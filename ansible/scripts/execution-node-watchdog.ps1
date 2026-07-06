param(
    [string]$LogDirectory = 'C:\SMA\logs',
    [string]$LogFileName = 'execution-node-watchdog.log',
    [string]$ExecutionNodeTaskName = 'SMA-Execution-Node',
    [string]$Mt5TaskName = 'SMA-MT5-Terminal',
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

function Restart-ScheduledTaskSafely {
    param(
        [string]$TaskName,
        [switch]$KillTerminalProcesses
    )

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

    if ($KillTerminalProcesses) {
        foreach ($Process in @(Get-Process -Name 'terminal64' -ErrorAction SilentlyContinue)) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
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

    if (@(Get-Process -Name 'terminal64' -ErrorAction SilentlyContinue).Count -eq 0) {
        Write-WatchdogLog 'MetaTrader terminal64 is not running; restarting MT5 scheduled task.'
        Restart-ScheduledTaskSafely -TaskName $Mt5TaskName -KillTerminalProcesses
        Start-Sleep -Seconds $Mt5StartupWaitSeconds

        $Mt5Count = @(Get-Process -Name 'terminal64' -ErrorAction SilentlyContinue).Count
        if ($Mt5Count -gt 0) {
            Write-WatchdogLog "MetaTrader terminal64 is running ($Mt5Count process(es))."
        }
        else {
            Write-WatchdogLog 'MetaTrader terminal64 is still not running after MT5 restart.'
        }
    }

    Write-WatchdogLog 'Watchdog check finished.'
}
catch {
    Write-WatchdogLog "Watchdog check failed: $($_.Exception.Message)"
    throw
}
