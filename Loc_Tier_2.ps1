Clear-Host

$script:LocTier1Version = '1.5.0'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Open-LocalMachineRegistryKey {
    param([string]$SubKeyPath)

    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64
        )
        if ([string]::IsNullOrWhiteSpace($SubKeyPath)) { return $base }
        return $base.OpenSubKey($SubKeyPath)
    } catch {
        return $null
    }
}

function Add-RegistryKeyFingerprint {
    param(
        [Microsoft.Win32.RegistryKey]$Key,
        [string]$Prefix,
        [System.Collections.Generic.List[string]]$Parts
    )

    foreach ($name in $Key.GetValueNames()) {
        $raw = $Key.GetValue($name)
        if ($null -eq $raw) {
            $Parts.Add("$Prefix|$name=")
        } elseif ($raw -is [byte[]]) {
            $Parts.Add("$Prefix|$name=0x$([BitConverter]::ToString($raw).Replace('-', ''))")
        } else {
            $Parts.Add("$Prefix|$name=$raw")
        }
    }

    foreach ($subName in $Key.GetSubKeyNames()) {
        $subKey = $Key.OpenSubKey($subName)
        if ($subKey) {
            Add-RegistryKeyFingerprint -Key $subKey -Prefix "$Prefix\$subName" -Parts $Parts
            $subKey.Close()
        } else {
            $Parts.Add("$Prefix\$subName=<missing>")
        }
    }
}

# ===============================
# ASCII Banner (LOC RECORDING POLICY T1)
# ===============================
Write-Host "   __   ____  _____  ___  _____________  ___  ___  _____  _______  ___  ____  __   ___________  __  _________" -ForegroundColor Cyan
Write-Host "  / /  / __ \/ ___/ / _ \/ __/ ___/ __ \/ _ \/ _ \/  _/ |/ / ___/ / _ \/ __ \/ /  /  _/ ___/\ \/ / /_  __<  /" -ForegroundColor Cyan
Write-Host " / /__/ /_/ / /__  / , _/ _// /__/ /_/ / , _/ // // //    / (_ / / ___/ /_/ / /___/ // /__   \  /   / /  / / " -ForegroundColor Cyan
Write-Host "/____/\____/\___/ /_/|_/___/\___/\____/_/|_/____/___/_/|_/\___/ /_/   \____/____/___/\___/   /_/   /_/  /_/  " -ForegroundColor Cyan
Write-Host ""
Write-Host "LOC Tier 1 v$($script:LocTier1Version)" -ForegroundColor White
Write-Host "Discord.gg/locx | Complete with 100% success rate" -ForegroundColor White
Write-Host ""
if (-not (Test-Admin)) {
    Write-Host "WARNING: Run as Administrator for full results." -ForegroundColor Yellow
}

function Write-Section {
    param($Title, $Lines)
    Write-Host "--- $Title ---" -ForegroundColor Cyan
    foreach ($line in $Lines) {
        if ($line -like "SUCCESS*") { Write-Host $line -ForegroundColor Green }
        elseif ($line -like "FAILURE*") { Write-Host $line -ForegroundColor Red }
        elseif ($line -like "WARNING*") { Write-Host $line -ForegroundColor Yellow }
    }
    Write-Host ""
}

function Invoke-ToolDownload {
    param(
        [string]$Url,
        [string]$ZipPath,
        [string]$DestDir
    )

    try {
        Invoke-WebRequest -Uri $Url -OutFile $ZipPath -UseBasicParsing -TimeoutSec 120
        if (-not (Test-Path $ZipPath)) { return $false }
        if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
        Expand-Archive -Path $ZipPath -DestinationPath $DestDir -Force
        return $true
    } catch {
        Write-Warning "Download failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-Exclusions {
    $list = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    try {
        $prefs = Get-MpPreference -ErrorAction Stop
        foreach ($item in @($prefs.ExclusionPath) + @($prefs.ExclusionProcess) + @($prefs.ExclusionExtension)) {
            if ($item) { [void]$list.Add([string]$item) }
        }
    } catch {}

    $regRoots = @(
        'SOFTWARE\Microsoft\Windows Defender\Exclusions',
        'SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions'
    )
    $regTypes = @('Paths', 'Processes', 'Extensions')

    foreach ($root in $regRoots) {
        foreach ($type in $regTypes) {
            try {
                $key = Open-LocalMachineRegistryKey -SubKeyPath "$root\$type"
                if (-not $key) { continue }
                foreach ($name in $key.GetValueNames()) {
                    if ($name) { [void]$list.Add($name) }
                }
                $key.Close()
            } catch {}
        }
    }

    return @($list)
}

$script:DefenderExclusionsRegRoots = @(
    'SOFTWARE\Microsoft\Windows Defender\Exclusions',
    'SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions'
)
$script:DefenderThreatsRegRoots = @(
    'SOFTWARE\Microsoft\Windows Defender\Threats',
    'SOFTWARE\Policies\Microsoft\Windows Defender\Threats'
)
$script:DefenderThreatsSystemSubkeys = @(
    'ThreatSeverityDefaultAction',
    'ThreatIDDefaultAction',
    'ThreatTypeDefaultAction'
)

function Get-RegistrySubtreeFingerprint {
    param([string]$RelativePath)

    $parts = New-Object 'System.Collections.Generic.List[string]'

    try {
        $root = Open-LocalMachineRegistryKey -SubKeyPath $RelativePath
        if (-not $root) { return 'MISSING' }
        Add-RegistryKeyFingerprint -Key $root -Prefix $RelativePath -Parts $parts
        $root.Close()
    } catch {
        return 'ERROR'
    }

    if ($parts.Count -eq 0) { return 'EMPTY' }
    return ($parts | Sort-Object) -join '|'
}

function Get-DefenderRegistryMonitorLabels {
    $labels = @{}
    foreach ($root in $script:DefenderExclusionsRegRoots) {
        $labels[$root] = "Defender Exclusions registry ($root)"
    }
    foreach ($root in $script:DefenderThreatsRegRoots) {
        $labels[$root] = "Defender Threats registry ($root)"
    }
    return $labels
}

function Get-DefenderRegistryFingerprints {
    $fps = @{}
    foreach ($root in ($script:DefenderExclusionsRegRoots + $script:DefenderThreatsRegRoots)) {
        $fps[$root] = Get-RegistrySubtreeFingerprint -RelativePath $root
    }
    return $fps
}

function Get-AllowedDefenderThreats {
    $list = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($relPath in @(
        'SOFTWARE\Microsoft\Windows Defender\Exclusions\Threats',
        'SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions\Threats'
    )) {
        try {
            $key = Open-LocalMachineRegistryKey -SubKeyPath $relPath
            if (-not $key) { continue }
            foreach ($name in $key.GetValueNames()) {
                if ($name) { [void]$list.Add("$relPath -> $name") }
            }
            foreach ($subName in $key.GetSubKeyNames()) {
                [void]$list.Add("$relPath\$subName")
            }
            $key.Close()
        } catch {}
    }

    foreach ($root in $script:DefenderThreatsRegRoots) {
        try {
            $key = Open-LocalMachineRegistryKey -SubKeyPath $root
            if (-not $key) { continue }
            foreach ($subName in $key.GetSubKeyNames()) {
                if ($script:DefenderThreatsSystemSubkeys -contains $subName) { continue }
                if ($subName -match '(?i)^\{?[0-9A-F-]{36}\}?$|^\d+$') {
                    [void]$list.Add("$root\$subName")
                }
            }
            $key.Close()
        } catch {}
    }

    return @($list)
}

function Get-DefenderStatusAlerts {
    $alerts = @()

    try {
        $def = Get-MpComputerStatus -ErrorAction Stop
        if (-not $def.RealTimeProtectionEnabled) {
            $alerts += 'FAILURE: Real-time protection disabled'
        }
        if (-not $def.IsTamperProtected) {
            $alerts += 'WARNING: Tamper protection disabled'
        }
    } catch {
        $alerts += 'WARNING: Defender status unavailable'
    }

    foreach ($disableKey in @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender',
        'HKLM:\SOFTWARE\Microsoft\Windows Defender'
    )) {
        try {
            $disabled = Get-ItemPropertyValue -Path $disableKey -Name 'DisableAntiSpyware' -ErrorAction Stop
            if ($disabled -eq 1) { $alerts += 'FAILURE: DisableAntiSpyware active' }
        } catch {}
    }

    return $alerts
}

