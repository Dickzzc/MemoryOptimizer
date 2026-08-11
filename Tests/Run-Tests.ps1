[CmdletBinding()]
param(
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message; expected [$Expected], actual [$Actual]"
    }
}

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS: $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host "FAIL: $Name`n$($_.Exception.Message)" -ForegroundColor Red
    }
}

$requiredFiles = @(
    'Memory.Common.ps1',
    'Check-Memory.ps1',
    'Optimize-Memory-Safe.ps1',
    'Restore-Settings.ps1',
    'Monitor-Memory.ps1',
    'Start-MemoryOptimizer.ps1',
    'MemoryOptimizer.exe',
    'MemoryOptimizer.Launcher.csproj',
    'Program.cs',
    'app.manifest',
    'Tests\Run-LauncherTest.ps1',
    'Start-MemoryOptimizer.bat',
    'Restore-MemorySettings.bat',
    'config.json',
    'README.md'
)

Invoke-Test 'project files exist' {
    foreach ($file in $requiredFiles) {
        Assert-True (Test-Path -LiteralPath (Join-Path $ProjectRoot $file)) "missing $file"
    }
}

Invoke-Test 'all PowerShell files parse' {
    $parseErrors = @()
    $tokens = $null
    Get-ChildItem -LiteralPath $ProjectRoot -Filter '*.ps1' -File -Recurse | ForEach-Object {
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    }
    Assert-Equal 0 $parseErrors.Count 'PowerShell parse error count'
}

Invoke-Test 'check script creates full reports' {
    $testRoot = Join-Path $env:TEMP ('MemoryOptimizerTests_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    try {
        & (Join-Path $ProjectRoot 'Check-Memory.ps1') -OutputRoot $testRoot -NoPause
        foreach ($file in @('SystemInfo.txt', 'TopMemoryProcesses.csv', 'StartupItems.csv', 'ThirdPartyServices.csv', 'ScheduledTasks.csv', 'MemoryAnalysisReport.html', 'BrowserProcessDetails.csv')) {
            $path = Join-Path $testRoot "Reports\$file"
            Assert-True (Test-Path -LiteralPath $path) "missing report $file"
        }
        $rows = @(Import-Csv -LiteralPath (Join-Path $testRoot 'Reports\TopMemoryProcesses.csv'))
        Assert-True ($rows.Count -gt 0) 'process report is empty'
    }
    finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-Test 'dry run does not write system settings' {
    $testRoot = Join-Path $env:TEMP ('MemoryOptimizerDryRun_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    try {
        & (Join-Path $ProjectRoot 'Optimize-Memory-Safe.ps1') -OutputRoot $testRoot -DryRun -Interactive:$false -SkipBrowserOptimization
        $logs = Get-ChildItem -LiteralPath (Join-Path $testRoot 'Logs') -Filter '*.log' -File
        Assert-True ($logs.Count -gt 0) 'dry run did not create a log'
        $text = Get-Content -LiteralPath $logs[0].FullName -Raw
        Assert-True ($text -match 'DryRun') 'log does not mention DryRun'
    }
    finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-Test 'short monitor creates CSV and HTML' {
    $testRoot = Join-Path $env:TEMP ('MemoryOptimizerMonitor_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    try {
        & (Join-Path $ProjectRoot 'Monitor-Memory.ps1') -OutputRoot $testRoot -DurationMinutes 0.02 -IntervalSeconds 1
        Assert-True ((Get-ChildItem -LiteralPath (Join-Path $testRoot 'Reports') -Filter 'MemoryTrend_*.csv').Count -eq 1) 'monitor CSV count is wrong'
        Assert-True ((Get-ChildItem -LiteralPath (Join-Path $testRoot 'Reports') -Filter 'MemoryTrend_*.html').Count -eq 1) 'monitor HTML count is wrong'
    }
    finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Invoke-Test 'launcher validates adjacent entry script' {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProjectRoot 'Tests\Run-LauncherTest.ps1') -ProjectRoot $ProjectRoot
    Assert-Equal 0 $LASTEXITCODE 'launcher smoke test exit code'
}

Write-Host "`nTest result: passed $script:Passed, failed $script:Failed" -ForegroundColor Cyan
if ($script:Failed -gt 0) {
    exit 1
}
