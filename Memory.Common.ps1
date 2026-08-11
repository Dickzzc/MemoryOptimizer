#requires -Version 5.1
Set-StrictMode -Version 2.0

$script:MemoryOptimizerScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-MemoryConfig {
    [CmdletBinding()]
    param([string]$ConfigPath = (Join-Path $script:MemoryOptimizerScriptRoot 'config.json'))

    $defaults = [ordered]@{
        OutputRoot = 'C:\MemoryOptimization'
        TempCleanupAgeDays = 7
        MonitorDurationMinutes = 30
        MonitorIntervalSeconds = 30
        ProcessTopCount = 30
        MonitorTopCount = 15
        LargeProcessMemoryMB = 1024
        LongRunningHours = 6
    }

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return [pscustomobject]$defaults
    }

    try {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
        $loaded = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($property in $loaded.PSObject.Properties) {
            $defaults[$property.Name] = $property.Value
        }
    }
    catch {
        Write-Warning ("Unable to read config; using defaults: {0}" -f $_.Exception.Message)
    }

    return [pscustomobject]$defaults
}

function Get-ConfigValue {
    param([object]$Config, [string]$Name, $DefaultValue)
    if ($null -ne $Config -and $null -ne $Config.PSObject.Properties[$Name]) {
        $value = $Config.PSObject.Properties[$Name].Value
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return $value
        }
    }
    return $DefaultValue
}

function Resolve-MemoryPaths {
    [CmdletBinding()]
    param(
        [string]$OutputRoot,
        [object]$Config = (Get-MemoryConfig)
    )

    $configuredRoot = $OutputRoot
    if ([string]::IsNullOrWhiteSpace($configuredRoot)) {
        $configuredRoot = [string](Get-ConfigValue $Config 'OutputRoot' 'C:\MemoryOptimization')
    }

    $root = [Environment]::ExpandEnvironmentVariables($configuredRoot)
    try {
        New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null
    }
    catch {
        $fallback = Join-Path $script:MemoryOptimizerScriptRoot 'Reports'
        New-Item -ItemType Directory -Path $fallback -Force -ErrorAction SilentlyContinue | Out-Null
        $root = $script:MemoryOptimizerScriptRoot
        Write-Warning ("Unable to create output root [{0}]; using project root [{1}]: {2}" -f $configuredRoot, $root, $_.Exception.Message)
    }

    $reports = Join-Path $root 'Reports'
    $logs = Join-Path $root 'Logs'
    $backup = Join-Path $root 'Backup'
    foreach ($directory in @($reports, $logs, $backup)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $logFile = Join-Path $logs ("MemoryOptimizer_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    return [pscustomobject]@{
        Root = $root
        Reports = $reports
        Logs = $logs
        Backup = $backup
        LogFile = $logFile
        ScriptRoot = $script:MemoryOptimizerScriptRoot
    }
}

function Write-MemoryLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DRYRUN')][string]$Level = 'INFO',
        [object]$Data
    )

    try {
        $record = [ordered]@{
            Timestamp = (Get-Date).ToString('o')
            Level = $Level
            Message = $Message
            Data = $Data
        }
        $line = $record | ConvertTo-Json -Compress -Depth 6
        Add-Content -LiteralPath $Paths.LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Warning ("Unable to write log: {0}" -f $_.Exception.Message)
    }
}

function Invoke-MemorySafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Paths,
        [switch]$ContinueOnError
    )

    try {
        $result = & $Action
        Write-MemoryLog -Paths $Paths -Message ("Completed: {0}" -f $Name) -Data $null
        return $result
    }
    catch {
        Write-MemoryLog -Paths $Paths -Level ERROR -Message ("Failed: {0}" -f $Name) -Data @{ Error = $_.Exception.ToString() }
        if (-not $ContinueOnError) {
            throw
        }
        return $null
    }
}

