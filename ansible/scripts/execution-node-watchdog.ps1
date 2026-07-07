param(
    [string]$LogDirectory = 'C:\SMA\logs',
    [string]$LogFileName = 'execution-node-watchdog.log',
    [string]$ExecutionNodeTaskName = 'SMA-Execution-Node',
    [string]$EnvFilePath = 'C:\SMA\sma-execution-node\.env',
    [int]$HealthTimeoutSeconds = 5,
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

function Get-ExecutionNodeApiKey {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    foreach ($Line in Get-Content $Path) {
        if ($Line -match '^\s*EXECUTION_NODE_API_KEY\s*=\s*(.+)\s*$') {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }

    return $null
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

function Get-RequiredTerminalPaths {
    param([string]$ApiKey)

    $Headers = @{ 'X-API-Key' = $ApiKey }
    $Response = Invoke-RestMethod `
        -Uri 'http://localhost:8000/ops/watchdog/terminals' `
        -Headers $Headers `
        -TimeoutSec $HealthTimeoutSeconds
    return @($Response.terminal_paths)
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

    Start-Process -FilePath $ExecutablePath | Out-Null
    return $true
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

    if (-not (Test-ExecutionNodeHealth)) {
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

    $ApiKey = Get-ExecutionNodeApiKey -Path $EnvFilePath
    if ($null -eq $ApiKey -or $ApiKey.Length -eq 0) {
        Write-WatchdogLog "Execution Node API key not found in $EnvFilePath; skipping deployment terminal checks."
    }
    else {
        try {
            $RequiredPaths = Get-RequiredTerminalPaths -ApiKey $ApiKey
            if ($RequiredPaths.Count -eq 0) {
                Write-WatchdogLog 'No active deployment terminals required.'
            }
            else {
                foreach ($Path in $RequiredPaths) {
                    if (Test-TerminalRunning -ExecutablePath $Path) {
                        Write-WatchdogLog "Terminal already running: $Path"
                        continue
                    }

                    Write-WatchdogLog "Starting terminal for active deployment: $Path"
                    if (Start-Mt5Terminal -ExecutablePath $Path) {
                        Start-Sleep -Seconds $Mt5StartupWaitSeconds
                        if (Test-TerminalRunning -ExecutablePath $Path) {
                            Write-WatchdogLog "Terminal started successfully: $Path"
                        }
                        else {
                            Write-WatchdogLog "Terminal failed to start: $Path"
                        }
                    }
                }
            }
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