function Get-RegistryToolProcessHits {
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $messages = @()

    foreach ($procName in @('regedit.exe', 'reg.exe')) {
        try {
            Get-CimInstance Win32_Process -Filter "Name='$procName'" -ErrorAction Stop | ForEach-Object {
                $procId = [int]$_.ProcessId
                if (-not $seen.Add($procId)) { return }
                $path = [string]$_.ExecutablePath
                $cmd = [string]$_.CommandLine
                $label = "$procName (PID $procId)"
                if ($path) { $label += " -> $path" }
                if ($cmd) { $label += " [$cmd]" }
                $messages += $label
            }
        } catch {}
    }

    return $messages
}

function Get-CheatFolderHits {
    $hits = New-Object 'System.Collections.Generic.HashSet[string]'
    $scanPaths = @(
        (Join-Path $env:USERPROFILE "Downloads"),
        (Join-Path $env:USERPROFILE "Desktop"),
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:ProgramData,
        $env:TEMP,
        "$env:SystemDrive\"
    )

    foreach ($scanPath in $scanPaths) {
        if (-not (Test-Path $scanPath)) { continue }

        $maxDepth = 2
        if ($scanPath -eq "$env:SystemDrive\") { $maxDepth = 1 }

        Get-ChildItem -Path $scanPath -Directory -Recurse -Depth $maxDepth -ErrorAction SilentlyContinue | ForEach-Object {
            $nameLower = $_.Name.ToLower()
            $matched = Get-MatchedCheatKeyword -Text $nameLower -FolderName
            if ($matched) { [void]$hits.Add($_.FullName) }
        }
    }

    return @($hits)
}

function Get-BamRegistryFingerprints {
    $fps = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $roots = @(
        'SYSTEM\CurrentControlSet\Services\bam\State\UserSettings',
        'SYSTEM\CurrentControlSet\Services\dam\State\UserSettings'
    )

    foreach ($root in $roots) {
        try {
            $rootKey = Open-LocalMachineRegistryKey -SubKeyPath $root
            if (-not $rootKey) { continue }

            foreach ($sidName in $rootKey.GetSubKeyNames()) {
                if ($sidName -eq 'S-1-5-18') { continue }
                $sidKey = $rootKey.OpenSubKey($sidName)
                if (-not $sidKey) { continue }

                foreach ($valueName in $sidKey.GetValueNames()) {
                    if ($valueName) { [void]$fps.Add("$root|$sidName|$valueName") }
                }
                $sidKey.Close()
            }
            $rootKey.Close()
        } catch {}
    }

    return @($fps)
}

function Get-PrefetchFileNames {
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $prefetchPath = "$env:WINDIR\Prefetch"
    if (-not (Test-Path $prefetchPath)) { return @($names) }

    try {
        Get-ChildItem -Path $prefetchPath -Filter "*.pf" -ErrorAction Stop | ForEach-Object {
            [void]$names.Add($_.Name)
        }
    } catch {}

    return @($names)
}

function Get-TamperLogEvents {
    param([datetime]$Since)

    $events = @()
    $filters = @(
        @{ LogName = 'Security'; Id = 1102 },
        @{ LogName = 'System'; Id = 104 },
        @{ LogName = 'Microsoft-Windows-Eventlog/Operational'; Id = 104 }
    )

    foreach ($filter in $filters) {
        try {
            $filter.StartTime = $Since
            Get-WinEvent -FilterHashtable $filter -ErrorAction Stop | ForEach-Object { $events += $_ }
        } catch {}
    }

    try {
        Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-Sysmon/Operational'
            Id        = 23
            StartTime = $Since
        } -ErrorAction Stop | Where-Object {
            $_.Message -match '(?i)\\Prefetch\\|\\bam\\|\\dam\\|UserSettings'
        } | ForEach-Object { $events += $_ }
    } catch {}

    return $events
}

