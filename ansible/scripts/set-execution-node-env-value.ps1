param(
    [Parameter(Mandatory = $true)]
    [string]$EnvFilePath,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [string]$Value
)

$ErrorActionPreference = 'Stop'

$Directory = Split-Path -Parent $EnvFilePath
if ($Directory -and -not (Test-Path $Directory)) {
    New-Item -ItemType Directory -Path $Directory | Out-Null
}

$Lines = @()
if (Test-Path $EnvFilePath) {
    $Lines = @(Get-Content -Path $EnvFilePath)
}

$Pattern = "^\s*$([regex]::Escape($Name))\s*="
$NewLine = "$Name=$Value"
$Found = $false
$Updated = @(
    foreach ($Line in $Lines) {
        if ($Line -match $Pattern) {
            $Found = $true
            $NewLine
        }
        else {
            $Line
        }
    }
)

if (-not $Found) {
    if ($Updated.Count -gt 0 -and $Updated[-1].Trim().Length -gt 0) {
        $Updated += ''
    }
    $Updated += $NewLine
}

Set-Content -Path $EnvFilePath -Value $Updated -Encoding UTF8

@{
    env_file = $EnvFilePath
    name = $Name
    updated = $true
    inserted = -not $Found
}