function Test-MemoryAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-ObjectPropertyValue {
    param([object]$Object, [string]$Name, $DefaultValue = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $DefaultValue
}

function ConvertTo-MemoryMB {
    param([double]$Bytes)
    return [math]::Round(($Bytes / 1MB), 1)
}

function ConvertTo-DisplayValue {
    param($Value, [string]$Format = 'General')
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($Value -is [double] -or $Value -is [decimal]) { return ('{0:N1}' -f $Value) }
    return [string]$Value
}

function Get-ExecutablePathFromCommand {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $value = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($value.StartsWith('"')) {
        $match = [regex]::Match($value, '^"([^"]+)"')
        if ($match.Success) { return $match.Groups[1].Value }
    }
    $exeMatch = [regex]::Match($value, '(?i)^(.+?\.exe)(?:\s|$)')
    if ($exeMatch.Success) { return $exeMatch.Groups[1].Value.Trim('"') }
    $match = [regex]::Match($value, '^([^\s]+)')
    if ($match.Success) { return $match.Groups[1].Value.Trim('"') }
    return $value
}

function Test-IsWindowsPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = $Path.ToLowerInvariant().Replace('/', '\')
    return ($normalized -match '\\windows\\' -or $normalized -match '^%systemroot%' -or $normalized -match '^%windir%' -or $normalized -match '^system32')
}

function Test-IsMicrosoftPublisher {
    param([string]$Publisher, [string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Publisher) -and $Publisher -match '(?i)microsoft') { return $true }
    return Test-IsWindowsPath $Path
}

function Get-ExecutableMetadata {
    param([string]$Path)
    $result = [ordered]@{
        Publisher = ''
        SignatureStatus = 'Unavailable'
        Product = ''
        Version = ''
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$result
    }
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $result.Publisher = [string]$item.VersionInfo.CompanyName
        $result.Product = [string]$item.VersionInfo.ProductName
        $result.Version = [string]$item.VersionInfo.ProductVersion
    }
    catch { }
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $result.SignatureStatus = [string]$signature.Status
        if ([string]::IsNullOrWhiteSpace($result.Publisher) -and $null -ne $signature.SignerCertificate) {
            $result.Publisher = [string]$signature.SignerCertificate.Subject
        }
    }
    catch { }
    return [pscustomobject]$result
}

function Get-SafeCpuSeconds {
    param([object]$Process)
    try { return [double]$Process.CPU }
    catch { return 0.0 }
}

function Get-SafeProcessStartTime {
    param([object]$Process)
    try { return [datetime]$Process.StartTime }
    catch { return $null }
}

function Get-SafeProcessPath {
    param([object]$Process)
    try { return [string]$Process.MainModule.FileName }
    catch { return '' }
}

function Get-ProcessClassification {
    param([string]$Name, [string]$Path, [string]$Publisher)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $lower = $base.ToLowerInvariant()
    $core = @('system', 'system idle process', 'smss', 'csrss', 'wininit', 'services', 'lsass', 'winlogon', 'svchost', 'fontdrvhost', 'dwm', 'registry', 'memory compression', 'audiodg')
    $security = @('msmpeng', 'nissrv', 'securityhealthservice', 'windefend', 'wscsvc', 'mssense', 'avp', 'ekrn', 'savservice', 'bdservicehost', 'mbamservice')
    $virtual = @('vmmem', 'vmmemwsl', 'wslhost', 'docker desktop', 'com.docker.backend', 'vmcompute', 'vmwp', 'virtualboxvm', 'vmware-vmx', 'qemu-system', 'hd-player', 'dnplayer', 'aow_exe', 'emulator')
    $userApps = @('chrome', 'msedge', 'wechat', 'wechatappex', 'winword', 'excel', 'powerpnt', 'outlook', 'code', 'codex', 'chatgpt', 'devenv', 'idea64', 'notepad')

    if ($core -contains $lower) {
        return [pscustomobject]@{ Category = 'Windows核心进程'; Risk = '禁止结束'; Advice = '不要关闭；需由系统自动管理。' }
    }
    if (($security -contains $lower) -or ((Test-IsMicrosoftPublisher $Publisher $Path) -and ($lower -match 'defender|security|antimalware'))) {
        return [pscustomobject]@{ Category = '安全软件/驱动'; Risk = '不建议关闭'; Advice = '不要关闭或禁用安全保护。' }
    }
    if ($virtual -contains $lower -or $lower -match 'wsl|docker|virtualbox|vmware|qemu|emulator') {
        return [pscustomobject]@{ Category = 'WSL/容器/虚拟机/模拟器'; Risk = '仅在不用时退出'; Advice = '只在确认没有运行任务时手动停止。' }
    }
    if ($userApps -contains $lower) {
        return [pscustomobject]@{ Category = '当前使用的软件'; Risk = '可退出但可能丢失未保存内容'; Advice = '先保存工作，再从软件自身菜单退出。' }
    }
    if ((Test-IsMicrosoftPublisher $Publisher $Path) -and ((Test-IsWindowsPath $Path) -or ($lower -match '^(msedgewebview2|runtimebroker|searchapp)$'))) {
        return [pscustomobject]@{ Category = 'Windows/微软组件'; Risk = '不要盲目关闭'; Advice = '先确认启动来源和用途。' }
    }
    if ($Path -match '(?i)\\(Temp|AppData\\Roaming)\\' -and $Publisher -eq '') {
        return [pscustomobject]@{ Category = '需人工核查的未知进程'; Risk = '不要删除或结束'; Advice = '检查数字签名、安装来源和父进程。' }
    }
    return [pscustomobject]@{ Category = '第三方/未知进程'; Risk = '需人工判断'; Advice = '结合路径、发布者和签名后再处理。' }
}

