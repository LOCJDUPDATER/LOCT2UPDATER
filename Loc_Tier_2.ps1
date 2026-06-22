Clear-Host

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $hostExe = (Get-Process -Id $PID).Path
    if ($PSCommandPath) {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
        Start-Process -FilePath $hostExe -ArgumentList $argList -Wait | Out-Null
        exit
    }
    $tempScript = Join-Path $env:TEMP 'Loc_Tier_2.ps1'
    try {
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/LOCJDUPDATER/LOCT2UPDATER/main/Loc_Tier_2.ps1' -OutFile $tempScript -UseBasicParsing
        Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$tempScript`"") -Wait | Out-Null
    } catch {
        Write-Warning "WinForms steps need STA mode. Use: powershell -STA -ExecutionPolicy Bypass -File `"<script.ps1>`""
    }
    exit
}

$script:WinFormsLoaded = $false
function Initialize-WinForms {
    if (-not $script:WinFormsLoaded) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $script:WinFormsLoaded = $true
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

$script:LocTier2Version = '2.5.2'

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
# ASCII Banner (LOC RECORDING POLICY T2)
# ===============================
Write-Host ' _     ___   ____   ____  _____ ____ ___  ____  ____ ___ _   _  ____ ' -ForegroundColor Cyan
Write-Host '| |   / _ \ / ___| |  _ \| ____/ ___/ _ \|  _ \|  _ \_ _| \ | |/ ___|' -ForegroundColor Cyan
Write-Host '| |  | | | | |     | |_) |  _|| |  | | | | |_) | | | | ||  \| | |  _ ' -ForegroundColor Cyan
Write-Host '| |__| |_| | |___  |  _ <| |__| |__| |_| |  _ <| |_| | || |\| | |_| |' -ForegroundColor Cyan
Write-Host '|_____\___/ \____| |_| \_\_____\____\___/|_| \_\____/___|_| \_|\____|' -ForegroundColor Cyan
Write-Host ' ____   ___  _     ___ ______   __  _____ ____  ' -ForegroundColor Cyan
Write-Host '|  _ \ / _ \| |   |_ _/ ___\ \ / / |_   _|___ \ ' -ForegroundColor Cyan
Write-Host '| |_) | | | | |    | | |    \ V /    | |   __) |' -ForegroundColor Cyan
Write-Host '|  __/| |_| | |___ | | |___  | |     | |  / __/ ' -ForegroundColor Cyan
Write-Host '|_|    \___/|_____|___\____| |_|     |_| |_____|' -ForegroundColor Cyan
Write-Host ""
Write-Host "LOC Tier 2 v$($script:LocTier2Version)" -ForegroundColor White
Write-Host ""
if (-not (Test-Admin)) {
    Write-Host "WARNING: Run as Administrator for full results." -ForegroundColor Yellow
}

# ===============================
# Loading Bar Function
# ===============================
function Show-LoadingBar {
    for ($i = 0; $i -le 20; $i++) {
        $percent = $i * 5
        $bar = ("#" * $i) + ("-" * (20 - $i))
        Write-Host "`r[ $bar ] $percent%" -NoNewline
        Start-Sleep -Milliseconds 60
    }
    Write-Host ""
}

function Write-Section {
    param($Title, $Lines)

    if (-not $Lines -or $Lines.Count -eq 0) { return }
    Write-Host $Title -ForegroundColor Cyan
    foreach ($line in $Lines) {
        if ($line -like "SUCCESS*") { Write-Host "  $line" -ForegroundColor Green }
        elseif ($line -like "FAILURE*") { Write-Host "  $line" -ForegroundColor Red }
        elseif ($line -like "WARNING*") { Write-Host "  $line" -ForegroundColor Yellow }
        else { Write-Host "  $line" -ForegroundColor Gray }
    }
    Write-Host ""
}

function Wait-NextStep {
    param(
        [string]$Prompt,
        [string]$Label
    )
    Read-Host $Prompt | Out-Null
    Clear-Host
    Write-Host $Label -ForegroundColor Cyan
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

function Get-BamDevicePath {
    param([string]$Remainder)

    foreach ($drive in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
        if ($drive.Name -notmatch '^[A-Z]$') { continue }
        $candidate = "$($drive.Name):\$Remainder"
        if (Test-Path -LiteralPath $candidate -ErrorAction SilentlyContinue) {
            return $candidate
        }
    }

    return "$env:SystemDrive\$Remainder"
}

function Get-ActivityModeratorEntries {
    param([int]$SignatureBudget = 100)

    $entries = @()
    $seen = @{}
    $signaturesChecked = 0
    $roots = @(
        'SYSTEM\CurrentControlSet\Services\bam\State\UserSettings',
        'SYSTEM\CurrentControlSet\Services\dam\State\UserSettings'
    )

    foreach ($root in $roots) {
        $rootKey = Open-LocalMachineRegistryKey -SubKeyPath $root
        if (-not $rootKey) { continue }

        foreach ($sidName in $rootKey.GetSubKeyNames()) {
            if ($sidName -eq 'S-1-5-18') { continue }

            $sidKey = $rootKey.OpenSubKey($sidName)
            if (-not $sidKey) { continue }

            foreach ($valueName in $sidKey.GetValueNames()) {
                try {
                    $raw = $sidKey.GetValue($valueName)
                    if ($raw -isnot [byte[]] -or $raw.Length -lt 8) { continue }

                    $fileTime = [BitConverter]::ToInt64($raw, 0)
                    if ($fileTime -le 0) { continue }

                    $execTime = [DateTime]::FromFileTimeUtc($fileTime).ToLocalTime()
                    $exe = Split-Path $valueName -Leaf
                    $path = ""

                    if ($valueName -match '^\\Device\\HarddiskVolume\d+\\(.+)$') {
                        $path = Get-BamDevicePath -Remainder $matches[1]
                    } elseif ($valueName -match '^\\??\\(.+)$') {
                        $path = Get-BamDevicePath -Remainder $matches[1]
                    }

                    $dedupeKey = "$exe|$path|$($execTime.ToString('yyyy-MM-dd HH:mm:ss'))"
                    if ($seen.ContainsKey($dedupeKey)) { continue }
                    $seen[$dedupeKey] = $true

                    $sigStatus = "N/A"
                    if ($path -and (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) {
                        if ($signaturesChecked -lt $SignatureBudget) {
                            try {
                                $sig = Get-AuthenticodeSignature -LiteralPath $path
                                $sigStatus = if ($sig.Status -eq "Valid") { "Valid" } else { "Invalid" }
                            } catch {
                                $sigStatus = "Invalid"
                            }
                            $signaturesChecked++
                        } else {
                            $sigStatus = "N/A"
                        }
                    }

                    $timeText = $execTime.ToString("yyyy-MM-dd HH:mm:ss")
                    $entries += [PSCustomObject]@{
                        'Examiner Time'       = $timeText
                        'Last Execution Time' = $timeText
                        'Application'         = $exe
                        'Path'                = $path
                        'Signature'           = $sigStatus
                    }
                } catch { continue }
            }

            $sidKey.Close()
        }

        $rootKey.Close()
    }

    return $entries
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

$script:WindhawkProcessName = 'windhawk.exe'
$script:WindhawkWatchPaths = @(
    'C:\Users\Stef\Downloads\windhawk.exe',
    (Join-Path $env:USERPROFILE 'Downloads\windhawk.exe'),
    (Join-Path ${env:ProgramFiles} 'Windhawk\windhawk.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Windhawk\windhawk.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Windhawk\windhawk.exe')
)

function Get-WindhawkProcessHits {
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $messages = @()

    try {
        Get-CimInstance Win32_Process -Filter "Name='$($script:WindhawkProcessName)'" -ErrorAction Stop | ForEach-Object {
            $procId = [int]$_.ProcessId
            if (-not $seen.Add($procId)) { return }
            $path = [string]$_.ExecutablePath
            $label = "$($script:WindhawkProcessName) (PID $procId)"
            if ($path) { $label += " -> $path" }
            $messages += $label
        }
    } catch {}

    return $messages
}

function Get-WindhawkStep1Alerts {
    $alerts = @()
    $hits = @(Get-WindhawkProcessHits)

    if ($hits.Count -gt 0) {
        foreach ($hit in $hits) {
            $alerts += "FAILURE: Windhawk running $hit"
        }
        return $alerts
    }

    $foundPaths = @()
    foreach ($p in ($script:WindhawkWatchPaths | Select-Object -Unique)) {
        if ($p -and (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)) {
            $foundPaths += $p
        }
    }
    if ($foundPaths.Count -gt 0) {
        foreach ($p in $foundPaths) {
            $alerts += "WARNING: Windhawk found $p"
        }
        return $alerts
    }

    $alerts += 'SUCCESS: Windhawk not detected'
    return $alerts
}

function Get-PrefetchLastRunTime {
    param([string]$FilePath)

    try {
        $fs = [System.IO.File]::OpenRead($FilePath)
        try {
            $buffer = New-Object byte[] 144
            $read = $fs.Read($buffer, 0, $buffer.Length)
            if ($read -lt 24) { return "Unknown" }

            $version = [BitConverter]::ToInt32($buffer, 0)
            $candidates = @()

            if ($read -ge 24) {
                $candidates += [BitConverter]::ToInt64($buffer, 16)
            }
            if ($read -ge 136 -and $version -ge 26) {
                $candidates += [BitConverter]::ToInt64($buffer, 128)
            }

            foreach ($fileTime in $candidates) {
                if ($fileTime -le 0) { continue }
                try {
                    $dt = [DateTime]::FromFileTimeUtc($fileTime).ToLocalTime()
                    if ($dt.Year -ge 2000 -and $dt.Year -le 2100) {
                        return $dt.ToString("yyyy-MM-dd HH:mm:ss")
                    }
                } catch {}
            }
            return "Unknown"
        } finally {
            $fs.Close()
        }
    } catch {
        return "Unknown"
    }
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
        $fallback = Join-Path $env:TEMP 'loc_tier2_security_events.log'
        try { Add-Content -LiteralPath $fallback -Value "[$timestamp] $Message" -ErrorAction SilentlyContinue } catch {}
    }
}

function Convert-UserAssistName {
    param([string]$Name)

    if ([string]::IsNullOrEmpty($Name)) { return $Name }
    $chars = $Name.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $c = [int][char]$chars[$i]
        if ($c -ge 65 -and $c -le 90) { $chars[$i] = [char](((($c - 65 + 13) % 26) + 65)) }
        elseif ($c -ge 97 -and $c -le 122) { $chars[$i] = [char](((($c - 97 + 13) % 26) + 97)) }
    }
    return -join $chars
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
# STEP 1: System Check
# ===============================
Write-Host "[1/6] System Check" -ForegroundColor Cyan
Show-LoadingBar

$passedChecks = 0
$totalChecks = 0
$moduleOutput = @()
$cpuGpuOutput = @()
$processOutput = @()
$keyAuthOutput = @()
$powershellSigOutput = @()
$osOutput = @()
$vmOutput = @()
$defenderOutput = @()
$exclusionsOutput = @()
$allowedThreatsOutput = @()
$memoryIntegrityOutput = @()
$registryOutput = @()
$nvidiaOutput = @()
$windhawkOutput = @()

# ----- Module Check -----
$modules = @("Microsoft.PowerShell.Operation.Validation","PackageManagement","Pester","PowerShellGet","PSReadline")
$totalChecks++
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

# ----- CPU & GPU Detections -----
try {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name
    $gpu = (Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '
    if ($cpu -and $gpu) { $cpuGpuOutput += "SUCCESS: $cpu | $gpu" }
    elseif ($cpu) { $cpuGpuOutput += "SUCCESS: $cpu" }
} catch {
    $cpuGpuOutput += "WARNING: Hardware query failed"
}

# Cache OS/VM before Defender cmdlets (they break later CIM/WMI queries in the same session)
$osVerified = $false
if ($env:OS -eq "Windows_NT") {
    try {
        $osInfoEarly = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $osInfoEarly) { $osVerified = $true }
    } catch {}
}

$vmDetected = $false
$vmCheckFailed = $false
try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($cs.Manufacturer -match 'VMware|VirtualBox|innotek|QEMU|Xen|Parallels' -or $cs.Model -match 'Virtual|VMware|VirtualBox') { $vmDetected = $true }
    if ($cs.Manufacturer -match 'Microsoft' -and $cs.Model -match 'Virtual') { $vmDetected = $true }
    $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
    if ($bios.SMBIOSBIOSVersion -match "VMware|Hyper-V") { $vmDetected = $true }
    if (Get-Service "*vmware*" -ErrorAction SilentlyContinue) { $vmDetected = $true }
} catch { $vmCheckFailed = $true }

# ----- Windows Defender -----
$totalChecks++
try {
    $def = Get-MpComputerStatus
    if ($def.RealTimeProtectionEnabled) { $defenderOutput += "SUCCESS: Real-time protection on"; $passedChecks++ }
    else { $defenderOutput += "FAILURE: Real-time protection off" }

    if (-not $def.IsTamperProtected) { $defenderOutput += "WARNING: Tamper protection off" }
} catch { $defenderOutput += "WARNING: Defender unavailable" }

foreach ($disableKey in @(
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender',
    'HKLM:\SOFTWARE\Microsoft\Windows Defender'
)) {
    try {
        $disabled = Get-ItemPropertyValue -Path $disableKey -Name 'DisableAntiSpyware' -ErrorAction Stop
        if ($disabled -eq 1) { $defenderOutput += "FAILURE: DisableAntiSpyware active" }
    } catch {}
}

# ----- Defender Exclusions -----
$totalChecks++
try {
    $allExclusions = @(Get-Exclusions)

    if ($allExclusions.Count -eq 0) {
        $exclusionsOutput += "SUCCESS: No exclusions"
        $passedChecks++
    } else {
        foreach ($excl in $allExclusions) {
            $exclKw = Get-MatchedCheatKeyword -Text $excl
            if ($exclKw) { $exclusionsOutput += "FAILURE: Exclusion [$exclKw] $excl" }
            else { $exclusionsOutput += "FAILURE: Exclusion $excl" }
        }
    }
} catch { $exclusionsOutput += "WARNING: Exclusions check failed" }

# ----- Allowed Threats -----
$totalChecks++
try {
    $allowedThreats = @(Get-AllowedDefenderThreats)
    if ($allowedThreats.Count -eq 0) {
        $allowedThreatsOutput += "SUCCESS: No allowed threats"
        $passedChecks++
    } else {
        foreach ($threat in $allowedThreats) {
            $allowedThreatsOutput += "FAILURE: Allowed threat $threat"
        }
    }
} catch { $allowedThreatsOutput += "WARNING: Allowed threats check failed" }

# ----- Memory Integrity -----
$totalChecks++
try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
    $enabled = Get-ItemPropertyValue -Path $regPath -Name "Enabled" -ErrorAction Stop
    if ($enabled -eq 1) { $memoryIntegrityOutput += "SUCCESS: Memory Integrity on"; $passedChecks++ }
    else { $memoryIntegrityOutput += "FAILURE: Memory Integrity off" }
} catch { $memoryIntegrityOutput += "WARNING: Memory Integrity unavailable" }

# ----- NVIDIA ShadowPlay FTS (streamproof bypass) -----
$totalChecks++
foreach ($line in (Get-NvidiaShadowPlayFtsAlerts)) {
    $nvidiaOutput += $line
    if ($line -like 'SUCCESS*') { $passedChecks++ }
}

# ----- Process Scan -----
$totalChecks++
$procHits = @(Get-SuspiciousProcessHits)
if ($procHits.Count -eq 0) {
    $processOutput += "SUCCESS: Processes clean"
    $passedChecks++
} else {
    $processOutput += $procHits
}

# ----- KeyAuth -----
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

# ----- Windhawk -----
$totalChecks++
foreach ($line in (Get-WindhawkStep1Alerts)) {
    $windhawkOutput += $line
    if ($line -like 'SUCCESS*') { $passedChecks++ }
}

# ----- PowerShell Binary -----
$totalChecks++
try {
    $psPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $sig = Get-AuthenticodeSignature $psPath
    if ($sig.Status -eq "Valid" -and $sig.SignerCertificate.Subject -like "*Microsoft*") { $powershellSigOutput += "SUCCESS: PowerShell OK"; $passedChecks++ }
    else { $powershellSigOutput += "FAILURE: PowerShell tampered" }
} catch { $powershellSigOutput += "WARNING: PowerShell check failed" }

# ----- OS Check -----
$totalChecks++
if ($osVerified) { $osOutput += "SUCCESS: OS OK"; $passedChecks++ }
else { $osOutput += "FAILURE: OS check failed" }

# ----- VM -----
$totalChecks++
if ($vmCheckFailed) { $vmOutput += "WARNING: VM check failed" }
elseif (-not $vmDetected) { $vmOutput += "SUCCESS: Not a VM"; $passedChecks++ }
else { $vmOutput += "FAILURE: VM detected" }

# ----- Registry -----
$totalChecks++
$registryHit = $false
try {
    $mui = "HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"
    $entries = Get-ItemProperty -Path $mui -ErrorAction Stop
    foreach ($prop in $entries.PSObject.Properties) {
        if ($prop.Name -match '^(PSPath|PSParentPath|PSChildName|PSDrive|PSProvider)$') { continue }
        $muiKw = Get-MatchedCheatKeyword -Text $prop.Name
        if ($muiKw) {
            $registryOutput += "FAILURE: MuiCache [$muiKw] $($prop.Name)"
            $registryHit = $true
        }
    }
} catch { $registryOutput += "WARNING: MuiCache unavailable" }

try {
    $uaRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
    if (Test-Path $uaRoot) {
        Get-ChildItem $uaRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $countKey = Join-Path $_.PSPath 'Count'
            if (-not (Test-Path $countKey)) { return }
            $uaEntries = Get-ItemProperty -Path $countKey -ErrorAction SilentlyContinue
            if (-not $uaEntries) { return }
            foreach ($prop in $uaEntries.PSObject.Properties) {
                if ($prop.Name -match '^(PSPath|PSParentPath|PSChildName|PSDrive|PSProvider)$') { continue }
                $decoded = Convert-UserAssistName -Name $prop.Name
                $uaKw = Get-MatchedCheatKeyword -Text $decoded
                if ($uaKw) {
                    $registryOutput += "FAILURE: UserAssist [$uaKw] $decoded"
                    $registryHit = $true
                }
            }
        }
    }
} catch {}