function Write-MonitorAlert {
    param(
        [string]$Message,
        [string]$LogFile,
        [string]$Color = 'White'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
    try {
        Add-Content -LiteralPath $LogFile -Value "[$timestamp] $Message" -ErrorAction Stop
    } catch {
        $fallback = Join-Path $env:TEMP 'loc_tier1_security_events.log'
        try { Add-Content -LiteralPath $fallback -Value "[$timestamp] $Message" -ErrorAction SilentlyContinue } catch {}
    }
}

$script:CursorSchemeValueNames = @(
    '(Default)', 'Arrow', 'Help', 'AppStarting', 'Wait', 'Crosshair', 'IBeam',
    'NWPen', 'No', 'SizeNS', 'SizeWE', 'SizeNWSE', 'SizeNESW', 'SizeAll',
    'UpArrow', 'Hand', 'CursorBaseSize'
)

function Expand-CursorPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Get-CursorSchemeState {
    $state = @{}
    $keyPath = 'HKCU:\Control Panel\Cursors'
    if (-not (Test-Path $keyPath)) { return $state }

    foreach ($name in $script:CursorSchemeValueNames) {
        try {
            $state[$name] = [string](Get-ItemPropertyValue -Path $keyPath -Name $name -ErrorAction Stop)
        } catch {
            $state[$name] = ''
        }
    }
    return $state
}

function Get-CursorSchemeChanges {
    param(
        [hashtable]$Baseline,
        [hashtable]$Current
    )

    $changes = @()
    foreach ($name in $script:CursorSchemeValueNames) {
        $old = if ($Baseline.ContainsKey($name)) { [string]$Baseline[$name] } else { '' }
        $new = if ($Current.ContainsKey($name)) { [string]$Current[$name] } else { '' }
        if ($old -eq $new) { continue }

        $displayOld = Expand-CursorPath $old
        $displayNew = Expand-CursorPath $new
        $msg = "$name changed: '$displayOld' -> '$displayNew'"

        if ($displayNew -match '(?i)\.(cur|ani)$' -and $displayNew -notmatch '(?i)\\windows\\cursors\\') {
            $msg += ' [non-standard cursor path]'
        }

        $kw = Get-MatchedCheatKeyword -Text $displayNew
        if ($kw) { $msg += " [keyword: $kw]" }

        $changes += $msg
    }
    return $changes
}

$script:NvidiaShadowPlayFtsRegPath = 'SOFTWARE\NVIDIA Corporation\Global\NvApp\ShadowPlay\FTS'
$script:NvidiaStreamproofGuid = '497B8458-4244-4EE6-BFEA-F3D2BA294F21'
$script:NvidiaStreamproofValues = @(36, 0x24)

function Test-NvidiaGpuPresent {
    try {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object -ExpandProperty Name
        foreach ($gpu in $gpus) {
            if ($gpu -match '(?i)nvidia') { return $true }
        }
    } catch {}
    return $false
}

function Get-NvidiaShadowPlayFtsState {
    $state = @{
        Exists = $false
        Values = @{}
    }

    try {
        $key = Open-LocalMachineRegistryKey -SubKeyPath $script:NvidiaShadowPlayFtsRegPath
        if (-not $key) { return $state }

        $state.Exists = $true
        foreach ($name in $key.GetValueNames()) {
            $raw = $key.GetValue($name)
            if ($raw -is [int]) {
                $state.Values[$name] = [int]$raw
            } elseif ($raw -is [byte[]] -and $raw.Length -ge 4) {
                $state.Values[$name] = [BitConverter]::ToInt32($raw, 0)
            } else {
                $state.Values[$name] = [string]$raw
            }
        }
        $key.Close()
    } catch {}

    return $state
}

function Get-NvidiaShadowPlayFtsFingerprint {
    $state = Get-NvidiaShadowPlayFtsState
    if (-not $state.Exists) { return 'MISSING' }

    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in ($state.Values.Keys | Sort-Object)) {
        $parts.Add("$name=$($state.Values[$name])")
    }
    if ($parts.Count -eq 0) { return 'EMPTY' }
    return ($parts -join '|')
}

function Get-NvidiaShadowPlayFtsAlerts {
    $alerts = @()
    $state = Get-NvidiaShadowPlayFtsState
    $nvidiaGpu = Test-NvidiaGpuPresent

    if (-not $state.Exists) {
        if ($nvidiaGpu) {
            $alerts += 'WARNING: ShadowPlay FTS key missing (NVIDIA GPU detected)'
        } else {
            $alerts += 'SUCCESS: NVIDIA ShadowPlay N/A'
        }
        return $alerts
    }

    foreach ($entry in $state.Values.GetEnumerator()) {
        $nameNorm = $entry.Key.Trim('{}').ToLower()
        if ($nameNorm -ne $script:NvidiaStreamproofGuid.ToLower()) { continue }
        if ($entry.Value -isnot [int]) { continue }
        if ($script:NvidiaStreamproofValues -contains $entry.Value) {
            $alerts += "FAILURE: NVIDIA streamproof bypass ($($entry.Key)=$($entry.Value))"
        }
    }

    if ($alerts.Count -eq 0) {
        $alerts += 'SUCCESS: ShadowPlay FTS clean'
    }

    return $alerts
}

function Get-MainCplProcessHits {
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $messages = @()

    foreach ($procName in @('rundll32.exe', 'control.exe')) {
        try {
            Get-CimInstance Win32_Process -Filter "Name='$procName'" -ErrorAction Stop | ForEach-Object {
                $cmd = [string]$_.CommandLine
                if ($cmd -notmatch '(?i)main\.cpl') { return }
                if (-not $seen.Add([int]$_.ProcessId)) { return }
                $messages += "main.cpl opened PID $($_.ProcessId)"
            }
        } catch {}
    }

    return $messages
}