function Get-ProcessSnapshot {
    [CmdletBinding()]
    param(
        [int]$Top = 30,
        [int]$SampleMilliseconds = 250,
        [int]$LargeProcessMemoryMB = 1024,
        [int]$LongRunningHours = 6,
        [switch]$SkipMetadata
    )

    $first = @(Get-Process -ErrorAction SilentlyContinue)
    $firstCpu = @{}
    foreach ($process in $first) {
        $firstCpu[[int]$process.Id] = Get-SafeCpuSeconds $process
    }
    Start-Sleep -Milliseconds $SampleMilliseconds
    $second = @(Get-Process -ErrorAction SilentlyContinue)
    $secondById = @{}
    foreach ($process in $second) { $secondById[[int]$process.Id] = $process }
    $logicalProcessors = [math]::Max([Environment]::ProcessorCount, 1)
    $intervalSeconds = [math]::Max(($SampleMilliseconds / 1000.0), 0.001)
    $instanceCounts = @{}
    foreach ($process in $second) {
        $name = [string]$process.ProcessName
        if (-not $instanceCounts.ContainsKey($name)) { $instanceCounts[$name] = 0 }
        $instanceCounts[$name]++
    }

    $rows = foreach ($process in $second) {
        $processId = [int]$process.Id
        $path = Get-SafeProcessPath $process
        $cpuSeconds = Get-SafeCpuSeconds $process
        $previousCpu = 0.0
        if ($firstCpu.ContainsKey($processId)) { $previousCpu = [double]$firstCpu[$processId] }
        $cpuPercent = (($cpuSeconds - $previousCpu) / $intervalSeconds / $logicalProcessors) * 100
        if ($cpuPercent -lt 0) { $cpuPercent = 0 }
        if ($cpuPercent -gt 100) { $cpuPercent = 100 }
        $startTime = Get-SafeProcessStartTime $process
        $classification = Get-ProcessClassification -Name $process.ProcessName -Path $path -Publisher ''
        $workingSet = [double]$process.WorkingSet64
        $privateBytes = 0.0
        try { $privateBytes = [double]$process.PrivateMemorySize64 } catch { }
        $highSnapshot = $workingSet -ge ($LargeProcessMemoryMB * 1MB)
        $longRunning = $false
        if ($null -ne $startTime) { $longRunning = ((Get-Date) - $startTime).TotalHours -ge $LongRunningHours }
        [pscustomobject]@{
            Name = [string]$process.ProcessName
            PID = $processId
            MemoryMB = (ConvertTo-MemoryMB $workingSet)
            PrivateMemoryMB = (ConvertTo-MemoryMB $privateBytes)
            CPUPercent = [math]::Round($cpuPercent, 1)
            CPUSeconds = [math]::Round($cpuSeconds, 1)
            ExecutablePath = $path
            StartTime = if ($null -eq $startTime) { '' } else { $startTime.ToString('yyyy-MM-dd HH:mm:ss') }
            InstanceCount = [int]$instanceCounts[[string]$process.ProcessName]
            Category = $classification.Category
            Risk = $classification.Risk
            Recommendation = $classification.Advice
            SnapshotFlag = if ($highSnapshot -and $longRunning) { '高占用且长期运行；不能仅凭快照认定泄漏' } elseif ($highSnapshot) { '单次快照高占用；需持续监控' } else { '' }
            Publisher = ''
            SignatureStatus = 'Unavailable'
            Product = ''
            Version = ''
        }
    }

    if ($Top -gt 0) { $rows = @($rows | Sort-Object -Property @{Expression = { [double]$_.MemoryMB }; Descending = $true} | Select-Object -First $Top) }
    else { $rows = @($rows | Sort-Object -Property @{Expression = { [double]$_.MemoryMB }; Descending = $true}) }

    if (-not $SkipMetadata) {
        foreach ($row in $rows) {
            $metadata = Get-ExecutableMetadata $row.ExecutablePath
            $row.Publisher = $metadata.Publisher
            $row.SignatureStatus = $metadata.SignatureStatus
            $row.Product = $metadata.Product
            $row.Version = $metadata.Version
            $classification = Get-ProcessClassification -Name $row.Name -Path $row.ExecutablePath -Publisher $row.Publisher
            $row.Category = $classification.Category
            $row.Risk = $classification.Risk
            $row.Recommendation = $classification.Advice
        }
    }
    return $rows
}

