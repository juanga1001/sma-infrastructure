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
    param(
        [string]$ExecutablePath,
        [switch]$UseScheduledTask
    )

    if (-not (Test-Path $ExecutablePath)) {
        Write-WatchdogLog "MT5 terminal executable not found: $ExecutablePath"
        return $false
    }

    if ($UseScheduledTask) {
        $Task = Get-ScheduledTask -TaskName 'SMA-MT5-Terminal' -ErrorAction SilentlyContinue
        if ($null -eq $Task) {
            Write-WatchdogLog 'SMA-MT5-Terminal scheduled task not found; falling back to direct launch.'
        }
        else {
            if ($Task.State -eq 'Running') {
                Stop-ScheduledTask -TaskName 'SMA-MT5-Terminal' -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
            Start-ScheduledTask -TaskName 'SMA-MT5-Terminal' | Out-Null
            return $true
        }
    }

    $NormalizedPath = $ExecutablePath.ToLowerInvariant()
    $ConfigPath = 'C:\SMA\mt5\sma-terminal.ini'
    $ArgumentList = @()
    if ($NormalizedPath -like '*\sma\mt5\*') {
        $ArgumentList += '/portable'
    }
    if (Test-Path $ConfigPath) {
        $ArgumentList += "/config:`"$ConfigPath`""
    }

    if ($ArgumentList.Count -gt 0) {
        Start-Process -FilePath $ExecutablePath -ArgumentList $ArgumentList | Out-Null
    }
    else {
        Start-Process -FilePath $ExecutablePath | Out-Null
    }
    return $true
}

function Enable-Mt5AlgoTradingAtPath {
    param([string]$ExecutablePath)

    $ScriptPath = 'C:\SMA\sma-execution-node\scripts\windows\enable-mt5-algo-trading-at-path.ps1'
    if (-not (Test-Path $ScriptPath)) {
        Write-WatchdogLog "Algo trading toggle script not found: $ScriptPath"
        return
    }

    try {
        & $ScriptPath -TerminalPath $ExecutablePath
        Write-WatchdogLog "Algo trading toggle sent for terminal: $ExecutablePath"
    }
    catch {
        Write-WatchdogLog "Failed to enable algo trading for $ExecutablePath : $($_.Exception.Message)"
    }
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
        $UseScheduledTask = (
            $Reason -eq 'default API' -and
            ($Path.ToLowerInvariant() -like '*\program files\metatrader 5\terminal64.exe')
        )
        if (Start-Mt5Terminal -ExecutablePath $Path -UseScheduledTask:$UseScheduledTask) {
            Start-Sleep -Seconds $Mt5StartupWaitSeconds
            if (Test-TerminalRunning -ExecutablePath $Path) {
                Write-WatchdogLog "Terminal started successfully ($Reason): $Path"
                Enable-Mt5AlgoTradingAtPath -ExecutablePath $Path
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

    if ($Task.State -eq 'Running') {
        # Stop via Task Scheduler first, while it still owns the process
        # cleanly. Killing the process out-of-band before this leaves Task
        # Scheduler believing the task is still running, which makes
        # Start-ScheduledTask a silent no-op (result code 267009 /
        # SCHED_S_TASK_RUNNING) on every subsequent watchdog cycle.
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $Deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $Deadline) {
            if ((Get-ScheduledTask -TaskName $TaskName).State -ne 'Running') {
                break
            }
            Start-Sleep -Milliseconds 500
        }
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

    Start-ScheduledTask -TaskName $TaskName
}

try {
    Write-WatchdogLog 'Watchdog check started.'

    $ApiKey = Get-ExecutionNodeApiKey -Path $EnvFilePath
    $ConnectionTestsActive = 0
    $WatchdogStateUnavailable = $false
    if ($null -ne $ApiKey -and $ApiKey.Length -gt 0) {
        try {
            $WatchdogState = Get-WatchdogState -ApiKey $ApiKey
            $ConnectionTestsActive = [int]$WatchdogState.connection_tests_active
        }
        catch {
            $WatchdogStateUnavailable = $true
            Write-WatchdogLog "Failed to read watchdog state: $($_.Exception.Message)"
        }
    }

    if ($ConnectionTestsActive -gt 0) {
        Write-WatchdogLog "Connection test in progress ($ConnectionTestsActive active); skipping API restart and deployment terminal checks."
    }
    elseif ($WatchdogStateUnavailable) {
        Write-WatchdogLog 'Watchdog state unavailable; skipping API restart to avoid interrupting in-flight account connections.'
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

    if ($null -eq $ApiKey -or $ApiKey.Length -eq 0) {
        Write-WatchdogLog "Execution Node API key not found in $EnvFilePath; skipping deployment terminal checks."
    }
    elseif ($ConnectionTestsActive -gt 0) {
        Write-WatchdogLog 'Skipping deployment terminal checks while connection test is active.'
    }
    elseif ($WatchdogStateUnavailable) {
        Write-WatchdogLog 'Skipping deployment terminal checks while watchdog state is unavailable.'
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