$script:CheatKeywords = @(
    'matcha', 'isabelle', 'severe', 'matrix', 'clarity', 'loader', 'photon', 'valex', 'aimmy',
    'keyauth', 'melatonin', 'evolve', 'serotonin', 'dx9ware', 'unicore', 'monolith', 'skript',
    'ntfsdump', 'atlanta', 'eulen', 'hammafia', 'redengine', 'susano', 'bypass'
)

$script:FolderOnlyKeywords = @('map')

function Test-KeywordTokenMatch {
    param(
        [string]$Text,
        [string]$Keyword
    )

    if ([string]::IsNullOrWhiteSpace($Text) -or [string]::IsNullOrWhiteSpace($Keyword)) { return $false }
    $escaped = [regex]::Escape($Keyword)
    return [regex]::IsMatch($Text, "(?i)(^|[\\_\s\-\.])(($escaped))($|[\\_\s\-\.])")
}

function Test-TrustedProcessPath {
    param([string]$ExecutablePath)

    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) { return $true }
    $path = $ExecutablePath.ToLower().Replace('/', '\')
    $prefixes = @(
        "$($env:SystemRoot.ToLower())\",
        "$($env:ProgramFiles.ToLower())\"
    )
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) { $prefixes += "$($pf86.ToLower())\" }
    foreach ($prefix in $prefixes) {
        if ($path.StartsWith($prefix)) { return $true }
    }
    return $false
}

$script:MasqueradeProcessPaths = @{
    'svchost.exe'       = @('\windows\system32\svchost.exe', '\windows\syswow64\svchost.exe')
    'explorer.exe'      = @('\windows\explorer.exe')
    'csrss.exe'         = @('\windows\system32\csrss.exe')
    'lsass.exe'         = @('\windows\system32\lsass.exe')
    'services.exe'      = @('\windows\system32\services.exe')
    'smss.exe'          = @('\windows\system32\smss.exe')
    'winlogon.exe'      = @('\windows\system32\winlogon.exe')
    'dwm.exe'           = @('\windows\system32\dwm.exe')
    'taskhostw.exe'     = @('\windows\system32\taskhostw.exe')
    'runtimebroker.exe' = @('\windows\system32\runtimebroker.exe')
    'conhost.exe'       = @('\windows\system32\conhost.exe', '\windows\syswow64\conhost.exe')
    'dllhost.exe'       = @('\windows\system32\dllhost.exe', '\windows\syswow64\dllhost.exe')
    'spoolsv.exe'       = @('\windows\system32\spoolsv.exe')
    'wininit.exe'       = @('\windows\system32\wininit.exe')
    'sihost.exe'        = @('\windows\system32\sihost.exe')
    'fontdrvhost.exe'   = @('\windows\system32\fontdrvhost.exe')
}

function Get-MatchedCheatKeyword {
    param(
        [string]$Text,
        [switch]$FolderName
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $lower = $Text.ToLower()

    if ($FolderName) {
        foreach ($kw in ($script:CheatKeywords + $script:FolderOnlyKeywords)) {
            if ($lower -like "*$kw*") { return $kw }
        }
        return $null
    }

    foreach ($kw in $script:CheatKeywords) {
        if ($kw.Length -le 4) {
            if (Test-KeywordTokenMatch -Text $lower -Keyword $kw) { return $kw }
        } elseif ($lower -like "*$kw*") {
            return $kw
        }
    }
    return $null
}

function Test-MasqueradeProcessPath {
    param(
        [string]$ProcessName,
        [string]$ExecutablePath
    )

    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) { return $null }
    $nameLower = $ProcessName.ToLower()
    if (-not $script:MasqueradeProcessPaths.ContainsKey($nameLower)) { return $null }

    $pathLower = $ExecutablePath.ToLower().Replace('/', '\')
    foreach ($legitSuffix in $script:MasqueradeProcessPaths[$nameLower]) {
        if ($pathLower.EndsWith($legitSuffix)) { return $null }
    }

    return "Windows process '$ProcessName' running from non-standard path: $ExecutablePath"
}

function Get-SuspiciousProcessHits {
    $hits = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $messages = @()

    try {
        Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
            $procName = $_.Name
            $procPath = $_.ExecutablePath
            $procId = $_.ProcessId

            $masquerade = Test-MasqueradeProcessPath -ProcessName $procName -ExecutablePath $procPath
            if ($masquerade) {
                $key = "masquerade|$procName|$procPath"
                if ($hits.Add($key)) { $messages += "FAILURE: Masquerade $procName (PID $procId)" }
            }

            $nameKw = Get-MatchedCheatKeyword -Text $procName
            if ($nameKw) {
                $key = "name|$procName|$nameKw"
                if ($hits.Add($key)) { $messages += "FAILURE: $procName (PID $procId) [$nameKw]" }
            }

            if ($procPath -and -not (Test-TrustedProcessPath -ExecutablePath $procPath)) {
                $pathKw = Get-MatchedCheatKeyword -Text $procPath
                if ($pathKw) {
                    $key = "path|$procPath|$pathKw|$procId"
                    if ($hits.Add($key)) { $messages += "FAILURE: $procPath (PID $procId) [$pathKw]" }
                }
            }
        }
    } catch {
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            $nameKw = Get-MatchedCheatKeyword -Text $_.Name
            if ($nameKw) {
                $key = "name|$($_.Name)|$nameKw"
                if ($hits.Add($key)) { $messages += "FAILURE: $($_.Name) (PID $($_.Id)) [$nameKw]" }
            }
        }
    }

    return $messages
}

function Get-ProcessSuspiciousReasons {
    param(
        [string]$ProcessName,
        [string]$ExecutablePath
    )

    $reasons = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
        if ($ProcessName -notmatch '(?i)^(System|Registry|Secure System|Memory Compression|Idle)$') {
            [void]$reasons.Add('no image path')
        }
    } else {
        $leaf = Split-Path $ExecutablePath -Leaf
        if ($ProcessName -and $leaf -and ($ProcessName.ToLower() -ne $leaf.ToLower())) {
            [void]$reasons.Add('name/path mismatch')
        }
    }

    if (Test-MasqueradeProcessPath -ProcessName $ProcessName -ExecutablePath $ExecutablePath) {
        [void]$reasons.Add('masquerade')
    }

    $nameKw = Get-MatchedCheatKeyword -Text $ProcessName
    if ($nameKw) { [void]$reasons.Add($nameKw) }

    if ($ExecutablePath -and -not (Test-TrustedProcessPath -ExecutablePath $ExecutablePath)) {
        $pathKw = Get-MatchedCheatKeyword -Text $ExecutablePath
        if ($pathKw) { [void]$reasons.Add($pathKw) }
    }

    return @($reasons)
}

