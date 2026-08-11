[CmdletBinding()]
param([string]$ProjectRoot)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$exe = Join-Path $ProjectRoot 'MemoryOptimizer.exe'
$script = Join-Path $ProjectRoot 'Start-MemoryOptimizer.ps1'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Launcher EXE is missing: $exe"
}
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw "PowerShell entry script is missing: $script"
}

$process = Start-Process -FilePath $exe -ArgumentList '--validate' -WorkingDirectory $ProjectRoot -Wait -PassThru -NoNewWindow
if ($process.ExitCode -ne 0) {
    throw "Launcher validation failed with exit code $($process.ExitCode)"
}

Write-Host 'Launcher smoke test passed.' -ForegroundColor Green