function Get-ApplicationSummary {
    param([object[]]$Processes)
    $definitions = [ordered]@{
        'Chrome' = @('chrome')
        'Edge' = @('msedge')
        '微信' = @('wechat', 'wechatappex')
        'Office' = @('winword', 'excel', 'powerpnt', 'outlook', 'onenote', 'msaccess')
        'VS Code' = @('code')
        'Codex' = @('codex', 'chatgpt')
        'Defender/安全软件' = @('msmpeng', 'nissrv', 'securityhealthservice', 'windefend', 'mssense', 'avp', 'ekrn', 'savservice', 'bdservicehost', 'mbamservice')
        'WSL/Docker/虚拟机/模拟器' = @('vmmem', 'vmmemwsl', 'wslhost', 'docker desktop', 'com.docker.backend', 'vmcompute', 'vmwp', 'virtualboxvm', 'vmware-vmx', 'qemu-system', 'hd-player', 'dnplayer', 'aow_exe', 'emulator')
    }
    $result = foreach ($entry in $definitions.GetEnumerator()) {
        $matching = @($Processes | Where-Object { $entry.Value -contains ([string]$_.Name).ToLowerInvariant() })
        $memoryMeasure = $matching | Measure-Object -Property MemoryMB -Sum
        $memorySum = 0.0
        if ($null -ne $memoryMeasure -and $null -ne $memoryMeasure.Sum) { $memorySum = [double]$memoryMeasure.Sum }
        [pscustomobject]@{
            Application = $entry.Key
            ProcessCount = $matching.Count
            TotalMemoryMB = [math]::Round($memorySum, 1)
            PIDs = ($matching | ForEach-Object { $_.PID }) -join ','
            Notes = if ($matching.Count -eq 0) { '当前快照未发现进程' } elseif ($matching.Count -gt 1) { '存在多个实例；请检查标签页、扩展或多个配置文件' } else { '' }
        }
    }
    return @($result)
}