function Test-UserLandProcessPath {
    param([string]$ExecutablePath)

    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) { return $false }
    $path = $ExecutablePath.ToLower().Replace('/', '\')
    foreach ($marker in @('\downloads\', '\desktop\', '\appdata\', '\temp\', '\programdata\')) {
        if ($path -like "*$marker*") { return $true }
    }
    return $false
}

function Get-ProcessSnapshot {
    $snap = @{}
    try {
        Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
            $procId = [int]$_.ProcessId
            $path = [string]$_.ExecutablePath
            $name = [string]$_.Name
            $reasons = @(Get-ProcessSuspiciousReasons -ProcessName $name -ExecutablePath $path)
            $snap[$procId] = @{
                Name       = $name
                Path       = $path
                Reasons    = $reasons
                UserLand   = Test-UserLandProcessPath -ExecutablePath $path
                Suspicious = ($reasons.Count -gt 0)
            }
        }
    } catch {}
    return $snap
}

function Update-ProcessChangeMonitor {
    param(
        [hashtable]$Previous,
        [hashtable]$Current,
        [hashtable]$Watched,
        [string]$LogFile
    )

    foreach ($procId in $Current.Keys) {
        if ($Previous.ContainsKey($procId)) { continue }

        $proc = $Current[$procId]
        $label = "$($proc.Name) (PID $procId)"
        if ($proc.Path) { $label += " -> $($proc.Path)" }

        if ($proc.Suspicious) {
            $tag = $proc.Reasons -join ', '
            Write-MonitorAlert -Message "Started [$tag]: $label" -LogFile $LogFile -Color Red
            $Watched[$procId] = $proc
        } elseif ($proc.UserLand) {
            Write-MonitorAlert -Message "Started: $label" -LogFile $LogFile -Color Yellow
            $Watched[$procId] = $proc
        }
    }

    foreach ($procId in $Previous.Keys) {
        if ($Current.ContainsKey($procId)) { continue }

        $proc = $Previous[$procId]
        if (-not $proc.Suspicious -and -not $proc.UserLand -and -not $Watched.ContainsKey($procId)) { continue }

        $label = "$($proc.Name) (PID $procId)"
        if ($proc.Path) { $label += " -> $($proc.Path)" }
        if ($proc.Reasons.Count -gt 0) {
            Write-MonitorAlert -Message "Exited [$($proc.Reasons -join ', ')]: $label" -LogFile $LogFile -Color $(if ($proc.Suspicious) { 'Red' } else { 'Yellow' })
        } else {
            Write-MonitorAlert -Message "Exited: $label" -LogFile $LogFile -Color Yellow
        }
        if ($Watched.ContainsKey($procId)) { $Watched.Remove($procId) | Out-Null }
    }
}

$script:BaselineBamKeys = @{}
$script:BaselinePrefetchFiles = @{}

# ===============================
# Step 1 Indicator
# ===============================
Write-Host "[ Step 1 of 3 - System Check ]" -ForegroundColor Cyan
Write-Host ""

# ===============================
# Loading Bar
# ===============================
for ($i = 0; $i -le 20; $i++) {
    $percent = $i * 5
    $bar = ("#" * $i) + ("-" * (20 - $i))
    Write-Host "`r[ $bar ] $percent%" -NoNewline
    Start-Sleep -Milliseconds 120
}
Write-Host "`n"

# ===============================
# Initialize
# ===============================
$passedChecks = 0
$totalChecks  = 0

$moduleOutput          = @()
$cpuGpuOutput          = @()
$processOutput         = @()
$keyAuthOutput         = @()
$powershellSigOutput   = @()
$osOutput              = @()
$vmOutput              = @()
$defenderOutput        = @()
$exclusionsOutput      = @()
$allowedThreatsOutput  = @()
$memoryIntegrityOutput = @()
$nvidiaOutput          = @()
$registryOutput        = @()

# ===============================
# Module Check
# ===============================
$totalChecks++
$modules = @(
    "Microsoft.PowerShell.Operation.Validation",
    "PackageManagement",
    "Pester",
    "PowerShellGet",
    "PSReadline"
)
$moduleFails = @()
foreach ($mod in $modules) {
    if (-not (Get-Module -ListAvailable -Name $mod -ErrorAction SilentlyContinue)) {
        $moduleFails += $mod
    }
}
if ($moduleFails.Count -eq 0) {
    $moduleOutput += "SUCCESS: Modules OK"
    $passedChecks++
} else {
    foreach ($fail in $moduleFails) { $moduleOutput += "FAILURE: Missing module $fail" }
}

# ===============================
# CPU & GPU Detections
# ===============================
try {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name
    if ($cpu) { $cpuGpuOutput += "SUCCESS: CPU detected -> $cpu" }

    $gpus = Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name
    foreach ($gpu in $gpus) {
        $cpuGpuOutput += "SUCCESS: GPU detected -> $gpu"
    }
} catch {
    $cpuGpuOutput += "WARNING: Unable to query CPU/GPU information."
}

# ===============================
# Windows Defender
# ===============================
$totalChecks++
try {
    $def = Get-MpComputerStatus
    if ($def.RealTimeProtectionEnabled) {
        $defenderOutput += "SUCCESS: Windows Defender real-time protection enabled."
        $passedChecks++
    } else {
        $defenderOutput += "FAILURE: Windows Defender real-time protection disabled."
    }

    if (-not $def.IsTamperProtected) {
        $defenderOutput += "WARNING: Tamper protection disabled."
    }
} catch {
    $defenderOutput += "WARNING: Unable to query Defender."
}