if (-not $registryHit -and ($registryOutput -notlike 'WARNING*')) {
    $registryOutput += "SUCCESS: Registry clean"
    $passedChecks++
}

Write-Section "System" ($moduleOutput + $cpuGpuOutput + $osOutput + $vmOutput)
Write-Section "Defender" ($defenderOutput + $exclusionsOutput + $allowedThreatsOutput + $memoryIntegrityOutput)
Write-Section "NVIDIA ShadowPlay" $nvidiaOutput
Write-Section "Processes" $processOutput
Write-Section "KeyAuth" $keyAuthOutput
Write-Section "Windhawk" $windhawkOutput
Write-Section "PowerShell" $powershellSigOutput
Write-Section "Registry" $registryOutput

if ($totalChecks -ne 0) { $successRate = [math]::Round(($passedChecks / $totalChecks) * 100) } else { $successRate = 0 }
Write-Host "Result: $successRate%" -ForegroundColor Cyan
Write-Host ""
Wait-NextStep "[2/6] Press Enter" "[2/6] BAM Key Entries"

# ----- Admin check -----
if (-not (Test-Admin)) {
    Write-Warning "Administrator required."
    Start-Sleep 2
    exit
}

Show-LoadingBar

try {
    $Bam = @(Get-ActivityModeratorEntries)
} catch {
    $Bam = @()
}