function Get-MemorySystemSnapshot {
    [CmdletBinding()]
    param([object]$Paths)

    $os = $null
    $computer = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { Write-MemoryLog -Paths $Paths -Level ERROR -Message '读取操作系统信息失败' -Data @{ Error = $_.Exception.ToString() } }
    try { $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { Write-MemoryLog -Paths $Paths -Level ERROR -Message '读取计算机信息失败' -Data @{ Error = $_.Exception.ToString() } }
    $totalKB = 0.0
    $freeKB = 0.0
    if ($null -ne $os) { $totalKB = [double]$os.TotalVisibleMemorySize; $freeKB = [double]$os.FreePhysicalMemory }
    $usedKB = [math]::Max(($totalKB - $freeKB), 0)
    $pageUsage = @()
    $pageSettings = @()
    try { $pageUsage = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop) } catch { Write-MemoryLog -Paths $Paths -Level WARN -Message '读取页面文件使用量失败' -Data @{ Error = $_.Exception.Message } }
    try { $pageSettings = @(Get-CimInstance Win32_PageFileSetting -ErrorAction Stop) } catch { Write-MemoryLog -Paths $Paths -Level WARN -Message '读取页面文件配置失败' -Data @{ Error = $_.Exception.Message } }
    $compression = $null
    if (Get-Command Get-MMAgent -ErrorAction SilentlyContinue) {
        try { $compression = Get-MMAgent -ErrorAction Stop } catch { Write-MemoryLog -Paths $Paths -Level WARN -Message '读取内存压缩状态失败' -Data @{ Error = $_.Exception.Message } }
    }
    $memoryCompressionProcess = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '(?i)^(MemCompression|Memory Compression)$' })
    $disks = @()
    try { $disks = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop | Select-Object DeviceID, @{Name = 'FreeGB'; Expression = { [math]::Round(([double]$_.FreeSpace / 1GB), 2) }}, @{Name = 'SizeGB'; Expression = { [math]::Round(([double]$_.Size / 1GB), 2) }}) } catch { }
    $physicalDisks = @()
    if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        try { $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop | Select-Object FriendlyName,MediaType,BusType,HealthStatus,OperationalStatus,@{Name = 'SizeGB'; Expression = { [math]::Round(([double]$_.Size / 1GB), 2) }}) } catch { }
    }
    if ($physicalDisks.Count -eq 0) {
        try { $physicalDisks = @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Select-Object @{Name = 'FriendlyName'; Expression = { $_.Model }},MediaType,@{Name = 'BusType'; Expression = { $_.InterfaceType }},Status,@{Name = 'SizeGB'; Expression = { [math]::Round(([double]$_.Size / 1GB), 2) }}) } catch { }
    }
    $security = @()
    try { $security = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | Select-Object displayName, pathToSignedProductExe, productState) } catch { }
    $defender = $null
    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        try { $defender = Get-MpComputerStatus -ErrorAction Stop | Select-Object AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,AntispywareEnabled } catch { }
    }
    $virtualization = Get-VirtualizationStatus -Paths $Paths
    $boot = if ($null -ne $os) { [datetime]$os.LastBootUpTime } else { $null }
    return [pscustomobject]@{
        OS = if ($null -ne $os) { [string]$os.Caption } else { '' }
        Version = if ($null -ne $os) { [string]$os.Version } else { '' }
        Build = if ($null -ne $os) { [string]$os.BuildNumber } else { '' }
        Architecture = if ($null -ne $os) { [string]$os.OSArchitecture } else { if ([Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' } }
        TotalMemoryGB = [math]::Round(($totalKB / 1MB), 2)
        UsedMemoryGB = [math]::Round(($usedKB / 1MB), 2)
        FreeMemoryGB = [math]::Round(($freeKB / 1MB), 2)
        MemoryUsagePercent = if ($totalKB -gt 0) { [math]::Round(($usedKB / $totalKB) * 100, 1) } else { 0 }
        LastBoot = if ($null -eq $boot) { '' } else { $boot.ToString('yyyy-MM-dd HH:mm:ss') }
        Uptime = if ($null -eq $boot) { '' } else { ((Get-Date) - $boot).ToString() }
        AutomaticManagedPagefile = if ($null -ne $computer) { [bool]$computer.AutomaticManagedPagefile } else { $null }
        PageFileUsage = $pageUsage
        PageFileSettings = $pageSettings
        MemoryAgent = $compression
        MemoryCompressionProcessCount = $memoryCompressionProcess.Count
        Disks = $disks
        PhysicalDisks = $physicalDisks
        SecurityProducts = $security
        Defender = $defender
        Virtualization = $virtualization
    }
}

function Get-VirtualizationStatus {
    param([object]$Paths)
    $names = @('wsl', 'wslhost', 'vmmem', 'vmmemWSL', 'docker', 'com.docker.backend', 'vmcompute', 'vmwp', 'VirtualBoxVM', 'vmware-vmx', 'qemu-system-x86_64', 'HD-Player', 'dnplayer', 'aow_exe', 'emulator')
    $processes = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName -or $_.ProcessName -match '(?i)wsl|docker|vmmem|virtualbox|vmware|qemu|emulator|player' })
    $wslStatus = ''
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        try {
            $rawWslStatus = (& wsl.exe --status 2>&1 | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($rawWslStatus)) {
                $wslStatus = 'wsl.exe detected; status output was empty'
            }
            elseif ($rawWslStatus.IndexOf([char]0) -ge 0 -or $rawWslStatus.IndexOf([char]0xfffd) -ge 0) {
                $wslStatus = 'wsl.exe detected; detailed status encoding was unavailable'
            }
            else {
                $wslStatus = $rawWslStatus
            }
        }
        catch { $wslStatus = 'wsl.exe status query failed: ' + $_.Exception.Message }
    }
    return [pscustomobject]@{
        RunningProcesses = @($processes | Select-Object ProcessName,Id,WorkingSet64)
        RunningProcessCount = $processes.Count
        WslStatus = $wslStatus
        DockerDetected = [bool](@($processes | Where-Object { $_.ProcessName -match '(?i)docker' }).Count)
        VirtualMachineDetected = [bool](@($processes | Where-Object { $_.ProcessName -match '(?i)vmmem|vmwp|virtualbox|vmware|qemu' }).Count)
        AndroidEmulatorDetected = [bool](@($processes | Where-Object { $_.ProcessName -match '(?i)emulator|player|aow' }).Count)
    }
}