foreach ($disableKey in @(
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender',
    'HKLM:\SOFTWARE\Microsoft\Windows Defender'
)) {
    try {
        $disabled = Get-ItemPropertyValue -Path $disableKey -Name 'DisableAntiSpyware' -ErrorAction Stop
        if ($disabled -eq 1) { $defenderOutput += "FAILURE: DisableAntiSpyware active." }
    } catch {}
}

# ===============================
# Defender Exclusions (T2 method: cmdlet + registry)
# ===============================
$totalChecks++
try {
    $allExclusions = @(Get-Exclusions)

    if ($allExclusions.Count -eq 0) {
        $exclusionsOutput += "SUCCESS: No Defender exclusions."
        $passedChecks++
    } else {
        foreach ($excl in $allExclusions) {
            $exclKw = Get-MatchedCheatKeyword -Text $excl
            if ($exclKw) {
                $exclusionsOutput += "FAILURE: Defender exclusion [$exclKw] -> $excl"
            } else {
                $exclusionsOutput += "FAILURE: Defender exclusion -> $excl"
            }
        }
    }
} catch {
    $exclusionsOutput += "WARNING: Exclusions check failed."
}

# ===============================
# Allowed Threats
# ===============================
$totalChecks++
try {
    $allowedThreats = @(Get-AllowedDefenderThreats)
    if ($allowedThreats.Count -eq 0) {
        $allowedThreatsOutput += "SUCCESS: No allowed threats."
        $passedChecks++
    } else {
        foreach ($threat in $allowedThreats) {
            $allowedThreatsOutput += "FAILURE: Allowed threat -> $threat"
        }
    }
} catch {
    $allowedThreatsOutput += "WARNING: Allowed threats check failed."
}

# ===============================
# Memory Integrity
# ===============================
$totalChecks++
try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
    $enabled = Get-ItemPropertyValue -Path $regPath -Name Enabled
    if ($enabled -eq 1) {
        $memoryIntegrityOutput += "SUCCESS: Memory Integrity enabled."
        $passedChecks++
    } else {
        $memoryIntegrityOutput += "FAILURE: Memory Integrity disabled."
    }
} catch {
    $memoryIntegrityOutput += "WARNING: Memory Integrity status unavailable."
}

# ===============================
# NVIDIA ShadowPlay FTS (streamproof bypass)
# ===============================
$totalChecks++
foreach ($line in (Get-NvidiaShadowPlayFtsAlerts)) {
    $nvidiaOutput += $line
    if ($line -like 'SUCCESS*') { $passedChecks++ }
}

# ===============================
# Process Scan
# ===============================
$totalChecks++
$procHits = @(Get-SuspiciousProcessHits)
if ($procHits.Count -eq 0) {
    $processOutput += "SUCCESS: Processes clean"
    $passedChecks++
} else {
    $processOutput += $procHits
}

# ===============================
# KeyAuth Check
# ===============================
$totalChecks++
try {
    $keyAuthHits = @()
    $keyAuthRoots = @(
        'C:\ProgramData\KeyAuth',
        (Join-Path $env:ProgramData 'KeyAuth')
    )
    foreach ($keyRoot in ($keyAuthRoots | Select-Object -Unique)) {
        if (-not (Test-Path $keyRoot)) { continue }
        Get-ChildItem $keyRoot -Recurse -Directory -Depth 3 -ErrorAction SilentlyContinue | ForEach-Object {
            $keyAuthHits += $_.FullName
        }
    }
    if ($keyAuthHits.Count -eq 0) {
        $keyAuthOutput += "SUCCESS: KeyAuth clean"
        $passedChecks++
    } else {
        foreach ($hit in ($keyAuthHits | Select-Object -Unique)) {
            $keyAuthOutput += "FAILURE: KeyAuth $hit"
        }
    }
} catch {
    $keyAuthOutput += "WARNING: KeyAuth check failed"
}

# ===============================
# Display Results
# ===============================
Write-Section "Modules" $moduleOutput
Write-Section "CPU & GPU Detections" $cpuGpuOutput
Write-Section "Windows Defender" $defenderOutput
Write-Section "Defender Exclusions" $exclusionsOutput
Write-Section "Allowed Threats" $allowedThreatsOutput
Write-Section "Memory Integrity" $memoryIntegrityOutput
Write-Section "NVIDIA ShadowPlay" $nvidiaOutput
Write-Section "Process Scan" $processOutput
Write-Section "KeyAuth Check" $keyAuthOutput

# ===============================
# Success Rate
# ===============================
if ($totalChecks -ne 0) { $successRate = [math]::Round(($passedChecks / $totalChecks) * 100) } else { $successRate = 0 }
Write-Host "Overall Success Rate: $successRate%" -ForegroundColor Cyan
Write-Host ""

Write-Host "Press Enter to continue..." -ForegroundColor Yellow
[Console]::ReadLine() | Out-Null

# ===============================
# STEP 2 – PROCESS EXPLORER
# ===============================
Clear-Host
Write-Host "[ Step 2 of 3 - Process Explorer ]" -ForegroundColor Cyan
Write-Host ""

$procDir = "$env:TEMP\ProcessExplorer"
$procExe = "$procDir\procexp64.exe"
$procZip = "$env:TEMP\procexp.zip"
$procURL = "https://download.sysinternals.com/files/ProcessExplorer.zip"

if (-not (Test-Path $procExe)) {
    if (-not (Invoke-ToolDownload -Url $procURL -ZipPath $procZip -DestDir $procDir)) {
        Write-Host "WARNING: Process Explorer unavailable" -ForegroundColor Yellow
    }
}

if (Test-Path $procExe) {
    Write-Host "Launching Process Explorer..." -ForegroundColor Green
    Write-Host ""
    $proc = Start-Process -FilePath $procExe -ArgumentList "/accepteula" -PassThru
    Wait-Process -Id $proc.Id
    Write-Host ""
    Write-Host "Process Explorer closed." -ForegroundColor Cyan
} else {
    Write-Host "WARNING: Process Explorer not found." -ForegroundColor Yellow
}

