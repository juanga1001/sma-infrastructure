param(
    [string]$LogDirectory = 'C:\SMA\logs',
    [string]$LogFileName = 'execution-node-watchdog.log',
    [string]$ExecutionNodeTaskName = 'SMA-Execution-Node',
    [string]$EnvFilePath = 'C:\SMA\sma-execution-node\.env',
    [int]$HealthTimeoutSeconds = 30,
    [int]$Mt5StartupWaitSeconds = 20
)

function Write-WatchdogLog {
    param([string]$Message)

    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory | Out-Null
    }

    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $LogPath = Join-Path $LogDirectory $LogFileName
    "$Timestamp $Message" | Add-Content -Path $LogPath
}

function Get-ExecutionNodeEnvValue {
    param(
        [string]$Name,
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    foreach ($Line in Get-Content $Path) {
        if ($Line -match "^\s*$Name\s*=\s*(.+)\s*$") {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }

    return $null
}

function Get-ExecutionNodeApiKey {
    param([string]$Path)

    return Get-ExecutionNodeEnvValue -Name 'EXECUTION_NODE_API_KEY' -Path $Path
}

function Get-DefaultTerminalPath {
    param([string]$Path)

    return Get-ExecutionNodeEnvValue -Name 'MT5_PATH' -Path $Path
}

function Test-ExecutionNodeHealth {
    try {
        $Response = Invoke-WebRequest `
            -Uri 'http://localhost:8000/healthcheck' `
            -UseBasicParsing `
            -TimeoutSec $HealthTimeoutSeconds
        return $Response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

function Get-WatchdogState {
    param([string]$ApiKey)

    $Headers = @{ 'X-API-Key' = $ApiKey }
    return Invoke-RestMethod `
        -Uri 'http://localhost:8000/ops/watchdog/terminals' `
        -Headers $Headers `
        -TimeoutSec $HealthTimeoutSeconds
}

function Get-RequiredTerminalPaths {
    param([string]$ApiKey)

    $State = Get-WatchdogState -ApiKey $ApiKey
    return @($State.terminal_paths)
}

function Test-TerminalRunning {
    param([string]$ExecutablePath)

    $NormalizedPath = $ExecutablePath.ToLowerInvariant()
    $Processes = @(
        Get-CimInstance Win32_Process -Filter "Name = 'terminal64.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            ($_.ExecutablePath.ToLowerInvariant() -eq $NormalizedPath)
        }
    )
    return $Processes.Count -gt 0
}

function Start-Mt5Terminal {
    param([string]$ExecutablePath)

    if (-not (Test-Path $ExecutablePath)) {
        Write-WatchdogLog "MT5 terminal executable not found: $ExecutablePath"
        return $false
    }

    $NormalizedPath = $ExecutablePath.ToLowerInvariant()
    $ConfigPath = 'C:\SMA\mt5\sma-terminal.ini'
    $LaunchCommand = "`"$ExecutablePath`""
    if ($NormalizedPath -like '*\sma\mt5\*') {
        if (Test-Path $ConfigPath) {
            $LaunchCommand = "`"$ExecutablePath`" /portable /config:`"$ConfigPath`""
        }
        else {
            $LaunchCommand = "`"$ExecutablePath`" /portable"
        }
    }
    elseif (Test-Path $ConfigPath) {
        $LaunchCommand = "`"$ExecutablePath`" /config:`"$ConfigPath`""
    }

    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $LaunchCommand) | Out-Null
    return $true
}

function Ensure-TerminalPathsRunning {
    param(
        [string[]]$TerminalPaths,
        [string]$Reason
    )

    $UniquePaths = @($TerminalPaths | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Select-Object -Unique)
    if ($UniquePaths.Count -eq 0) {
        Write-WatchdogLog "No $Reason terminals required."
        return
    }

    foreach ($Path in $UniquePaths) {
        if (Test-TerminalRunning -ExecutablePath $Path) {
            Write-WatchdogLog "Terminal already running ($Reason): $Path"
            continue
        }

        Write-WatchdogLog "Starting terminal ($Reason): $Path"
        if (Start-Mt5Terminal -ExecutablePath $Path) {
            Start-Sleep -Seconds $Mt5StartupWaitSeconds
            if (Test-TerminalRunning -ExecutablePath $Path) {
                Write-WatchdogLog "Terminal started successfully ($Reason): $Path"
            }
            else {
                Write-WatchdogLog "Terminal failed to start ($Reason): $Path"
            }
        }
    }
}

function Restart-ScheduledTaskSafely {
    param([string]$TaskName)

    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $Task) {
        throw "Scheduled task not found: $TaskName"
    }

    if ($TaskName -eq $ExecutionNodeTaskName) {
        $ApiProcesses = @(
            Get-CimInstance Win32_Process |
            Where-Object {
                $_.CommandLine -like '*uvicorn*' -and
                $_.CommandLine -like '*src.main:app*'
            }
        )
        foreach ($Process in $ApiProcesses) {
            Stop-Process -Id $Process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }

    if ($Task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    Start-ScheduledTask -TaskName $TaskName
}

try {
    Write-WatchdogLog 'Watchdog check started.'

    $ApiKey = Get-ExecutionNodeApiKey -Path $EnvFilePath
    $ConnectionTestsActive = 0
    if ($null -ne $ApiKey -and $ApiKey.Length -gt 0) {
        try {
            $WatchdogState = Get-WatchdogState -ApiKey $ApiKey
            $ConnectionTestsActive = [int]$WatchdogState.connection_tests_active
        }
        catch {
            Write-WatchdogLog "Failed to read watchdog state: $($_.Exception.Message)"
        }
    }

    if ($ConnectionTestsActive -gt 0) {
        Write-WatchdogLog "Connection test in progress ($ConnectionTestsActive active); skipping API restart and default terminal checks."
    }
    elseif (-not (Test-ExecutionNodeHealth)) {
        Write-WatchdogLog 'Execution Node healthcheck failed; restarting API scheduled task.'
        Restart-ScheduledTaskSafely -TaskName $ExecutionNodeTaskName
        Start-Sleep -Seconds 10

        if (Test-ExecutionNodeHealth) {
            Write-WatchdogLog 'Execution Node healthcheck recovered after API restart.'
        }
        else {
            Write-WatchdogLog 'Execution Node healthcheck still failing after API restart.'
        }
    }

    $DefaultTerminalPath = Get-DefaultTerminalPath -Path $EnvFilePath
    if ($ConnectionTestsActive -gt 0) {
        Write-WatchdogLog 'Skipping default API terminal check while connection test is active.'
    }
    elseif ($DefaultTerminalPath) {
        Ensure-TerminalPathsRunning -TerminalPaths @($DefaultTerminalPath) -Reason 'default API'
    }
    else {
        Write-WatchdogLog 'MT5_PATH not configured in Execution Node .env; skipping default terminal check.'
    }

    if ($null -eq $ApiKey -or $ApiKey.Length -eq 0) {
        Write-WatchdogLog "Execution Node API key not found in $EnvFilePath; skipping deployment terminal checks."
    }
    else {
        try {
            $RequiredPaths = Get-RequiredTerminalPaths -ApiKey $ApiKey
            Ensure-TerminalPathsRunning -TerminalPaths $RequiredPaths -Reason 'active deployment'
        }
        catch {
            Write-WatchdogLog "Failed to ensure active deployment terminals: $($_.Exception.Message)"
        }
    }

    Write-WatchdogLog 'Watchdog check finished.'
}
catch {
    Write-WatchdogLog "Watchdog check failed: $($_.Exception.Message)"
    throw
}
