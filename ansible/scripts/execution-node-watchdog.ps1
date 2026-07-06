param(
    [string]$LogDirectory = 'C:\SMA\logs',
    [string]$LogFileName = 'execution-node-watchdog.log',
    [string]$ExecutionNodeTaskName = 'SMA-Execution-Node',
    [string]$Mt5TaskName = 'SMA-MT5-Terminal',
    [int]$HealthTimeoutSeconds = 5
)

$ErrorActionPreference = 'Stop'

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
        Stop-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 2
    }

    Start-ScheduledTask -TaskName $TaskName
}

if (-not (Test-ExecutionNodeHealth)) {
    Write-WatchdogLog 'Execution Node healthcheck failed; restarting API scheduled task.'
    Restart-ScheduledTaskSafely -TaskName $ExecutionNodeTaskName
}

if (@(Get-Process -Name 'terminal64' -ErrorAction SilentlyContinue).Count -eq 0) {
    Write-WatchdogLog 'MetaTrader terminal64 is not running; restarting MT5 scheduled task.'
    Restart-ScheduledTaskSafely -TaskName $Mt5TaskName
}