function Get-StartupItems {
    [CmdletBinding()]
    param([object]$Paths)
    $items = @()
    try {
        $items += @(Get-CimInstance Win32_StartupCommand -ErrorAction Stop | ForEach-Object {
            $path = Get-ExecutablePathFromCommand $_.Command
            $metadata = Get-ExecutableMetadata $path
            [pscustomobject]@{
                Name = [string]$_.Name
                Command = [string]$_.Command
                Location = [string]$_.Location
                User = [string]$_.User
                Source = 'Win32_StartupCommand'
                RegistryPath = ''
                ExecutablePath = $path
                ExecutableExists = (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue))
                ResidualCandidate = (-not [string]::IsNullOrWhiteSpace($path) -and -not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue))
                Publisher = $metadata.Publisher
                SignatureStatus = $metadata.SignatureStatus
                IsCandidate = (-not (Test-IsWindowsPath $path) -and -not (Test-IsMicrosoftPublisher $metadata.Publisher $path))
                Recommendation = '先确认用途、发布者和是否需要开机启动；不自动判断为恶意。'
            }
        })
    }
    catch { Write-MemoryLog -Paths $Paths -Level WARN -Message '读取 Win32_StartupCommand 失败' -Data @{ Error = $_.Exception.Message } }

    $registryPaths = @(
        'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run',
        'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run',
        'Registry::HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($registryPath in $registryPaths) {
        try {
            if (-not (Test-Path -LiteralPath $registryPath)) { continue }
            $key = Get-Item -LiteralPath $registryPath -ErrorAction Stop
            $properties = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
            foreach ($property in $properties.PSObject.Properties) {
                if ($property.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) { continue }
                $command = [string]$property.Value
                $path = Get-ExecutablePathFromCommand $command
                $metadata = Get-ExecutableMetadata $path
                $items += [pscustomobject]@{
                    Name = [string]$property.Name
                    Command = $command
                    Location = $registryPath
                    User = if ($registryPath -match 'HKEY_CURRENT_USER') { [Environment]::UserName } else { 'All Users' }
                    Source = 'Registry'
                    RegistryPath = $registryPath
                    ExecutablePath = $path
                    ExecutableExists = (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue))
                    ResidualCandidate = (-not [string]::IsNullOrWhiteSpace($path) -and -not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue))
                    Publisher = $metadata.Publisher
                    SignatureStatus = $metadata.SignatureStatus
                    IsCandidate = (-not (Test-IsWindowsPath $path) -and -not (Test-IsMicrosoftPublisher $metadata.Publisher $path))
                    Recommendation = '仅在确认不需要时禁用；备份后可恢复。'
                }
            }
        }
        catch { Write-MemoryLog -Paths $Paths -Level WARN -Message '读取注册表启动项失败' -Data @{ RegistryPath = $registryPath; Error = $_.Exception.Message } }
    }
    return @($items | Sort-Object Location,Name -Unique)
}