Write-Host "Press Enter to continue..." -ForegroundColor Yellow
[Console]::ReadLine() | Out-Null

# ===============================
# STEP 3 – LIVE MONITOR
# ===============================
Clear-Host
Write-Host "[ Step 3 of 3 - Live Monitor ]" -ForegroundColor Cyan
Write-Host ""
Write-Host "Keep this window open during the match. Must show again after match." -ForegroundColor Yellow
Write-Host ""

$logFile = Join-Path $env:ProgramData 'loc_tier1_security_events.log'
try {
    if (-not (Test-Path $logFile)) { New-Item -Path $logFile -ItemType File -Force | Out-Null }
    Write-MonitorAlert -Message "LOC Tier 1 v$($script:LocTier1Version) monitor started" -LogFile $logFile
} catch {
    $logFile = Join-Path $env:TEMP 'loc_tier1_security_events.log'
    if (-not (Test-Path $logFile)) { New-Item -Path $logFile -ItemType File -Force | Out-Null }
    Write-Host "WARNING: Logging to $logFile" -ForegroundColor Yellow
    Write-MonitorAlert -Message "LOC Tier 1 v$($script:LocTier1Version) monitor started" -LogFile $logFile
}

Register-WmiEvent -Class Win32_VolumeChangeEvent -SourceIdentifier USBChange | Out-Null
trap {
    Get-EventSubscriber -SourceIdentifier USBChange -ErrorAction SilentlyContinue |
        Unregister-Event -Force -ErrorAction SilentlyContinue
    break
}

foreach ($fp in (Get-BamRegistryFingerprints)) { $script:BaselineBamKeys[$fp] = $true }
foreach ($pf in (Get-PrefetchFileNames)) { $script:BaselinePrefetchFiles[$pf] = $true }

$previousExclusions = @{}
foreach ($ex in (Get-Exclusions)) { $previousExclusions[$ex] = $true }
$knownCheatFolders = @{}
foreach ($folder in (Get-CheatFolderHits)) {
    $knownCheatFolders[$folder] = $true
}
$reportedBamDeletions = @{}
$reportedPrefetchDeletions = @{}
$reportedTamperEvents = @{}
$reportedPrefetchHits = @{}
$reportedCursorChanges = @{}
$reportedMainCplHits = @{}
$baselineCursorScheme = Get-CursorSchemeState
$baselineNvidiaFts = Get-NvidiaShadowPlayFtsFingerprint
$reportedNvidiaFtsChanges = @{}
$reportedNvidiaStreamproof = @{}
$reportedDefenderStatus = @{}
$reportedRegistryTools = @{}
$reportedDefenderRegChanges = @{}
$baselineDefenderReg = Get-DefenderRegistryFingerprints
$defenderRegLabels = Get-DefenderRegistryMonitorLabels
$lastProcessSnapshot = Get-ProcessSnapshot
$watchedProcesses = @{}
$monitoringStart = Get-Date
$folderScanCounter = 0
$deletionScanCounter = 0
$processChangeCounter = 0
$mainCplScanCounter = 0
$nvidiaScanCounter = 0
$defenderScanCounter = 0

foreach ($line in (Get-NvidiaShadowPlayFtsAlerts)) {
    if ($line -like 'FAILURE*') {
        $reportedNvidiaStreamproof[$line] = $true
        Write-MonitorAlert -Message $line -LogFile $logFile -Color Red
    }
}

foreach ($line in (Get-DefenderStatusAlerts)) {
    if ($line -like 'FAILURE*' -or $line -like 'WARNING*') {
        $reportedDefenderStatus[$line] = $true
        $color = if ($line -like 'FAILURE*') { 'Red' } else { 'Yellow' }
        Write-MonitorAlert -Message $line -LogFile $logFile -Color $color
    }
}

