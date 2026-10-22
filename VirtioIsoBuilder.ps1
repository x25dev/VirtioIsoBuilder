#Requires -Version 5.1
<#
.SYNOPSIS
    Windows + VirtIO ISO builder: get a Windows ISO (UUP dump / Microsoft Evaluation Center / local file)
    and a chosen virtio-win version, extract the VirtIO drivers matching that Windows version and
    optionally inject them (plus the QEMU guest agent) into a new bootable ISO.

.DESCRIPTION
    Single self-contained script. Run it without parameters (or right-click > Run with PowerShell) for a GUI.

    Windows sources:
      UUP   - uupdump.net builds an ISO from Windows Update files (Windows 10/11, Server 2022/2025).
      Eval  - Microsoft Evaluation Center ISO (Server 2016/2019/2022/2025, English, x64, 180 days).
      Local - your own ISO (any Windows 7 / Server 2008 R2 or newer).

    virtio-win: 'stable', 'latest' or any archive version, e.g. 0.1.302-1.

    Steps:
      1. Reads the Windows version/edition/architecture straight from sources\install.wim|esd|swm
         (no DISM needed) and maps it to the virtio-win folder (w10, w11, 2k16, 2k19, 2k22, 2k25, ...).
         If that folder is missing on the chosen virtio-win ISO, the nearest compatible one is used.
      2. Copies <driver>\<os>\<arch> for each driver plus the QEMU guest agent MSI.
      3. With -Inject: adds the drivers to every index of boot.wim and install.wim with DISM, adds the
         guest agent via sources\$OEM$ + SetupComplete.cmd, and rebuilds a BIOS/UEFI bootable ISO with
         oscdimg.exe. Needs the Windows ADK "Deployment Tools".

    Administrator rights are needed for -Inject and for the UUP source; the script relaunches itself
    elevated when required.

.EXAMPLE
    .\VirtioIsoBuilder.ps1
    GUI.

.EXAMPLE
    .\VirtioIsoBuilder.ps1 -Windows 2022 -Source Eval -VirtioVersion 0.1.302-1
    Download Server 2022 eval + virtio-win 0.1.302-1 and extract the matching drivers.

.EXAMPLE
    .\VirtioIsoBuilder.ps1 -Windows 11 -VirtioVersion stable -Inject -NoBootPrompt
    Newest Windows 11 from UUP dump with VirtIO drivers + guest agent injected.

.EXAMPLE
    .\VirtioIsoBuilder.ps1 -WindowsIso D:\ISO\Server2025.iso -VirtioIso D:\ISO\virtio-win.iso -AllDrivers -Inject

.EXAMPLE
    .\VirtioIsoBuilder.ps1 -Windows 2025 -ListBuilds
    .\VirtioIsoBuilder.ps1 -ListVirtioVersions