function Get-ThirdPartyServices {
    [CmdletBinding()]
    param([object]$Paths)
    $services = @()
    try {
        $services = @(Get-CimInstance Win32_Service -Filter "State='Running'" -ErrorAction Stop | ForEach-Object {
            $path = Get-ExecutablePathFromCommand $_.PathName
            $metadata = Get-ExecutableMetadata $path
            $isThirdParty = (-not (Test-IsWindowsPath $path) -and -not (Test-IsMicrosoftPublisher $metadata.Publisher $path))
            if ($isThirdParty) {
                [pscustomobject]@{
                    Name = [string]$_.Name
                    DisplayName = [string]$_.DisplayName
                    Status = [string]$_.State
                    StartMode = [string]$_.StartMode
                    ProcessId = [int]$_.ProcessId
                    StartName = [string]$_.StartName
                     PathName = [string]$_.PathName
                     ExecutablePath = $path
                     ExecutableExists = (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue))
                     ResidualCandidate = (-not [string]::IsNullOrWhiteSpace($path) -and -not (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction SilentlyContinue))
                     Publisher = $metadata.Publisher
                    SignatureStatus = $metadata.SignatureStatus
                    Product = $metadata.Product
                    Recommendation = '只记录为第三方运行服务；不要仅凭名称改为手动，先确认用途和恢复方案。'
                }
            }
        })
    }
    catch { Write-MemoryLog -Paths $Paths -Level WARN -Message '读取运行服务失败' -Data @{ Error = $_.Exception.ToString() } }
    return @($services | Sort-Object DisplayName)
}

function Get-ThirdPartyScheduledTasks {
    [CmdletBinding()]
    param([object]$Paths)
    $tasks = @()
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        Write-MemoryLog -Paths $Paths -Level WARN -Message '当前 PowerShell 没有 Get-ScheduledTask，跳过计划任务' -Data $null
        return @()
    }
    try {
        foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
            $actions = @($task.Actions | ForEach-Object { "{0} {1}" -f $_.Execute, $_.Arguments })
            $executePaths = @($task.Actions | ForEach-Object { Get-ExecutablePathFromCommand $_.Execute })
            $existingExecutePaths = @($executePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf -ErrorAction SilentlyContinue) })
            $isMicrosoft = ([string]$task.TaskPath -match '^\\Microsoft\\Windows\\') -and (@($executePaths | Where-Object { Test-IsWindowsPath $_ }).Count -gt 0)
            if (-not $isMicrosoft) {
                $tasks += [pscustomobject]@{
                    TaskName = [string]$task.TaskName
                    TaskPath = [string]$task.TaskPath
                    State = [string]$task.State
                    Author = [string]$task.Author
                    Principal = [string]$task.Principal.UserId
                    Actions = ($actions -join ' | ')
                    Triggers = (@($task.Triggers | ForEach-Object { $_.CimClass.CimClassName }) -join ' | ')
                     Hidden = [bool]$task.Settings.Hidden
                     ExecutablePaths = ($executePaths -join ' | ')
                     ExecutableExists = ($existingExecutePaths.Count -gt 0)
                     ResidualCandidate = ($executePaths.Count -gt 0 -and $existingExecutePaths.Count -eq 0)
                     Recommendation = '检查是否为更新器或常驻程序；先禁用而不是删除，记录恢复路径。'
                }
            }
        }
    }
    catch { Write-MemoryLog -Paths $Paths -Level WARN -Message '读取计划任务失败' -Data @{ Error = $_.Exception.ToString() } }
    return @($tasks | Sort-Object TaskPath,TaskName)
}