if ($Bam.Count -eq 0) {
    Write-Host "WARNING: No BAM/DAM entries found" -ForegroundColor Yellow
}

foreach ($fp in (Get-BamRegistryFingerprints)) { $script:BaselineBamKeys[$fp] = $true }

try {
    Initialize-WinForms

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "BAM Key Entries ($($Bam.Count))"
    $form.WindowState = 'Maximized'
    $form.StartPosition = "CenterScreen"

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines = $true
    $lv.Dock = 'Fill'
    $lv.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $lv.ForeColor = [System.Drawing.Color]::Black
    $lv.BackColor = [System.Drawing.Color]::White

    $lv.Columns.Add("Examiner Time", 200) | Out-Null
    $lv.Columns.Add("Last Execution Time", 200) | Out-Null
    $lv.Columns.Add("Application", 300) | Out-Null
    $lv.Columns.Add("Path", 700) | Out-Null
    $lv.Columns.Add("Signature", 200) | Out-Null

    $lv.BeginUpdate()
    try {
        foreach ($r in $Bam) {
            $item = New-Object System.Windows.Forms.ListViewItem($r.'Examiner Time')
            $item.SubItems.Add($r.'Last Execution Time') | Out-Null
            $item.SubItems.Add($r.Application) | Out-Null
            $item.SubItems.Add($r.Path) | Out-Null
            $item.SubItems.Add($r.Signature) | Out-Null
            $lv.Items.Add($item) | Out-Null
        }
    } finally {
        $lv.EndUpdate()
    }

    $form.Controls.Add($lv)

    $form.Add_Shown({
        $used = 0
        for ($i = 0; $i -lt ($lv.Columns.Count - 1); $i++) {
            $used += $lv.Columns[$i].Width
        }
        $remaining = $lv.ClientSize.Width - $used - 5
        if ($remaining -gt 100) {
            $lv.Columns[$lv.Columns.Count - 1].Width = $remaining
        }
    })

    [void]$form.ShowDialog()
} catch {
    Write-Warning "BAM viewer failed: $($_.Exception.Message)"
}