#>
[CmdletBinding()]
param(
    # Windows version to download: 10, 11 (newest), 11-23H2, 11-24H2, 11-25H2, 2016, 2019, 2022, 2025.
    [ValidateSet('10', '11', '11-23H2', '11-24H2', '11-25H2', '2016', '2019', '2022', '2025')]
    [string]$Windows,
    # Auto (UUP when available, else Eval), UUP, Eval or Local.
    [ValidateSet('Auto', 'UUP', 'Eval', 'Local')]
    [string]$Source = 'Auto',
    # Use this Windows ISO (or extracted folder) instead of downloading.
    [string]$WindowsIso,
    [ValidateSet('amd64', 'arm64')]
    [string]$Arch = 'amd64',
    # UUP dump language, e.g. en-us, nl-nl, de-de.
    [string]$Language = 'en-us',
    # UUP dump edition, e.g. PROFESSIONAL, CORE, SERVERSTANDARD, SERVERDATACENTER.
    [string]$Edition,
    # UUP dump build UUID or build number (e.g. 26100.4349). Default: newest.
    [string]$UupBuild,
    # stable, latest or e.g. 0.1.302-1.
    [string]$VirtioVersion = 'stable',
    # Use this virtio-win ISO (or extracted folder) instead of downloading.
    [string]$VirtioIso,
    # Downloads, caches and default output. No spaces (UUP dump requirement).
    [string]$WorkRoot = "$env:SystemDrive\VirtioBuild",
    # Output folder. Default: <WorkRoot>\output\<Windows ISO name>
    [string]$OutputPath,
    # Path of the new ISO (with -Inject). Default: <OutputPath>\<Windows ISO name>-<virtio name>.iso
    [string]$OutputIso,
    [string[]]$Drivers = @('viostor', 'vioscsi', 'NetKVM', 'Balloon', 'vioserial'),
    [switch]$AllDrivers,
    [switch]$Inject,
    [switch]$NoBootPrompt,
    [switch]$NoGuestAgent,
    [switch]$ListBuilds,
    [switch]$ListVirtioVersions,
    # Internal: keep the window open at the end (used by the GUI and the elevated relaunch).
    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is extremely slow with the progress bar in PS 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# "-Drivers a,b,c" arrives as one string when the script is started with powershell.exe -File.
$Drivers = @($Drivers | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$UserAgent  = 'VirtioIsoBuilder/1.0 (PowerShell)'
$VirtioBase = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads'
$BootCriticalDrivers = @('viostor', 'vioscsi')

# Uup.Search goes to the UUP dump listid API (all words must appear in the title); Uup.Build filters the build number.
$Catalog = [ordered]@{
    '10'      = @{ Name = 'Windows 10 22H2';             Uup = @{ Search = 'windows 10 19045'; Build = '19045'; Edition = 'PROFESSIONAL'; Server = $false } }
    '11'      = @{ Name = 'Windows 11 (newest release)'; Uup = @{ Search = 'windows 11';       Build = '';      Edition = 'PROFESSIONAL'; Server = $false } }
    '11-23H2' = @{ Name = 'Windows 11 23H2';             Uup = @{ Search = 'windows 11 22631'; Build = '22631'; Edition = 'PROFESSIONAL'; Server = $false } }
    '11-24H2' = @{ Name = 'Windows 11 24H2';             Uup = @{ Search = 'windows 11 26100'; Build = '26100'; Edition = 'PROFESSIONAL'; Server = $false } }
    '11-25H2' = @{ Name = 'Windows 11 25H2';             Uup = @{ Search = 'windows 11 26200'; Build = '26200'; Edition = 'PROFESSIONAL'; Server = $false } }
    '2016'    = @{ Name = 'Windows Server 2016';
                   Eval = 'https://go.microsoft.com/fwlink/p/?LinkID=2195174&clcid=0x409&culture=en-us&country=US' }
    '2019'    = @{ Name = 'Windows Server 2019';
                   Eval = 'https://go.microsoft.com/fwlink/p/?LinkID=2195167&clcid=0x409&culture=en-us&country=US' }
    '2022'    = @{ Name = 'Windows Server 2022';
                   Uup  = @{ Search = 'server 20348'; Build = '20348'; Edition = 'SERVERSTANDARD'; Server = $true }
                   Eval = 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US' }
    '2025'    = @{ Name = 'Windows Server 2025';
                   Uup  = @{ Search = 'server 26100'; Build = '26100'; Edition = 'SERVERSTANDARD'; Server = $true }
                   Eval = 'https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us' }
}

$SourceNames = [ordered]@{
    UUP   = 'UUP dump (build from Windows Update)'
    Eval  = 'Microsoft Evaluation Center (180-day eval, English)'
    Local = 'Local ISO file'
}

$WinPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

function Get-WinPSModulePath {
    # Windows PowerShell 5.1's own module folders. PowerShell 7 hands its module path down to child processes,
    # which makes 5.1 children (UUP's get_aria2.ps1) load PS7 modules and fail ("Get-FileHash is not recognized").
    @((Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')) -join ';'
}

function ConvertTo-QuotedArg([string]$s) {
    # Quote for a command line; a trailing backslash would escape the closing quote (e.g. "C:\").
    if ($s.EndsWith('\')) { $s += '\' }
    '"' + $s + '"'
}

function ConvertTo-ArgString([System.Collections.IDictionary]$Params) {
    $parts = foreach ($kv in $Params.GetEnumerator()) {
        $v = $kv.Value
        if ($v -is [System.Management.Automation.SwitchParameter] -or $v -is [bool]) { if ($v) { "-$($kv.Key)" } }
        elseif ($v -is [array]) { "-$($kv.Key)"; ($v -join ',') }
        else { "-$($kv.Key)"; ConvertTo-QuotedArg ([string]$v) }
    }
    $parts -join ' '
}

function Test-IsAdmin {
    (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

#region Downloads -------------------------------------------------------------------------------

function Save-Url([string]$Url, [string]$Destination) {
    # curl.exe ships with Windows 10 1803+; resumes partial downloads and shows progress.
    $part = "$Destination.part"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -L --fail --retry 3 -A $UserAgent -C - -o $part $Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit code $LASTEXITCODE): $Url" }
    }
    else {
        Invoke-WebRequest -Uri $Url -OutFile $part -UserAgent $UserAgent -UseBasicParsing
    }
    Move-Item -LiteralPath $part -Destination $Destination -Force
}

function Get-EvalIso([string]$Key, [string]$Root) {
    $url = $Catalog[$Key].Eval
    if (-not $url) { throw "$($Catalog[$Key].Name) has no Evaluation Center download." }
    $dir = Join-Path $Root 'eval'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dest = Join-Path $dir "WindowsServer$Key-Eval-en-us.iso"
    if (Test-Path -LiteralPath $dest) { Write-Step "Using cached $dest"; return $dest }
    Write-Step "Downloading $($Catalog[$Key].Name) evaluation ISO..."
    Save-Url $url $dest
    $dest
}

#endregion

#region UUP dump --------------------------------------------------------------------------------

function Invoke-UupApi([string]$Name, [hashtable]$Query, [int]$Retries = 4) {
    $qs = ($Query.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, [uri]::EscapeDataString([string]$_.Value) }) -join '&'
    $url = "https://api.uupdump.net/$Name.php?$qs"
    for ($n = 0; ; $n++) {
        try {
            $r = Invoke-RestMethod -Uri $url -UserAgent $UserAgent -UseBasicParsing
            if ($r.response.error) { throw "API error: $($r.response.error)" }
            return $r.response
        }
        catch {
            if ($n -ge $Retries) { throw "UUP dump '$Name' request failed: $($_.Exception.Message)" }
            Write-Warning "UUP dump '$Name' request failed ($($_.Exception.Message)); retrying in 10 s..."
            Start-Sleep -Seconds 10
        }
    }
}

function Find-UupBuilds($Entry, [string]$Arch, [int]$Retries = 4) {
    $u = $Entry.Uup
    if (-not $u) { return @() }
    $resp = Invoke-UupApi listid @{ search = "$($u.Search) $Arch"; sortByDate = 1 } -Retries $Retries
    $builds = $resp.builds
    if (-not $builds) { return @() }
    # The API returns an object keyed by index rather than a JSON array.
    if ($builds -isnot [array]) { $builds = @($builds.PSObject.Properties | ForEach-Object { $_.Value }) }
    @($builds | Where-Object {
            $_.arch -eq $Arch -and
            $_.title -notmatch 'preview|insider|\.NET|CPC|Azure|HCI|Update Stack' -and
            (($_.title -match 'server') -eq $u.Server) -and
            (-not $u.Build -or $_.build -like "$($u.Build).*")
        })
}

function Select-UupEdition([string[]]$Available, [string]$Wanted) {
    $hit = $Available | Where-Object { $_ -eq $Wanted } | Select-Object -First 1
    if ($hit) { return $hit }
    $hit = $Available | Where-Object { $_ -match 'STANDARD|PROFESSIONAL' -and $_ -notmatch 'CORE$|N$' } | Select-Object -First 1
    if ($hit) { return $hit }
    $Available | Select-Object -First 1
}

function Get-UupIso($Build, [string]$Lang, [string]$EditionName, [string]$Root) {
    $dir = Join-Path $Root ('uup\{0}_{1}_{2}_{3}' -f $Build.build, $Build.arch, $Lang, $EditionName)
    $iso = Get-ChildItem -LiteralPath $dir -Filter *.iso -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($iso) { Write-Step "Using cached $($iso.FullName)"; return $iso.FullName }

    # uup_download_windows.cmd refuses (and waits for a key press) when its path contains spaces.
    if ($dir -match ' ') { throw "The UUP dump work folder must not contain spaces: '$dir'. Choose another -WorkRoot." }
    # UUP file names are up to ~95 characters; a deep folder exceeds the 260-character path limit and aria2
    # then fails ("Failed to write into the segment file") while the UUP script retries forever.
    if ($dir.Length -gt 120) { throw "The UUP dump work folder path is too long ($($dir.Length) characters): '$dir'. Use a short -WorkRoot such as C:\VirtioBuild." }

    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = "$dir.zip"
    Write-Step "Requesting UUP dump package for '$($Build.title)' ($Lang, $EditionName)..."
    $url = "https://uupdump.net/get.php?id=$($Build.uuid)&pack=$Lang&edition=$EditionName"
    Invoke-WebRequest -Method Post -Uri $url -Body @{ autodl = 2; updates = 1; cleanup = 1 } -OutFile $zip -UserAgent $UserAgent -UseBasicParsing
    $magic = [IO.File]::ReadAllBytes($zip) | Select-Object -First 2
    if ([string]::new([char[]]$magic) -ne 'PK') {
        $body = Get-Content -LiteralPath $zip -Raw
        Remove-Item -LiteralPath $zip -Force
        throw "uupdump.net did not return a download package (server busy or build removed). Response starts with: $($body.Substring(0, [Math]::Min(200, $body.Length)))"
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    Remove-Item -LiteralPath $zip -Force

    $cmd = Join-Path $dir 'uup_download_windows.cmd'
    if (-not (Test-Path -LiteralPath $cmd)) { throw "UUP dump package did not contain uup_download_windows.cmd ($dir)." }

    # Unattended conversion, keep install.wim (no ESD/SWM) so drivers can be injected afterwards.
    $ini = Join-Path $dir 'ConvertConfig.ini'
    if (Test-Path -LiteralPath $ini) {
        $text = Get-Content -LiteralPath $ini -Raw
        foreach ($kv in @{ AutoStart = 1; AutoExit = 1; Cleanup = 1; SkipISO = 0; wim2esd = 0; wim2swm = 0 }.GetEnumerator()) {
            $text = [regex]::Replace($text, "(?m)^($($kv.Key)\s*=\s*)\S*", "`${1}$($kv.Value)")
        }
        Set-Content -LiteralPath $ini -Value $text -Encoding Ascii -NoNewline
    }

    # aria2c (used by the UUP script) ignores the Windows proxy settings; hand them over via all_proxy.
    # Only when a real proxy is configured: GetProxy() can return nothing, which must not become "://".
    $target = [uri]'https://uupdump.net/'
    $webProxy = [System.Net.WebRequest]::GetSystemWebProxy()
    if (-not $env:all_proxy -and $webProxy -and -not $webProxy.IsBypassed($target)) {
        $proxy = $webProxy.GetProxy($target)
        if ($proxy -and $proxy.Host -and $proxy.Host -ne $target.Host) {
            $env:all_proxy = "$($proxy.Scheme)://$($proxy.Authority)"
            Write-Host "    Using system proxy for aria2: $env:all_proxy"
        }
    }

    Write-Step 'Running UUP dump download + conversion (downloads several GB; this takes a while)...'
    # Start-Process keeps the UUP script attached to this console so its progress and prompts are visible.
    # The UUP script calls convert-UUP.cmd by bare name, which breaks if NoDefaultCurrentDirectoryInExePath is set.
    $env:NoDefaultCurrentDirectoryInExePath = $null
    $savedModulePath = $env:PSModulePath
    $env:PSModulePath = Get-WinPSModulePath
    try {
        $p = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', "`"$cmd`"" `
            -WorkingDirectory $dir -NoNewWindow -Wait -PassThru
    }
    finally { $env:PSModulePath = $savedModulePath }
    Write-Host "    UUP dump script finished (exit code $($p.ExitCode))."

    $iso = Get-ChildItem -LiteralPath $dir -Filter *.iso | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $iso) { throw "UUP dump conversion did not produce an ISO in $dir. Check the output above; logs: $dir\aria2_download.log and $dir\ConvertUUP_*.log." }
    $iso.FullName
}

#endregion

#region virtio-win ------------------------------------------------------------------------------

function Get-VirtioVersions {
    $html = (Invoke-WebRequest -Uri "$VirtioBase/archive-virtio/" -UserAgent $UserAgent -UseBasicParsing).Content
    [regex]::Matches($html, 'href="virtio-win-(\d+\.\d+\.\d+(?:-\d+)?)/"') |
        ForEach-Object { $_.Groups[1].Value } |
        Select-Object -Unique |
        Sort-Object { [version]($_ -replace '-', '.') } -Descending
}

function Get-VirtioIso([string]$Version, [string]$Root) {
    $dir = Join-Path $Root 'virtio'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Version = $Version.Trim() -replace '^virtio-win-', '' -replace '\.iso$', ''

    if ($Version -in 'stable', 'latest') {
        # Moving targets: always fetch fresh.
        $dest = Join-Path $dir "virtio-win-$Version.iso"
        Write-Step "Downloading virtio-win ($Version)..."
        Save-Url "$VirtioBase/$Version-virtio/virtio-win.iso" $dest
        return $dest
    }

    $all = @(Get-VirtioVersions)
    $folder = $all | Where-Object { $_ -eq $Version -or $_ -like "$Version-*" } | Select-Object -First 1
    if (-not $folder) { throw "virtio-win version '$Version' not found. Available: $(($all | Select-Object -First 15) -join ', ') ..." }

    $dest = Join-Path $dir "virtio-win-$folder.iso"
    if (Test-Path -LiteralPath $dest) { Write-Step "Using cached $dest"; return $dest }

    $folderUrl = "$VirtioBase/archive-virtio/virtio-win-$folder/"
    $html = (Invoke-WebRequest -Uri $folderUrl -UserAgent $UserAgent -UseBasicParsing).Content
    $isoName = [regex]::Matches($html, 'href="(virtio-win-[\d.]+\.iso)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 1
    if (-not $isoName) { $isoName = 'virtio-win.iso' }

    Write-Step "Downloading virtio-win $folder ($isoName)..."
    Save-Url ($folderUrl + $isoName) $dest
    $dest
}

#endregion

#region ISO + image inspection ------------------------------------------------------------------

function Mount-Iso([string]$Path) {
    # Accepts an .iso (mounted if needed) or an already-extracted folder.
    $full = (Resolve-Path -LiteralPath $Path).Path
    $item = Get-Item -LiteralPath $full
    if ($item.PSIsContainer) {
        return [pscustomobject]@{ Root = $full.TrimEnd('\'); Label = $item.Name; ImagePath = $null; MountedByUs = $false }
    }

    $img = Get-DiskImage -ImagePath $full
    $mountedByUs = $false
    if (-not $img.Attached) {
        Mount-DiskImage -ImagePath $full -StorageType ISO | Out-Null
        $mountedByUs = $true
    }

    $vol = $null
    for ($i = 0; $i -lt 20; $i++) {
        $vol = Get-DiskImage -ImagePath $full | Get-Volume -ErrorAction SilentlyContinue
        if ($vol -and $vol.DriveLetter) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not ($vol -and $vol.DriveLetter)) {
        if ($mountedByUs) { Dismount-DiskImage -ImagePath $full | Out-Null }
        throw "Mounted '$full' but it got no drive letter (is automount disabled?)."
    }
    [pscustomobject]@{ Root = "$($vol.DriveLetter):"; Label = $vol.FileSystemLabel; ImagePath = $full; MountedByUs = $mountedByUs }
}

function Dismount-Iso($Mount) {
    if ($Mount -and $Mount.MountedByUs) {
        Dismount-DiskImage -ImagePath $Mount.ImagePath -ErrorAction SilentlyContinue | Out-Null
    }
}

function Find-InstallImages([string]$Root) {
    # Standard media has \sources; dual-architecture media has \x64\sources and \x86\sources.
    foreach ($dir in 'sources', 'x64\sources', 'x86\sources') {
        foreach ($name in 'install.wim', 'install.esd', 'install.swm') {
            $p = Join-Path $Root "$dir\$name"
            if (Test-Path -LiteralPath $p) {
                [pscustomobject]@{ SourcesDir = $dir; Path = $p }
                break
            }
        }
    }
}

function Read-WimXml([string]$Path) {
    # The WIM/ESD header points to an uncompressed UTF-16 XML block describing every image,
    # so no DISM (and no admin rights) is needed to read versions and editions.
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $br = New-Object IO.BinaryReader($fs)
        if ([Text.Encoding]::ASCII.GetString($br.ReadBytes(5)) -ne 'MSWIM') { throw "$Path is not a WIM/ESD file." }
        $fs.Position = 0x48                          # rhXmlData: 7-byte size + 1-byte flags, 8-byte offset
        $sizeBytes = $br.ReadBytes(8)
        $sizeBytes[7] = 0
        $size = [BitConverter]::ToInt64($sizeBytes, 0)
        $offset = $br.ReadInt64()
        $fs.Position = $offset
        $bytes = $br.ReadBytes([int]$size)
    }
    finally { $fs.Dispose() }
    [xml]([Text.Encoding]::Unicode.GetString($bytes).TrimStart([char]0xFEFF))
}

function Get-WimImages([string]$Path) {
    $xml = Read-WimXml $Path
    foreach ($img in @($xml.WIM.IMAGE)) {
        [pscustomobject]@{ Index = [int]$img.INDEX; Name = [string]$img.NAME; Windows = $img.WINDOWS }
    }
}

function ConvertTo-VirtioArch([int]$WimArch) {
    switch ($WimArch) {
        0       { 'x86' }
        9       { 'amd64' }
        12      { 'ARM64' }
        default { throw "Unsupported image architecture code $WimArch (only x86, amd64, ARM64 have VirtIO drivers)." }
    }
}

function Get-VirtioOsCandidates([version]$Version, [bool]$IsServer) {
    # virtio-win OS folder names, best match first, followed by compatible fallbacks.
    $b = $Version.Build
    if ($Version.Major -eq 6) {
        switch ($Version.Minor) {
            0 { return @('2k8') }                                                            # Vista / 2008
            1 { if ($IsServer) { return @('2k8R2', 'w7') }     else { return @('w7', '2k8R2') } }
            2 { if ($IsServer) { return @('2k12', 'w8') }      else { return @('w8', '2k12') } }
            3 { if ($IsServer) { return @('2k12R2', 'w8.1') }  else { return @('w8.1', '2k12R2') } }
        }
    }
    elseif ($Version.Major -eq 10) {
        if ($IsServer) {
            if ($b -ge 26100) { return @('2k25', '2k22', '2k19') }   # Server 2025
            if ($b -ge 20348) { return @('2k22', '2k19') }           # Server 2022 (+ 23H2 annual channel)
            if ($b -ge 17763) { return @('2k19', '2k16') }           # Server 2019 (+ SAC 1903..20H2)
            return @('2k16', 'w10')                                  # Server 2016 (+ SAC 1709/1803)
        }
        if ($b -ge 22000) { return @('w11', 'w10') }                 # Windows 11
        return @('w10')                                              # Windows 10
    }
    throw "Windows version $Version is not supported by virtio-win."
}

function Get-OsFriendlyName([string]$OsFolder) {
    $map = @{
        'w7' = 'Windows 7'; 'w8' = 'Windows 8'; 'w8.1' = 'Windows 8.1'; 'w10' = 'Windows 10'; 'w11' = 'Windows 11'
        '2k8' = 'Server 2008 / Vista'; '2k8R2' = 'Server 2008 R2'; '2k12' = 'Server 2012'; '2k12R2' = 'Server 2012 R2'
        '2k16' = 'Server 2016'; '2k19' = 'Server 2019'; '2k22' = 'Server 2022'; '2k25' = 'Server 2025'
    }
    if ($map.ContainsKey($OsFolder)) { $map[$OsFolder] } else { $OsFolder }
}

function Get-WinImageInfo([string]$ImagePath, [string]$SourcesDir) {
    foreach ($img in (Get-WimImages $ImagePath)) {
        $w = $img.Windows
        $sp = 0
        if ($w.VERSION.SPBUILD) { $sp = [int]$w.VERSION.SPBUILD }
        $version = [version]::new([int]$w.VERSION.MAJOR, [int]$w.VERSION.MINOR, [int]$w.VERSION.BUILD, $sp)
        $isServer = ($w.INSTALLATIONTYPE -match 'Server') -or ($w.PRODUCTTYPE -eq 'ServerNT') -or ($w.EDITIONID -match 'Server')
        $candidates = Get-VirtioOsCandidates -Version $version -IsServer $isServer
        [pscustomobject]@{
            SourcesDir   = $SourcesDir
            ImagePath    = $ImagePath
            Index        = $img.Index
            Name         = $img.Name
            Version      = $version
            Type         = $(if ($isServer) { 'Server' } else { 'Client' })
            Arch         = ConvertTo-VirtioArch ([int]$w.ARCH)
            OsKey        = $candidates[0]
            OsCandidates = $candidates
        }
    }
}

#endregion

#region DISM / ADK ------------------------------------------------------------------------------

function Get-AdkToolsDir {
    Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools'
}

function Find-Oscdimg {
    foreach ($a in 'amd64', 'arm64', 'x86') {
        $p = Join-Path (Get-AdkToolsDir) "$a\Oscdimg\oscdimg.exe"
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $null
}

function Find-Dism {
    # Prefer the ADK's DISM: the in-box one refuses to service images newer than the host OS
    # ("The request is not supported").
    $hostArch = 'x86'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $hostArch = 'arm64' }
    elseif ([Environment]::Is64BitOperatingSystem) { $hostArch = 'amd64' }
    $adk = Join-Path (Get-AdkToolsDir) "$hostArch\DISM\dism.exe"
    if (Test-Path -LiteralPath $adk) { return $adk }
    Join-Path $env:SystemRoot 'System32\dism.exe'
}

function Invoke-Dism([string[]]$Arguments) {
    $out = & $script:DismExe @Arguments '/English' '/NoRestart'
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Where-Object { $_ -and $_.Trim() }) -join "`n" }
}

function Get-DismError($Result) {
    # Last meaningful lines of DISM output ("Error: 50" + message) plus the tail of dism.log errors.
    $msg = (($Result.Output -split "`n") | Select-Object -Last 3) -join ' '
    $log = Join-Path $env:SystemRoot 'Logs\DISM\dism.log'
    if (Test-Path -LiteralPath $log) {
        $errs = Get-Content -LiteralPath $log -Tail 300 | Where-Object { $_ -match ', Error ' } | Select-Object -Last 3
        if ($errs) { $msg += "`n      dism.log: " + ($errs -join "`n      dism.log: ") }
    }
    "exit $($Result.ExitCode): $msg"
}

function Add-DriversToWim([string]$WimPath, [hashtable]$DriverDirByIndex, [string]$DefaultDriverDir, [string]$MountDir) {
    $wimName = Split-Path $WimPath -Leaf
    foreach ($ix in (Get-WimImages $WimPath)) {
        $key = [string]$ix.Index
        $drvDir = $DefaultDriverDir
        if ($DriverDirByIndex -and $DriverDirByIndex.ContainsKey($key)) { $drvDir = $DriverDirByIndex[$key] }

        Write-Step "Injecting drivers into $wimName index $key ($($ix.Name))"
        $r = Invoke-Dism @('/Mount-Image', "/ImageFile:$WimPath", "/Index:$key", "/MountDir:$MountDir")
        if ($r.ExitCode -ne 0) { throw "Mounting $wimName index $key failed - $(Get-DismError $r)" }
        try {
            # One driver at a time, so a single unsupported driver doesn't block the rest and is reported by name.
            foreach ($drv in (Get-ChildItem -LiteralPath $drvDir -Directory)) {
                $r = Invoke-Dism @("/Image:$MountDir", '/Add-Driver', "/Driver:$($drv.FullName)", '/Recurse')
                if ($r.ExitCode -eq 0) { Write-Host "    + $($drv.Name)" }
                else {
                    $detail = Get-DismError $r
                    Write-Warning "$($drv.Name) -> $wimName index $key failed: $detail"
                    $script:InjectFailures.Add([pscustomobject]@{ Driver = $drv.Name; Wim = $wimName; Index = $key; Detail = $detail })
                }
            }
        }
        catch {
            Invoke-Dism @('/Unmount-Image', "/MountDir:$MountDir", '/Discard') | Out-Null
            throw
        }
        $r = Invoke-Dism @('/Unmount-Image', "/MountDir:$MountDir", '/Commit')
        if ($r.ExitCode -ne 0) {
            Invoke-Dism @('/Unmount-Image', "/MountDir:$MountDir", '/Discard') | Out-Null
            throw "Saving $wimName index $key failed - $(Get-DismError $r)"
        }
    }
}

#endregion

#region Extract + inject ------------------------------------------------------------------------

function Invoke-VirtioProcess {
    param(
        [string]$WindowsIso, [string]$VirtioIso, [string]$OutputPath, [string[]]$DriverNames, [bool]$AllDrivers,
        [bool]$Inject, [string]$OutputIso, [string]$WorkPath, [bool]$NoBootPrompt, [bool]$NoGuestAgent
    )
    $winMount = $null
    $virtioMount = $null
    try {
        Write-Step "Mounting Windows ISO: $WindowsIso"
        $winMount = Mount-Iso $WindowsIso
        Write-Step "Mounting virtio-win ISO: $VirtioIso"
        $virtioMount = Mount-Iso $VirtioIso
        Write-Host "    virtio-win volume label: $($virtioMount.Label)"

        # --- Detect Windows version ---
        $installImages = @(Find-InstallImages $winMount.Root)
        if ($installImages.Count -eq 0) { throw "No sources\install.wim / install.esd / install.swm found on '$WindowsIso'. Is this a Windows installation ISO?" }
        $images = @(foreach ($ii in $installImages) { Get-WinImageInfo -ImagePath $ii.Path -SourcesDir $ii.SourcesDir })
        $images | Format-Table Index, Name, Version, Type, Arch, @{ n = 'VirtIO folder'; e = { $_.OsKey } } -AutoSize | Out-Host

        # --- Extract drivers ---
        New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
        $OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
        if ($AllDrivers) {
            $DriverNames = @(Get-ChildItem -LiteralPath "$($virtioMount.Root)\" -Directory | Select-Object -ExpandProperty Name)
        }

        $driverDirByTarget = @{}   # "OsKey|Arch" -> output folder
        $manifest = New-Object System.Collections.Generic.List[string]
        $manifest.Add("Windows ISO : $WindowsIso")
        $manifest.Add("virtio ISO  : $VirtioIso ($($virtioMount.Label))")
        $manifest.Add("Created     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $manifest.Add('')

        foreach ($group in ($images | Group-Object { "$($_.OsKey)|$($_.Arch)" })) {
            $first = $group.Group[0]
            $targetDir = Join-Path $OutputPath "virtio-$($first.OsKey)-$($first.Arch)"
            Write-Step "Extracting drivers for $(Get-OsFriendlyName $first.OsKey) $($first.Arch) (build $($first.Version.Build)) -> $targetDir"
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
            $manifest.Add("[$(Get-OsFriendlyName $first.OsKey) / $($first.Arch) / build $($first.Version)]")
            $manifest.Add('Editions: ' + (($group.Group | ForEach-Object { $_.Name }) -join ', '))

            $copied = 0
            foreach ($drv in $DriverNames) {
                $found = $null
                foreach ($os in $first.OsCandidates) {
                    $p = Join-Path $virtioMount.Root "$drv\$os\$($first.Arch)"
                    if (Test-Path -LiteralPath $p) { $found = [pscustomobject]@{ Os = $os; Path = $p }; break }
                }
                if (-not $found) {
                    # With -AllDrivers many top-level folders (guest-agent, cert, data, ...) are not drivers - skip quietly.
                    if (-not $AllDrivers) { Write-Warning "Driver '$drv' not available for $($first.OsCandidates -join '/') $($first.Arch) on this virtio-win ISO." }
                    continue
                }
                if ($found.Os -ne $first.OsKey) {
                    Write-Warning "'$drv' has no '$($first.OsKey)' folder on this virtio-win ISO; using compatible '$($found.Os)' instead."
                }
                $dest = Join-Path $targetDir $drv
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                Copy-Item -Path (Join-Path $found.Path '*') -Destination $dest -Recurse -Force
                if (-not (Get-ChildItem -LiteralPath $dest -Filter *.inf -Recurse)) { Write-Warning "No .inf found in $dest" }
                $line = '    {0,-14} <- {1}' -f $drv, $found.Path.Substring($virtioMount.Root.Length)
                Write-Host $line
                $manifest.Add($line)
                $copied++
            }
            $manifest.Add('')
            if ($copied -eq 0) { throw "No drivers found for $($first.OsKey) $($first.Arch). Is the virtio-win ISO too old/new for this Windows version?" }
            $driverDirByTarget[$group.Name] = $targetDir
        }

        # --- QEMU guest agent: an MSI per architecture, kept outside the driver folders (it is not a driver) ---
        $guestAgentByArch = @{}
        if (-not $NoGuestAgent) {
            $gaArchName = @{ 'amd64' = 'x86_64'; 'x86' = 'i386'; 'ARM64' = 'aarch64' }
            foreach ($a in ($images | Select-Object -ExpandProperty Arch -Unique)) {
                $msi = Join-Path $virtioMount.Root "guest-agent\qemu-ga-$($gaArchName[$a]).msi"
                if (-not (Test-Path -LiteralPath $msi)) {
                    Write-Warning "QEMU guest agent for $a not found on this virtio-win ISO (expected $($msi.Substring($virtioMount.Root.Length)))."
                    continue
                }
                $gaDir = Join-Path $OutputPath 'guest-agent'
                New-Item -ItemType Directory -Force -Path $gaDir | Out-Null
                Copy-Item -LiteralPath $msi -Destination $gaDir -Force
                $guestAgentByArch[$a] = Join-Path $gaDir (Split-Path $msi -Leaf)
                $line = '    {0,-14} <- {1}' -f 'qemu-ga', $msi.Substring($virtioMount.Root.Length)
                Write-Host $line
                $manifest.Add("[QEMU guest agent / $a]")
                $manifest.Add($line)
            }
        }

        $manifest | Set-Content -LiteralPath (Join-Path $OutputPath 'manifest.txt') -Encoding UTF8
        Write-Host "`nDrivers extracted to: $OutputPath" -ForegroundColor Green
        if (-not $Inject) { return }

        # --- Inject + rebuild ISO ---
        $oscdimg = Find-Oscdimg
        $script:DismExe = Find-Dism
        $script:InjectFailures = New-Object System.Collections.Generic.List[object]
        $isoTree = Join-Path $WorkPath 'iso'
        $mountDir = Join-Path $WorkPath 'mount'

        # Release a mount left behind by an earlier aborted run, and start from a clean copy.
        if ((Test-Path -LiteralPath $mountDir) -and (Get-ChildItem -LiteralPath $mountDir -Force | Select-Object -First 1)) {
            Invoke-Dism @('/Unmount-Image', "/MountDir:$mountDir", '/Discard') | Out-Null
        }
        if (Test-Path -LiteralPath $isoTree) { Remove-Item -LiteralPath $isoTree -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $isoTree, $mountDir | Out-Null

        $dismInfo = (Get-Item -LiteralPath $script:DismExe).VersionInfo
        $maxImageBuild = ($images | ForEach-Object { $_.Version.Build } | Measure-Object -Maximum).Maximum
        Write-Host "    Using DISM $($dismInfo.ProductVersion): $($script:DismExe)"
        # Enablement-package releases share a servicing stack with their base (26200 -> 26100, 22631 -> 22621,
        # 19045 -> 19041), so only a larger gap means a genuinely newer image.
        if ($maxImageBuild - $dismInfo.FileBuildPart -gt 200) {
            Write-Warning "DISM (build $($dismInfo.FileBuildPart)) is older than the Windows image (build $maxImageBuild). Servicing will likely fail with 'The request is not supported'. Install the Windows ADK for build $maxImageBuild or newer."
        }

        Write-Step "Copying Windows ISO contents to $isoTree ..."
        Copy-Item -Path "$($winMount.Root)\*" -Destination $isoTree -Recurse -Force
        Get-ChildItem -LiteralPath $isoTree -Recurse -File | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }

        foreach ($sourcesGroup in ($images | Group-Object SourcesDir)) {
            $sourcesDir = Join-Path $isoTree $sourcesGroup.Name
            $byIndex = @{}
            foreach ($img in $sourcesGroup.Group) { $byIndex[[string]$img.Index] = $driverDirByTarget["$($img.OsKey)|$($img.Arch)"] }
            $default = $driverDirByTarget["$($sourcesGroup.Group[0].OsKey)|$($sourcesGroup.Group[0].Arch)"]

            # install.esd cannot be serviced -> export to install.wim first. Split .swm cannot be serviced at all.
            $installWim = Join-Path $sourcesDir 'install.wim'
            $installEsd = Join-Path $sourcesDir 'install.esd'
            if (Test-Path -LiteralPath $installEsd) {
                Write-Step "Converting $($sourcesGroup.Name)\install.esd to install.wim (this takes a while)..."
                foreach ($ix in (Get-WimImages $installEsd)) {
                    $r = Invoke-Dism @('/Export-Image', "/SourceImageFile:$installEsd", "/SourceIndex:$($ix.Index)", "/DestinationImageFile:$installWim", '/Compress:max', '/CheckIntegrity')
                    if ($r.ExitCode -ne 0) { throw "Converting install.esd index $($ix.Index) failed - $(Get-DismError $r)" }
                }
                Remove-Item -LiteralPath $installEsd -Force
            }

            $bootWim = Join-Path $sourcesDir 'boot.wim'
            if (Test-Path -LiteralPath $bootWim) {
                Add-DriversToWim -WimPath $bootWim -DriverDirByIndex $null -DefaultDriverDir $default -MountDir $mountDir
            }
            if (Test-Path -LiteralPath $installWim) {
                Add-DriversToWim -WimPath $installWim -DriverDirByIndex $byIndex -DefaultDriverDir $default -MountDir $mountDir
            }
            else {
                Write-Warning "$($sourcesGroup.Name)\install.swm (split image) cannot be serviced; only boot.wim was updated. Load the drivers from the extracted folder during setup instead."
            }

            # QEMU guest agent: Setup copies sources\$OEM$\$1 to C:\ and $OEM$\$$ to C:\Windows, then runs
            # Setup\Scripts\SetupComplete.cmd as SYSTEM at the end of installation.
            $gaMsi = $guestAgentByArch[$sourcesGroup.Group[0].Arch]
            if ($gaMsi) {
                $oemRoot = Join-Path $sourcesDir '$OEM$'
                $oemVirtio = Join-Path $oemRoot '$1\virtio'
                $oemScripts = Join-Path $oemRoot '$$\Setup\Scripts'
                New-Item -ItemType Directory -Force -Path $oemVirtio, $oemScripts | Out-Null
                Copy-Item -LiteralPath $gaMsi -Destination $oemVirtio -Force
                $msiName = Split-Path $gaMsi -Leaf
                $setupComplete = Join-Path $oemScripts 'SetupComplete.cmd'
                $lines = @(
                    'rem Added by VirtioIsoBuilder.ps1: install the QEMU guest agent (uses the vioserial driver).'
                    "msiexec /i `"%SystemDrive%\virtio\$msiName`" /qn /norestart /l*v `"%SystemDrive%\virtio\qemu-ga-install.log`""
                )
                if (-not (Test-Path -LiteralPath $setupComplete)) { $lines = @('@echo off') + $lines }
                Add-Content -LiteralPath $setupComplete -Value $lines -Encoding Ascii
                Write-Host '    + qemu-ga (installed by SetupComplete.cmd after Windows Setup)'
            }
        }

        if ($script:InjectFailures.Count) {
            Write-Host "`nDriver injection failures:" -ForegroundColor Red
            $script:InjectFailures | Format-Table Driver, Wim, Index, Detail -AutoSize -Wrap | Out-Host
            $critical = @($script:InjectFailures | Where-Object { $_.Driver -in $BootCriticalDrivers })
            if ($critical.Count) {
                throw "Boot-critical driver(s) $((@($critical.Driver) | Select-Object -Unique) -join ', ') could not be injected; not building an ISO that would not see its VirtIO disk. Details above and in $env:SystemRoot\Logs\DISM\dism.log."
            }
            Write-Warning 'Continuing: only non-boot-critical drivers failed. Install those later from the extracted folder.'
        }

        Write-Step "Building $OutputIso with oscdimg..."
        $etfs = Join-Path $isoTree 'boot\etfsboot.com'
        $efi = Join-Path $isoTree 'efi\microsoft\boot\efisys.bin'
        if ($NoBootPrompt -and (Test-Path -LiteralPath (Join-Path $isoTree 'efi\microsoft\boot\efisys_noprompt.bin'))) {
            $efi = Join-Path $isoTree 'efi\microsoft\boot\efisys_noprompt.bin'
        }
        if ((Test-Path -LiteralPath $etfs) -and (Test-Path -LiteralPath $efi)) { $bootData = "2#p0,e,b$etfs#pEF,e,b$efi" }   # BIOS + UEFI
        elseif (Test-Path -LiteralPath $efi) { $bootData = "1#pEF,e,b$efi" }                                                 # UEFI only (e.g. ARM64)
        elseif (Test-Path -LiteralPath $etfs) { $bootData = "1#p0,e,b$etfs" }                                                # BIOS only (very old media)
        else { throw 'No boot sector files (etfsboot.com / efisys.bin) found in the ISO tree.' }

        $label = $winMount.Label
        if (-not $label) { $label = 'WIN_VIRTIO' }
        if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }

        New-Item -ItemType Directory -Force -Path (Split-Path $OutputIso) | Out-Null
        & $oscdimg -m -o -u2 -udfver102 "-l$label" "-bootdata:$bootData" $isoTree $OutputIso
        if ($LASTEXITCODE -ne 0) { throw "oscdimg failed with exit code $LASTEXITCODE." }

        Write-Step 'Cleaning up work folder...'
        Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "`nNew ISO with VirtIO drivers: $OutputIso" -ForegroundColor Green
    }
    finally {
        Dismount-Iso $winMount
        Dismount-Iso $virtioMount
    }
}

#endregion

#region GUI -------------------------------------------------------------------------------------

function Show-SelectionForm {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:guiBuilds = @()
    $script:guiEditions = @()
    $script:guiResult = $null
    $versionKeys = @($Catalog.Keys)

    function Add-Control($Parent, [string]$Type, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text) {
        $c = New-Object "System.Windows.Forms.$Type"
        $c.Location = New-Object System.Drawing.Point($X, $Y)
        $c.Size = New-Object System.Drawing.Size($W, $H)
        if ($Text) { $c.Text = $Text }
        $Parent.Controls.Add($c)
        $c
    }
    function Add-Combo($Parent, [int]$X, [int]$Y, [int]$W, [switch]$Editable) {
        $c = Add-Control $Parent ComboBox $X $Y $W 24
        $c.DropDownStyle = if ($Editable) { 'DropDown' } else { 'DropDownList' }
        $c
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Windows + VirtIO ISO builder'
    $form.ClientSize = New-Object System.Drawing.Size(640, 570)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # --- Windows ---
    $gWin = Add-Control $form GroupBox 10 8 620 245 'Windows'
    [void](Add-Control $gWin Label 12 28 95 20 'Version')
    $cmbVersion = Add-Combo $gWin 110 25 250
    foreach ($k in $versionKeys) { [void]$cmbVersion.Items.Add($Catalog[$k].Name) }
    [void](Add-Control $gWin Label 12 58 95 20 'Source')
    $cmbSource = Add-Combo $gWin 110 55 330
    [void](Add-Control $gWin Label 12 88 95 20 'Architecture')
    $cmbArch = Add-Combo $gWin 110 85 100
    [void]$cmbArch.Items.AddRange(@('amd64', 'arm64')); $cmbArch.SelectedItem = $Arch
    $btnFind = Add-Control $gWin Button 225 84 120 26 'Find builds'
    [void](Add-Control $gWin Label 12 118 95 20 'Build')
    $cmbBuild = Add-Combo $gWin 110 115 495
    [void](Add-Control $gWin Label 12 148 95 20 'Language')
    $cmbLang = Add-Combo $gWin 110 145 100
    [void](Add-Control $gWin Label 225 148 55 20 'Edition')
    $cmbEdition = Add-Combo $gWin 285 145 320
    [void](Add-Control $gWin Label 12 178 95 20 'Local ISO')
    $txtIso = Add-Control $gWin TextBox 110 175 410 24
    $txtIso.Text = $WindowsIso
    $btnIso = Add-Control $gWin Button 525 174 80 26 'Browse...'
    $lblStatus = Add-Control $gWin Label 12 210 595 28
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray

    # --- virtio-win ---
    $gVirtio = Add-Control $form GroupBox 10 260 620 92 'virtio-win'
    [void](Add-Control $gVirtio Label 12 28 95 20 'Version')
    $cmbVirtio = Add-Combo $gVirtio 110 25 250 -Editable
    $btnVirtioRefresh = Add-Control $gVirtio Button 370 24 120 26 'Refresh list'
    [void](Add-Control $gVirtio Label 12 58 95 20 'or local ISO')
    $txtVirtio = Add-Control $gVirtio TextBox 110 55 410 24
    $txtVirtio.Text = $VirtioIso
    $btnVirtio = Add-Control $gVirtio Button 525 54 80 26 'Browse...'

    # --- Output ---
    $gOut = Add-Control $form GroupBox 10 360 620 158 'Output'
    [void](Add-Control $gOut Label 12 28 95 20 'Work folder')
    $txtWork = Add-Control $gOut TextBox 110 25 410 24
    $txtWork.Text = $WorkRoot
    $btnWork = Add-Control $gOut Button 525 24 80 26 'Browse...'
    [void](Add-Control $gOut Label 12 58 95 20 'Output folder')
    $txtOut = Add-Control $gOut TextBox 110 55 410 24
    $txtOut.Text = $OutputPath
    $btnOut = Add-Control $gOut Button 525 54 80 26 'Browse...'
    $chkAll = Add-Control $gOut CheckBox 110 88 230 22 'All drivers (not only the defaults)'
    $chkAll.Checked = [bool]$AllDrivers
    $chkInject = Add-Control $gOut CheckBox 350 88 255 22 'Inject drivers and build a new ISO'
    $chkInject.Checked = $true
    $chkGuestAgent = Add-Control $gOut CheckBox 110 108 235 22 'QEMU guest agent (qemu-ga)'
    $chkGuestAgent.Checked = -not $NoGuestAgent
    $chkNoPrompt = Add-Control $gOut CheckBox 350 108 255 22 'No "Press any key" on UEFI boot'
    $chkNoPrompt.Checked = [bool]$NoBootPrompt
    $lblOutHint = Add-Control $gOut Label 110 133 495 18 ("Defaults: $($Drivers -join ', '). Empty output folder = <work folder>\output\<ISO name>")
    $lblOutHint.ForeColor = [System.Drawing.Color]::DimGray

    $btnStart = Add-Control $form Button 420 528 100 32 'Start'
    $btnCancel = Add-Control $form Button 530 528 100 32 'Cancel'
    $form.AcceptButton = $btnStart
    $form.CancelButton = $btnCancel

    # --- Logic ---
    $getEntry = { $Catalog[$versionKeys[$cmbVersion.SelectedIndex]] }
    $getSource = { foreach ($k in $SourceNames.Keys) { if ($SourceNames[$k] -eq $cmbSource.SelectedItem) { return $k } } }
    $clearUup = {
        $script:guiBuilds = @(); $script:guiEditions = @()
        $cmbBuild.Items.Clear(); $cmbLang.Items.Clear(); $cmbEdition.Items.Clear()
    }
    $updateState = {
        $src = & $getSource
        foreach ($c in $cmbArch, $btnFind, $cmbBuild, $cmbLang, $cmbEdition) { $c.Enabled = ($src -eq 'UUP') }
        $txtIso.Enabled = ($src -eq 'Local'); $btnIso.Enabled = ($src -eq 'Local')
        switch ($src) {
            'UUP'   { $lblStatus.Text = 'Click "Find builds" to query uupdump.net. The ISO is built locally from Windows Update files (several GB, needs admin).' }
            'Eval'  { $lblStatus.Text = 'Official evaluation ISO (English, x64). Expires after 180 days unless converted to a licensed edition with DISM /Set-Edition.' }
            'Local' { $lblStatus.Text = 'Select your own Windows installation ISO; the version is detected automatically.' }
        }
    }
    $cmbVersion.Add_SelectedIndexChanged({
            $entry = & $getEntry
            $cmbSource.Items.Clear()
            if ($entry.Uup)  { [void]$cmbSource.Items.Add($SourceNames.UUP) }
            if ($entry.Eval) { [void]$cmbSource.Items.Add($SourceNames.Eval) }
            [void]$cmbSource.Items.Add($SourceNames.Local)
            $cmbSource.SelectedIndex = 0
            & $clearUup
        })
    $cmbSource.Add_SelectedIndexChanged({ & $updateState })
    $cmbArch.Add_SelectedIndexChanged({ & $clearUup })

    $btnFind.Add_Click({
            $form.Cursor = 'WaitCursor'
            $lblStatus.Text = 'Querying uupdump.net...'
            $form.Refresh()
            try {
                & $clearUup
                $script:guiBuilds = @(Find-UupBuilds -Entry (& $getEntry) -Arch $cmbArch.SelectedItem -Retries 1)
                foreach ($b in $script:guiBuilds) { [void]$cmbBuild.Items.Add($b.title) }
                if ($script:guiBuilds.Count) {
                    $lblStatus.Text = "$($script:guiBuilds.Count) build(s) found on UUP dump; newest selected."
                    $cmbBuild.SelectedIndex = 0
                }
                else { $lblStatus.Text = 'No matching builds on UUP dump. Use the Evaluation Center or a local ISO instead.' }
            }
            catch {
                $lblStatus.Text = 'UUP dump query failed.'
                [void][System.Windows.Forms.MessageBox]::Show("UUP dump query failed:`n$($_.Exception.Message)", 'UUP dump', 'OK', 'Error')
            }
            finally { $form.Cursor = 'Default' }
        })
    $cmbBuild.Add_SelectedIndexChanged({
            if ($cmbBuild.SelectedIndex -lt 0) { return }
            $form.Cursor = 'WaitCursor'
            try {
                $b = $script:guiBuilds[$cmbBuild.SelectedIndex]
                $lblStatus.Text = 'Loading languages from uupdump.net...'
                $form.Refresh()
                $langs = @((Invoke-UupApi listlangs @{ id = $b.uuid } -Retries 1).langList)
                $cmbLang.Items.Clear(); $cmbEdition.Items.Clear()
                if (-not $langs.Count) { $lblStatus.Text = 'This build has no downloadable files on UUP dump; pick another build.'; return }
                foreach ($l in $langs) { [void]$cmbLang.Items.Add($l) }
                $i = [array]::IndexOf($langs, $Language)
                if ($i -lt 0) { $i = [array]::IndexOf($langs, 'en-us') }
                if ($i -lt 0) { $i = 0 }
                $cmbLang.SelectedIndex = $i
            }
            catch {
                $lblStatus.Text = 'Could not load languages.'
                [void][System.Windows.Forms.MessageBox]::Show("Could not list languages:`n$($_.Exception.Message)", 'UUP dump', 'OK', 'Error')
            }
            finally { $form.Cursor = 'Default' }
        })
    $cmbLang.Add_SelectedIndexChanged({
            if ($cmbLang.SelectedIndex -lt 0) { return }
            $form.Cursor = 'WaitCursor'
            try {
                $b = $script:guiBuilds[$cmbBuild.SelectedIndex]
                $lblStatus.Text = 'Loading editions from uupdump.net...'
                $form.Refresh()
                $resp = Invoke-UupApi listeditions @{ id = $b.uuid; lang = $cmbLang.SelectedItem } -Retries 1
                $script:guiEditions = @($resp.editionList)
                $cmbEdition.Items.Clear()
                foreach ($e in $script:guiEditions) { [void]$cmbEdition.Items.Add("$($resp.editionFancyNames.$e) ($e)") }
                $want = $Edition
                if (-not $want) { $want = (& $getEntry).Uup.Edition }
                $pick = Select-UupEdition $script:guiEditions $want
                if ($pick) { $cmbEdition.SelectedIndex = [array]::IndexOf($script:guiEditions, $pick) }
                $lblStatus.Text = "Ready: $($b.title), $($cmbLang.SelectedItem)."
            }
            catch {
                $lblStatus.Text = 'Could not load editions.'
                [void][System.Windows.Forms.MessageBox]::Show("Could not list editions:`n$($_.Exception.Message)", 'UUP dump', 'OK', 'Error')
            }
            finally { $form.Cursor = 'Default' }
        })

    $loadVirtio = {
        $form.Cursor = 'WaitCursor'
        $cmbVirtio.Items.Clear()
        [void]$cmbVirtio.Items.AddRange(@('stable', 'latest'))
        try { foreach ($v in Get-VirtioVersions) { [void]$cmbVirtio.Items.Add($v) } }
        catch { $lblStatus.Text = "Could not read the virtio-win archive list: $($_.Exception.Message)" }
        $cmbVirtio.Text = $VirtioVersion
        $form.Cursor = 'Default'
    }
    $btnVirtioRefresh.Add_Click($loadVirtio)
    $form.Add_Shown($loadVirtio)

    $browseIso = {
        param($TextBox, $Title)
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = $Title
        $dlg.Filter = 'ISO images (*.iso)|*.iso|All files (*.*)|*.*'
        if ($dlg.ShowDialog() -eq 'OK') { $TextBox.Text = $dlg.FileName }
    }
    $browseFolder = {
        param($TextBox)
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($TextBox.Text) { $dlg.SelectedPath = $TextBox.Text }
        if ($dlg.ShowDialog() -eq 'OK') { $TextBox.Text = $dlg.SelectedPath }
    }
    $btnIso.Add_Click({ & $browseIso $txtIso 'Select the Windows installation ISO' })
    $btnVirtio.Add_Click({ & $browseIso $txtVirtio 'Select a virtio-win ISO' })
    $btnWork.Add_Click({ & $browseFolder $txtWork })
    $btnOut.Add_Click({ & $browseFolder $txtOut })

    $btnStart.Add_Click({
            $src = & $getSource
            $fail = $null
            if ($src -eq 'UUP' -and ($cmbBuild.SelectedIndex -lt 0 -or $cmbLang.SelectedIndex -lt 0 -or $cmbEdition.SelectedIndex -lt 0)) {
                $fail = 'Click "Find builds" and select a UUP dump build, language and edition first.'
            }
            elseif ($src -eq 'Local' -and -not ($txtIso.Text -and (Test-Path -LiteralPath $txtIso.Text))) { $fail = 'Select an existing Windows ISO.' }
            elseif ($txtVirtio.Text -and -not (Test-Path -LiteralPath $txtVirtio.Text)) { $fail = 'The local virtio-win ISO does not exist.' }
            elseif (-not $txtVirtio.Text -and -not $cmbVirtio.Text.Trim()) { $fail = 'Choose a virtio-win version.' }
            elseif (-not $txtWork.Text) { $fail = 'Choose a work folder.' }
            if ($fail) { [void][System.Windows.Forms.MessageBox]::Show($fail, 'Missing input', 'OK', 'Warning'); return }

            $doInject = $chkInject.Checked
            if ($doInject -and -not (Find-Oscdimg)) {
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    "The Windows ADK 'Deployment Tools' (oscdimg.exe) are not installed, so no new ISO can be built.`n`nContinue and only extract the drivers?`n`n(ADK: https://learn.microsoft.com/windows-hardware/get-started/adk-install)",
                    'Windows ADK not found', 'YesNo', 'Warning')
                if ($answer -ne 'Yes') { return }
                $doInject = $false
            }

            $script:guiResult = @{
                Windows       = $versionKeys[$cmbVersion.SelectedIndex]
                Source        = $src
                Arch          = [string]$cmbArch.SelectedItem
                Build         = $(if ($src -eq 'UUP') { $script:guiBuilds[$cmbBuild.SelectedIndex] })
                Language      = $(if ($src -eq 'UUP') { [string]$cmbLang.SelectedItem } else { $Language })
                Edition       = $(if ($src -eq 'UUP') { $script:guiEditions[$cmbEdition.SelectedIndex] })
                WindowsIso    = $(if ($src -eq 'Local') { $txtIso.Text })
                VirtioVersion = $cmbVirtio.Text.Trim()
                VirtioIso     = $txtVirtio.Text
                WorkRoot      = $txtWork.Text
                OutputPath    = $txtOut.Text
                OutputIso     = $OutputIso
                Drivers       = $Drivers
                AllDrivers    = $chkAll.Checked
                Inject        = $doInject
                NoBootPrompt  = $chkNoPrompt.Checked
                NoGuestAgent  = -not $chkGuestAgent.Checked
            }
            $form.DialogResult = 'OK'
            $form.Close()
        })

    $initial = 0
    if ($Windows) { $initial = [array]::IndexOf($versionKeys, $Windows) }
    $cmbVersion.SelectedIndex = [Math]::Max(0, $initial)

    [void]$form.ShowDialog()
    $form.Dispose()
    $script:guiResult
}

#endregion

#region Main ------------------------------------------------------------------------------------

function Resolve-CliSelection {
    $sel = @{
        Windows = $Windows; Source = $Source; Arch = $Arch; Build = $null; Language = $Language; Edition = $Edition
        WindowsIso = $WindowsIso; VirtioVersion = $VirtioVersion; VirtioIso = $VirtioIso; WorkRoot = $WorkRoot
        OutputPath = $OutputPath; OutputIso = $OutputIso; Drivers = $Drivers; AllDrivers = [bool]$AllDrivers
        Inject = [bool]$Inject; NoBootPrompt = [bool]$NoBootPrompt; NoGuestAgent = [bool]$NoGuestAgent
    }
    if ($WindowsIso) { $sel.Source = 'Local'; return $sel }
    if ($sel.Source -eq 'Local') { throw '-Source Local requires -WindowsIso.' }

    $entry = $Catalog[$Windows]
    if ($sel.Source -eq 'Auto') { $sel.Source = $(if ($entry.Uup) { 'UUP' } else { 'Eval' }) }
    if ($sel.Source -eq 'Eval') {
        if (-not $entry.Eval) { throw "$($entry.Name) has no Evaluation Center download; use -Source UUP or -WindowsIso." }
        if ($Arch -ne 'amd64' -or $Language -ne 'en-us') { Write-Warning 'Evaluation ISOs are downloaded as English (en-us) x64.' }
        return $sel
    }

    if (-not $entry.Uup) { throw "$($entry.Name) is not available on UUP dump; use -Source Eval or -WindowsIso." }
    Write-Step "Searching UUP dump for $($entry.Name) ($Arch)..."
    $builds = @(Find-UupBuilds -Entry $entry -Arch $Arch)
    if ($UupBuild) { $builds = @($builds | Where-Object { $_.uuid -eq $UupBuild -or $_.build -eq $UupBuild -or $_.build -like "$UupBuild.*" }) }
    if (-not $builds.Count) {
        if ($Source -eq 'Auto' -and $entry.Eval) {
            Write-Warning 'No matching UUP dump build found; falling back to the Evaluation Center ISO.'
            $sel.Source = 'Eval'
            return $sel
        }
        throw "No matching UUP dump build found for $($entry.Name) $Arch $UupBuild."
    }
    $sel.Build = $builds[0]
    Write-Host "    Build: $($sel.Build.title)"

    $langs = @((Invoke-UupApi listlangs @{ id = $sel.Build.uuid }).langList)
    if ($langs -notcontains $Language) { throw "Language '$Language' not available for this build. Available: $($langs -join ', ')" }
    $editions = @((Invoke-UupApi listeditions @{ id = $sel.Build.uuid; lang = $Language }).editionList)
    $want = $Edition
    if (-not $want) { $want = $entry.Uup.Edition }
    $sel.Edition = Select-UupEdition $editions $want
    if ($sel.Edition -ne $want) { Write-Warning "Edition '$want' not available; using '$($sel.Edition)'. Available: $($editions -join ', ')" }
    $sel
}

function Restart-Elevated($Sel) {
    # Rebuild the command line from the selection and relaunch this script as administrator.
    function Q([string]$s) { ConvertTo-QuotedArg $s }
    $a = New-Object System.Collections.Generic.List[string]
    $a.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Q $PSCommandPath)))
    if ($Sel.Source -eq 'Local') { $a.AddRange([string[]]@('-WindowsIso', (Q $Sel.WindowsIso))) }
    else {
        $a.AddRange([string[]]@('-Windows', $Sel.Windows, '-Source', $Sel.Source, '-Arch', $Sel.Arch, '-Language', $Sel.Language))
        if ($Sel.Build)   { $a.AddRange([string[]]@('-UupBuild', $Sel.Build.uuid)) }
        if ($Sel.Edition) { $a.AddRange([string[]]@('-Edition', $Sel.Edition)) }
    }
    if ($Sel.VirtioIso) { $a.AddRange([string[]]@('-VirtioIso', (Q $Sel.VirtioIso))) }
    else { $a.AddRange([string[]]@('-VirtioVersion', $Sel.VirtioVersion)) }
    $a.AddRange([string[]]@('-WorkRoot', (Q $Sel.WorkRoot), '-Drivers', ($Sel.Drivers -join ',')))
    if ($Sel.OutputPath)   { $a.AddRange([string[]]@('-OutputPath', (Q $Sel.OutputPath))) }
    if ($Sel.OutputIso)    { $a.AddRange([string[]]@('-OutputIso', (Q $Sel.OutputIso))) }
    if ($Sel.AllDrivers)   { $a.Add('-AllDrivers') }
    if ($Sel.Inject)       { $a.Add('-Inject') }
    if ($Sel.NoBootPrompt) { $a.Add('-NoBootPrompt') }
    if ($Sel.NoGuestAgent) { $a.Add('-NoGuestAgent') }
    $a.Add('-PauseAtEnd')

    Write-Step 'Administrator rights are needed (DISM / UUP conversion); relaunching elevated in a new window...'
    try { Start-Process -FilePath $WinPowerShell -ArgumentList ($a -join ' ') -Verb RunAs | Out-Null }
    catch { throw "Could not start an elevated PowerShell (UAC cancelled?): $($_.Exception.Message)" }
}

function Invoke-Build($Sel) {
    if ($Sel.Inject -and -not (Find-Oscdimg)) {
        throw 'oscdimg.exe not found. Install the Windows ADK "Deployment Tools" feature (https://learn.microsoft.com/windows-hardware/get-started/adk-install), or run without -Inject to only extract the drivers.'
    }
    if (($Sel.Inject -or $Sel.Source -eq 'UUP') -and -not (Test-IsAdmin)) {
        if (-not $PSCommandPath) { throw 'Administrator rights are required for -Inject and the UUP source. Run PowerShell as Administrator.' }
        Restart-Elevated $Sel
        return
    }

    New-Item -ItemType Directory -Force -Path $Sel.WorkRoot | Out-Null
    $root = (Resolve-Path -LiteralPath $Sel.WorkRoot).Path
    $logDir = Join-Path $root 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $log = Join-Path $logDir ("VirtioIsoBuilder-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    try { Start-Transcript -LiteralPath $log | Out-Null } catch { }
    Write-Host "Log: $log"
    try {
        switch ($Sel.Source) {
            'Local' { $winIso = (Resolve-Path -LiteralPath $Sel.WindowsIso).Path }
            'Eval'  { $winIso = Get-EvalIso -Key $Sel.Windows -Root $root }
            'UUP'   { $winIso = Get-UupIso -Build $Sel.Build -Lang $Sel.Language -EditionName $Sel.Edition -Root $root }
        }
        $virtioPath = $Sel.VirtioIso
        if ($virtioPath) { $virtioPath = (Resolve-Path -LiteralPath $virtioPath).Path }
        else { $virtioPath = Get-VirtioIso -Version $Sel.VirtioVersion -Root $root }

        $winName = [IO.Path]::GetFileNameWithoutExtension($winIso)
        $virtioName = [IO.Path]::GetFileNameWithoutExtension($virtioPath)
        $out = $Sel.OutputPath
        if (-not $out) { $out = Join-Path $root "output\$winName" }
        $isoOut = $Sel.OutputIso
        if (-not $isoOut) { $isoOut = Join-Path $out "$winName-$virtioName.iso" }

        Invoke-VirtioProcess -WindowsIso $winIso -VirtioIso $virtioPath -OutputPath (Join-Path $out "drivers-$virtioName") `
            -DriverNames $Sel.Drivers -AllDrivers $Sel.AllDrivers -Inject $Sel.Inject -OutputIso $isoOut `
            -WorkPath (Join-Path $root 'inject-tmp') -NoBootPrompt $Sel.NoBootPrompt -NoGuestAgent $Sel.NoGuestAgent
        Write-Host "`nDone. Output: $out" -ForegroundColor Green
    }
    finally {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

if ($PSVersionTable.PSEdition -eq 'Core' -and $PSCommandPath) {
    # Started from PowerShell 7 (e.g. Windows Terminal): run the whole tool in Windows PowerShell 5.1 with its own
    # module path, so UUP dump's helper scripts and the elevated relaunch behave the same as from powershell.exe.
    Write-Host 'Started from PowerShell 7 - continuing in Windows PowerShell 5.1...' -ForegroundColor DarkGray
    $env:PSModulePath = Get-WinPSModulePath
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File $(ConvertTo-QuotedArg $PSCommandPath) $(ConvertTo-ArgString $PSBoundParameters)"
    $p = Start-Process -FilePath $WinPowerShell -ArgumentList $argLine -NoNewWindow -Wait -PassThru
    exit $p.ExitCode
}

$exitCode = 0
try {
    if ($ListVirtioVersions) {
        @('stable', 'latest') + @(Get-VirtioVersions)
        return
    }
    if ($ListBuilds) {
        if (-not $Windows) { throw '-ListBuilds requires -Windows.' }
        Find-UupBuilds -Entry $Catalog[$Windows] -Arch $Arch | Format-Table title, build, uuid -AutoSize
        return
    }

    if (-not $Windows -and -not $WindowsIso) {
        $PauseAtEnd = $true   # GUI mode is usually started by double-click / "Run with PowerShell"
        $selection = Show-SelectionForm
        if (-not $selection) { Write-Host 'Cancelled.'; $PauseAtEnd = $false; return }
    }
    else {
        $selection = Resolve-CliSelection
    }
    Invoke-Build $selection
}
catch {
    $exitCode = 1
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "       at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
}
finally {
    if ($PauseAtEnd) { [void](Read-Host "`nPress Enter to close") }
}
if ($exitCode) { exit $exitCode }

#endregion