function Get-MemoryRecommendations {
    [CmdletBinding()]
    param(
        [object[]]$Processes,
        [object[]]$Applications,
        [object[]]$StartupItems,
        [object]$SystemSnapshot
    )
    $recommendations = @()
    foreach ($application in @($Applications | Where-Object { $_.ProcessCount -gt 0 -and $_.TotalMemoryMB -gt 100 -and $_.Application -ne 'Defender/安全软件' })) {
        $recommendations += [pscustomobject]@{
            Priority = 'A级'
            Item = $application.Application
            CurrentMemoryMB = $application.TotalMemoryMB
            Purpose = '当前应用或其后台进程'
            CanClose = '可以；先保存工作并从应用自身退出'
            CanDisableStartup = if ($application.Application -in @('Chrome','Edge','微信','Office','VS Code','Codex')) { '需人工确认' } else { '不确定' }
            ShouldUninstall = '不建议仅凭内存快照卸载'
            Risk = '低到中；关闭可能丢失未保存内容'
            ExpectedReleaseMB = $application.TotalMemoryMB
            Restore = '重新打开应用或恢复原启动项设置'
            Evidence = "进程数 $($application.ProcessCount)，PID $($application.PIDs)"
        }
    }
    foreach ($process in @($Processes | Where-Object { $_.SnapshotFlag -ne '' } | Select-Object -First 3)) {
        $recommendations += [pscustomobject]@{
            Priority = '需监控'
            Item = "$($process.Name) (PID $($process.PID))"
            CurrentMemoryMB = $process.MemoryMB
            Purpose = $process.Product
            CanClose = $process.Risk
            CanDisableStartup = '需结合启动来源判断'
            ShouldUninstall = '不建议；先检查签名和来源'
            Risk = '未知；单次快照不能证明泄漏'
            ExpectedReleaseMB = $process.MemoryMB
            Restore = '重新启动原程序；监控脚本可生成增长趋势'
            Evidence = $process.SnapshotFlag
        }
    }
    foreach ($startup in @($StartupItems | Where-Object { $_.IsCandidate -and $_.Source -eq 'Registry' } | Select-Object -First 3)) {
        $recommendations += [pscustomobject]@{
            Priority = 'A级/需确认'
            Item = "启动项：$($startup.Name)"
            CurrentMemoryMB = ''
            Purpose = $startup.ExecutablePath
            CanClose = '不适用'
            CanDisableStartup = '可在备份后禁用'
            ShouldUninstall = '不建议自动卸载'
            Risk = '低到中；可能影响自动同步或常用工具'
            ExpectedReleaseMB = '无法仅凭快照量化'
            Restore = 'Restore-Settings.ps1 可从 Backup 恢复'
            Evidence = "$($startup.Publisher); 签名 $($startup.SignatureStatus)"
        }
    }
    if ($null -ne $SystemSnapshot -and $SystemSnapshot.AutomaticManagedPagefile -eq $false) {
        $recommendations += [pscustomobject]@{
            Priority = 'B级'
            Item = '页面文件配置'
            CurrentMemoryMB = ''
            Purpose = '虚拟内存'
            CanClose = '不适用'
            CanDisableStartup = '不适用'
            ShouldUninstall = '不适用'
            Risk = '手动调整可能导致提交内存不足或需要重启'
            ExpectedReleaseMB = '不保证释放物理内存'
            Restore = '恢复为系统自动管理'
            Evidence = '当前不是系统自动管理'
        }
    }
    if (@($recommendations).Count -eq 0) {
        $recommendations += [pscustomobject]@{
            Priority = '提示'
            Item = '没有可自动判定的安全优化项'
            CurrentMemoryMB = ''
            Purpose = '当前快照未发现超过阈值的已知应用'
            CanClose = '仅关闭你确认不用的应用'
            CanDisableStartup = '逐项人工判断'
            ShouldUninstall = '不要自动卸载'
            Risk = '避免盲目修改'
            ExpectedReleaseMB = '未知'
            Restore = '保持现状'
            Evidence = '请结合趋势监控继续观察'
        }
    }
    return @($recommendations | Select-Object -First 10)
}

function Write-CsvUtf8 {
    param([object[]]$Rows, [string]$Path)
    if (@($Rows).Count -eq 0) {
        [pscustomobject]@{ 信息 = '没有采集到数据' } | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    }
    else {
        @($Rows) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    }
}

function ConvertTo-HtmlTable {
    param([object[]]$Rows, [string]$Title)
    if (@($Rows).Count -eq 0) { $Rows = @([pscustomobject]@{ 信息 = '没有采集到数据' }) }
    return ("<h2>{0}</h2>{1}" -f $Title, ((@($Rows) | ConvertTo-Html -Fragment) -join [Environment]::NewLine))
}