Wait-NextStep "[3/6] Press Enter" "[3/6] Prefetch Viewer"
Show-LoadingBar

function Launch-PrefetchViewer {
    Initialize-WinForms

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Prefetch Viewer"
    $form.WindowState = 'Maximized'
    $form.StartPosition = "CenterScreen"

    $listView = New-Object System.Windows.Forms.ListView
    $listView.View = [System.Windows.Forms.View]::Details
    $listView.FullRowSelect = $true
    $listView.GridLines = $true
    $listView.Dock = 'Fill'
    $listView.MultiSelect = $false

    $listView.Columns.Add("Prefetch File Name", 400) | Out-Null
    $listView.Columns.Add("Size (KB)", 100) | Out-Null
    $listView.Columns.Add("Last Access Time", 250) | Out-Null
    $listView.Columns.Add("Last Run Time", 250) | Out-Null

    $form.Controls.Add($listView) | Out-Null

    $prefetchPath = "$env:WINDIR\Prefetch"
    if (-Not (Test-Path $prefetchPath)) {
        [System.Windows.Forms.MessageBox]::Show("Prefetch folder not found.","Error",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $prefetchFiles = @()
    try {
        $prefetchFiles = @(Get-ChildItem -Path $prefetchPath -Filter "*.pf" -ErrorAction Stop)
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Cannot read Prefetch. Run as Administrator.","Prefetch",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }

    if ($prefetchFiles.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No prefetch files found.","Prefetch",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } else {
        foreach ($name in $prefetchFiles.Name) { $script:BaselinePrefetchFiles[$name] = $true }
    }

    $rows = foreach ($file in $prefetchFiles) {
        [PSCustomObject]@{
            Name       = $file.Name
            SizeKb     = ([math]::Round($file.Length / 1KB, 2)).ToString()
            AccessTime = $file.LastAccessTime.ToString("yyyy-MM-dd HH:mm:ss")
            RunTime    = Get-PrefetchLastRunTime -FilePath $file.FullName
        }
    }

    $listView.BeginUpdate()
    try {
        foreach ($row in $rows) {
            $item = New-Object System.Windows.Forms.ListViewItem($row.Name)
            $item.SubItems.Add($row.SizeKb) | Out-Null
            $item.SubItems.Add($row.AccessTime) | Out-Null
            $item.SubItems.Add($row.RunTime) | Out-Null
            $listView.Items.Add($item) | Out-Null
        }
    } finally {
        $listView.EndUpdate()
    }

    $listView.Add_DoubleClick({
        if ($listView.SelectedItems.Count -gt 0) {
            $selectedFile = $listView.SelectedItems[0].Text
            Start-Process "$prefetchPath\$selectedFile" | Out-Null
        }
    })

    [void]$form.ShowDialog()
}

try {
    Launch-PrefetchViewer
} catch {
    Write-Warning "Prefetch viewer failed: $($_.Exception.Message)"
}

Wait-NextStep "[4/6] Press Enter" "[4/6] Process Explorer"
Show-LoadingBar

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
    $proc = Start-Process -FilePath $procExe -PassThru
    $proc.WaitForExit()
}

Wait-NextStep "[5/6] Press Enter" "[5/6] Last Activity Viewer"
Show-LoadingBar

$lastActivityDir = "$env:TEMP\LastActivity"
$lastActivityExe = "$lastActivityDir\LastActivityView.exe"

if (-not (Test-Path $lastActivityExe)) {
    $lastActivityURL = "https://www.nirsoft.net/utils/lastactivityview.zip"
    $lastActivityZip = "$env:TEMP\LastActivityView.zip"
    if (-not (Invoke-ToolDownload -Url $lastActivityURL -ZipPath $lastActivityZip -DestDir $lastActivityDir)) {
        Write-Host "WARNING: Last Activity Viewer unavailable" -ForegroundColor Yellow
    }
}

if (Test-Path $lastActivityExe) {
    Start-Process -FilePath $lastActivityExe -WindowStyle Maximized
}

Wait-NextStep "[6/6] Press Enter" "[6/6] Live Monitor"
Show-LoadingBar
Write-Host "Keep this window open during the match. Must show again after match." -ForegroundColor Yellow
Write-Host ""

$logFile = Join-Path $env:ProgramData 'loc_tier2_security_events.log'
try {
    if (-not (Test-Path $logFile)) { New-Item -Path $logFile -ItemType File -Force | Out-Null }
    Write-MonitorAlert -Message "LOC Tier 2 v$($script:LocTier2Version) monitor started" -LogFile $logFile
} catch {
    $logFile = Join-Path $env:TEMP 'loc_tier2_security_events.log'
    if (-not (Test-Path $logFile)) { New-Item -Path $logFile -ItemType File -Force | Out-Null }
    Write-Host "WARNING: Logging to $logFile" -ForegroundColor Yellow
    Write-MonitorAlert -Message "LOC Tier 2 v$($script:LocTier2Version) monitor started" -LogFile $logFile
}

Register-WmiEvent -Class Win32_VolumeChangeEvent -SourceIdentifier USBChange | Out-Null
trap {
    Get-EventSubscriber -SourceIdentifier USBChange -ErrorAction SilentlyContinue |
        Unregister-Event -Force -ErrorAction SilentlyContinue
    break
}

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
$reportedWindhawkHits = @{}
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

foreach ($hit in (Get-WindhawkProcessHits)) {
    $reportedWindhawkHits[$hit] = $true
    Write-MonitorAlert -Message "Windhawk: $hit" -LogFile $logFile -Color Red
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

        foreach ($hit in (Get-WindhawkProcessHits)) {
            if (-not $reportedWindhawkHits.ContainsKey($hit)) {
                $reportedWindhawkHits[$hit] = $true
                Write-MonitorAlert -Message "Windhawk: $hit" -LogFile $logFile -Color Red
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