while ($true) {
    $usbEvent = Wait-Event -SourceIdentifier USBChange -Timeout 1
    if ($usbEvent) {
        $eventType = $usbEvent.SourceEventArgs.NewEvent.EventType
        $driveLetter = $usbEvent.SourceEventArgs.NewEvent.DriveName

        if ($eventType -eq 2) {
            Write-MonitorAlert -Message "USB in $driveLetter" -LogFile $logFile
        } elseif ($eventType -eq 3) {
            Write-MonitorAlert -Message "USB out $driveLetter" -LogFile $logFile
        }

        Remove-Event -EventIdentifier $usbEvent.EventIdentifier -ErrorAction SilentlyContinue
    }

    try {
        $currentExclusions = @{}
        foreach ($ex in (Get-Exclusions)) { $currentExclusions[$ex] = $true }

        foreach ($ex in $currentExclusions.Keys) {
            if (-not $previousExclusions.ContainsKey($ex)) {
                $exclKw = Get-MatchedCheatKeyword -Text $ex
                if ($exclKw) {
                    Write-MonitorAlert -Message "Exclusion added [$exclKw]: $ex" -LogFile $logFile -Color Red
                } else {
                    Write-MonitorAlert -Message "Exclusion added: $ex" -LogFile $logFile -Color Red
                }
            }
        }

        foreach ($ex in $previousExclusions.Keys) {
            if (-not $currentExclusions.ContainsKey($ex)) {
                Write-MonitorAlert -Message "Exclusion removed: $ex" -LogFile $logFile -Color Yellow
            }
        }

        $previousExclusions = $currentExclusions
    } catch {}

    foreach ($change in (Get-CursorSchemeChanges -Baseline $baselineCursorScheme -Current (Get-CursorSchemeState))) {
        if (-not $reportedCursorChanges.ContainsKey($change)) {
            $reportedCursorChanges[$change] = $true
            Write-MonitorAlert -Message "Cursor changed: $change" -LogFile $logFile -Color Red
        }
    }

    $mainCplScanCounter++
    if ($mainCplScanCounter -ge 5) {
        $mainCplScanCounter = 0
        foreach ($hit in (Get-MainCplProcessHits)) {
            if (-not $reportedMainCplHits.ContainsKey($hit)) {
                $reportedMainCplHits[$hit] = $true
                Write-MonitorAlert -Message $hit -LogFile $logFile -Color Yellow
            }
        }

        foreach ($hit in (Get-RegistryToolProcessHits)) {
            if (-not $reportedRegistryTools.ContainsKey($hit)) {
                $reportedRegistryTools[$hit] = $true
                Write-MonitorAlert -Message "Registry tool: $hit" -LogFile $logFile -Color Red
            }
        }
    }

    $defenderScanCounter++
    if ($defenderScanCounter -ge 5) {
        $defenderScanCounter = 0

        try {
            foreach ($line in (Get-DefenderStatusAlerts)) {
                if (-not $reportedDefenderStatus.ContainsKey($line)) {
                    $reportedDefenderStatus[$line] = $true
                    $color = if ($line -like 'FAILURE*') { 'Red' } else { 'Yellow' }
                    Write-MonitorAlert -Message $line -LogFile $logFile -Color $color
                }
            }

            foreach ($entry in (Get-DefenderRegistryFingerprints).GetEnumerator()) {
                $root = $entry.Key
                $currentFp = $entry.Value
                $baselineFp = $baselineDefenderReg[$root]
                if ($currentFp -eq $baselineFp) { continue }

                $changeKey = "$root|$currentFp"
                if ($reportedDefenderRegChanges.ContainsKey($changeKey)) { continue }
                $reportedDefenderRegChanges[$changeKey] = $true

                $label = if ($defenderRegLabels.ContainsKey($root)) { $defenderRegLabels[$root] } else { $root }
                Write-MonitorAlert -Message "$label changed: $currentFp" -LogFile $logFile -Color Red
            }
        } catch {}
    }

    $folderScanCounter++
    if ($folderScanCounter -ge 30) {
        $folderScanCounter = 0
        foreach ($folder in (Get-CheatFolderHits)) {
            if (-not $knownCheatFolders.ContainsKey($folder)) {
                $knownCheatFolders[$folder] = $true
                Write-MonitorAlert -Message "Cheat folder: $folder" -LogFile $logFile -Color Red
            }
        }
    }

    $processChangeCounter++
    if ($processChangeCounter -ge 3) {
        $processChangeCounter = 0
        $currentProcessSnapshot = Get-ProcessSnapshot
        Update-ProcessChangeMonitor -Previous $lastProcessSnapshot -Current $currentProcessSnapshot -Watched $watchedProcesses -LogFile $logFile
        $lastProcessSnapshot = $currentProcessSnapshot
    }

    $nvidiaScanCounter++
    if ($nvidiaScanCounter -ge 5) {
        $nvidiaScanCounter = 0

        foreach ($line in (Get-NvidiaShadowPlayFtsAlerts)) {
            if ($line -like 'FAILURE*') {
                if (-not $reportedNvidiaStreamproof.ContainsKey($line)) {
                    $reportedNvidiaStreamproof[$line] = $true
                    Write-MonitorAlert -Message $line -LogFile $logFile -Color Red
                }
            } elseif ($line -like 'WARNING*') {
                $warnKey = "warn|$line"
                if (-not $reportedNvidiaStreamproof.ContainsKey($warnKey)) {
                    $reportedNvidiaStreamproof[$warnKey] = $true
                    Write-MonitorAlert -Message $line -LogFile $logFile -Color Yellow
                }
            }
        }

        $currentNvidiaFts = Get-NvidiaShadowPlayFtsFingerprint
        if ($currentNvidiaFts -ne $baselineNvidiaFts -and -not $reportedNvidiaFtsChanges.ContainsKey($currentNvidiaFts)) {
            $reportedNvidiaFtsChanges[$currentNvidiaFts] = $true
            Write-MonitorAlert -Message "NVIDIA ShadowPlay FTS changed: $currentNvidiaFts" -LogFile $logFile -Color Red
            foreach ($line in (Get-NvidiaShadowPlayFtsAlerts)) {
                if ($line -like 'FAILURE*') {
                    $reportedNvidiaStreamproof[$line] = $true
                    Write-MonitorAlert -Message $line -LogFile $logFile -Color Red
                }
            }
        }
    }

    $deletionScanCounter++
    if ($deletionScanCounter -ge 10) {
        $deletionScanCounter = 0

        $currentBam = @{}
        foreach ($fp in (Get-BamRegistryFingerprints)) { $currentBam[$fp] = $true }
        foreach ($fp in $script:BaselineBamKeys.Keys) {
            if (-not $currentBam.ContainsKey($fp) -and -not $reportedBamDeletions.ContainsKey($fp)) {
                $reportedBamDeletions[$fp] = $true
                $display = ($fp -split '\|')[-1]
                Write-MonitorAlert -Message "BAM removed: $display" -LogFile $logFile -Color Red
            }
        }

        $currentPrefetch = @{}
        foreach ($pf in (Get-PrefetchFileNames)) {
            $currentPrefetch[$pf] = $true
            if (-not $script:BaselinePrefetchFiles.ContainsKey($pf) -and -not $reportedPrefetchHits.ContainsKey($pf)) {
                $pfKw = Get-MatchedCheatKeyword -Text $pf
                if ($pfKw) {
                    $reportedPrefetchHits[$pf] = $true
                    Write-MonitorAlert -Message "Prefetch added [$pfKw]: $pf" -LogFile $logFile -Color Red
                }
            }
        }
        foreach ($pf in $script:BaselinePrefetchFiles.Keys) {
            if (-not $currentPrefetch.ContainsKey($pf) -and -not $reportedPrefetchDeletions.ContainsKey($pf)) {
                $reportedPrefetchDeletions[$pf] = $true
                Write-MonitorAlert -Message "Prefetch deleted: $pf" -LogFile $logFile -Color Red
            }
        }

        foreach ($ev in (Get-TamperLogEvents -Since $monitoringStart)) {
            $eventKey = "$($ev.LogName)|$($ev.RecordId)"
            if ($reportedTamperEvents.ContainsKey($eventKey)) { continue }
            $reportedTamperEvents[$eventKey] = $true
            Write-MonitorAlert -Message "Log cleared ($($ev.Id))" -LogFile $logFile -Color Red
        }
    }
}
