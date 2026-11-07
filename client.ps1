# ur-vpn client for Windows 10, 11 and Windows Server.
#
#     irm https://raw.githubusercontent.com/Henryle-hd/ur-vps-ur-vpn/main/client.ps1 | iex
#
# Asks for the block your server printed, installs the official signed OpenVPN
# package, sets up the service that starts at boot, connects, and checks your
# traffic uses the VPN.
#
# From a clone:
#
#     powershell -ExecutionPolicy Bypass -File client.ps1 [-Action install|start|stop|restart|status|top|update|version|remove] [-ProfilePath FILE]
#
# Keep this file plain ASCII: Windows PowerShell 5.1 misreads UTF-8 without a BOM.
# Do not add #Requires: it is an err    or under Invoke-Expression.

param(
    [ValidateSet('install', 'start', 'stop', 'restart', 'on', 'off', 'status', 'top', 'update', 'version', 'remove')]
    [string]$Action = 'install',
    [string]$ProfilePath = '',
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- Constants ----------------------------------------------------------------

$RawBase = if ($env:UR_VPN_RAW) { $env:UR_VPN_RAW } else { 'https://raw.githubusercontent.com/Henryle-hd/ur-vps-ur-vpn/main' }
$ReleaseBase = if ($env:UR_VPN_RELEASE_URL) { $env:UR_VPN_RELEASE_URL } else { 'https://github.com/Henryle-hd/ur-vps-ur-vpn/releases/latest/download' }

# The release workflow stamps this. "dev" means installed from the main branch.
$Version = 'dev'

$FallbackVersion = '2.7.9-I001'
$ConnectTimeoutSeconds = 60
$ServiceName = 'OpenVPNService'
$ConfigName = 'ur-vpn'
$StateDir = Join-Path $env:ProgramData 'ur-vpn'

# --- Small helpers ------------------------------------------------------------

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Green }

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OpenVpnPaths {
    $root = Join-Path $env:ProgramFiles 'OpenVPN'
    $paths = @{
        Exe        = Join-Path $root 'bin\openvpn.exe'
        ConfigAuto = Join-Path $root 'config-auto'
        LogDir     = Join-Path $root 'log'
    }
    $registry = Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenVPN' -ErrorAction SilentlyContinue
    if ($registry) {
        if ($registry.exe_path) { $paths.Exe = $registry.exe_path }
        if ($registry.autostart_config_dir) { $paths.ConfigAuto = $registry.autostart_config_dir.TrimEnd('\') }
        if ($registry.log_dir) { $paths.LogDir = $registry.log_dir.TrimEnd('\') }
    }
    return $paths
}

function Get-LogPath { return (Join-Path (Get-OpenVpnPaths).LogDir "$ConfigName.log") }

# ==============================================================================
#  The whole story
# ==============================================================================

function Invoke-Install([string]$Path) {
    $profileText = Get-VpnProfile $Path
    Write-Step 'Profile accepted'
    Install-OpenVpn
    Set-ProfileFile $profileText
    Save-ManagementCopy

    Write-Step 'Connecting'
    $started = Get-Date
    Start-VpnService
    if (Wait-VpnConnection $started) {
        Show-Connected $profileText
    } else {
        Show-ConnectFailure
    }
}

function Show-Connected([string]$ProfileText) {
    Write-Host ''
    Write-Host 'Connected. The VPN also starts by itself at boot.' -ForegroundColor Green
    Show-PublicIp $ProfileText
    Write-Host ''
    Write-Host 'Manage it from an Administrator PowerShell:'
    $managed = Join-Path $StateDir 'client.ps1'
    if (Test-Path -LiteralPath $managed) {
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$managed`" -Action stop|start|restart|status|update|remove"
    } else {
        Write-Host '  Stop-Service OpenVPNService    disconnect'
        Write-Host '  Start-Service OpenVPNService   reconnect'
    }
}

function Show-ConnectFailure {
    Write-Host ''
    Write-Host "The VPN is installed but did not connect within $ConnectTimeoutSeconds seconds." -ForegroundColor Red
    Write-Host 'The usual cause is the provider''s firewall blocking the VPN port. Allow it in the'
    Write-Host 'provider''s web panel. OpenVPN keeps retrying by itself, so it will connect once it is open.'
    Write-Host "Log: $(Get-LogPath)"
}

function Show-PublicIp([string]$ProfileText) {
    $server = ''
    if ($ProfileText -match '(?m)^remote\s+(\S+)') { $server = $Matches[1] }
    try {
        $address = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15).ToString().Trim()
    } catch {
        Write-Host 'Connected, but the internet check through the VPN failed.' -ForegroundColor Yellow
        Write-Host "See the log: $(Get-LogPath)"
        return
    }
    if ($address -eq $server) {
        Write-Host "Your public IP is now $address, the VPN server."
    } else {
        Write-Host "Your public IP is now $address."
    }
}

# --- The profile --------------------------------------------------------------

function Get-VpnProfile([string]$Path) {
    if (-not $Path) {
        $profileText = ConvertFrom-ProfileBlock (Read-PastedBlock)
    } elseif (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot read $Path"
    } else {
        $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path)
        $isBlock = $text -match 'BEGIN UR-VPN PROFILE'
        $profileText = if ($isBlock) { ConvertFrom-ProfileBlock $text } else { $text }
    }

    $required = '(?m)^client', '(?m)^remote ', '<ca>', '<key>'
    foreach ($pattern in $required) {
        if ($profileText -notmatch $pattern) { throw 'That is not a valid VPN profile.' }
    }
    return $profileText
}

function Read-PastedBlock {
    Write-Host ''
    Write-Host 'Paste the block from your server, then press Enter.' -ForegroundColor White
    Write-Host '(Or copy it and just press Enter to read it from the clipboard.)'
    Write-Host 'If Windows warns about pasting multiple lines, choose "Paste anyway".'
    Write-Host ''

    $first = [Console]::ReadLine()
    if ([string]::IsNullOrWhiteSpace($first)) {
        $clipboard = Get-Clipboard -Raw
        if ($clipboard -notmatch 'BEGIN UR-VPN PROFILE') {
            throw 'The clipboard does not contain the block. Copy it from the server and try again.'
        }
        return $clipboard
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $line = $first
    while ($null -ne $line) {
        $lines.Add($line)
        if (($line -replace '\s', '') -like '*ENDUR-VPNPROFILE*') { break }
        $line = [Console]::ReadLine()
    }
    return ($lines -join "`n")
}

function ConvertFrom-ProfileBlock([string]$Text) {
    $inside = $false
    $complete = $false
    $base64 = New-Object System.Text.StringBuilder
    foreach ($rawLine in ($Text -split "`n")) {
        # Terminals and chat apps add stray spaces and carriage returns.
        $line = $rawLine -replace '\s', ''
        if ($line -like '*BEGINUR-VPNPROFILE*') {
            $inside = $true
            [void]$base64.Clear()
        } elseif ($line -like '*ENDUR-VPNPROFILE*') {
            $complete = $inside
            break
        } elseif ($inside) {
            [void]$base64.Append($line)
        }
    }
    if (-not $complete) { throw 'The block is incomplete. Copy all of it, including the BEGIN and END lines.' }

    try {
        $bytes = [Convert]::FromBase64String($base64.ToString())
        $memory = New-Object System.IO.MemoryStream(, $bytes)
        $gzip = New-Object System.IO.Compression.GzipStream($memory, [System.IO.Compression.CompressionMode]::Decompress)
        $reader = New-Object System.IO.StreamReader($gzip)
        $profileText = $reader.ReadToEnd()
        $reader.Dispose()
    } catch {
        throw 'That block is damaged. Copy it again from the server (ur-vpn show NAME).'
    }
    return $profileText
}

# --- Installing OpenVPN -------------------------------------------------------

function Install-OpenVpn {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service -and (Test-Path -LiteralPath (Get-OpenVpnPaths).Exe)) {
        Write-Step 'OpenVPN is already installed'
        return
    }

    $url = Get-InstallerUrl (Get-Architecture)
    $installer = Join-Path $env:TEMP ('ur-vpn-' + [guid]::NewGuid().ToString('N') + '.msi')
    Write-Step "Downloading $url"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $installer

    # An HTTPS download alone does not prove the installer is genuine.
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if (($signature.Status -ne 'Valid') -or ($signature.SignerCertificate.Subject -notmatch 'OpenVPN')) {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        throw "The OpenVPN installer failed its signature check ($($signature.Status))."
    }

    Write-Step 'Installing OpenVPN (this can take a minute)'
    $log = Join-Path $env:TEMP 'ur-vpn-msi.log'
    $arguments = "/i `"$installer`" /qn /norestart /l*v `"$log`""
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue

    # 3010 means success with a reboot requested; the VPN works without one.
    if (($process.ExitCode -ne 0) -and ($process.ExitCode -ne 3010)) {
        throw "The OpenVPN installer failed with code $($process.ExitCode). Log: $log"
    }
    if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        throw 'OpenVPN installed, but its auto-start service is missing.'
    }
}

function Get-Architecture {
    # Under x64 emulation on ARM, PROCESSOR_ARCHITEW6432 holds the real value.
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($architecture) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        'x86'   { return 'x86' }
        default { throw "Unsupported processor: $architecture" }
    }
}

function Get-InstallerUrl([string]$Architecture) {
    try {
        $page = Invoke-WebRequest -UseBasicParsing -Uri 'https://openvpn.net/community-downloads/' -TimeoutSec 20
        $pattern = "https://swupdate\.openvpn\.(org|net)/community/releases/OpenVPN-[0-9.]+-I[0-9]+-$Architecture\.msi"
        $latest = [regex]::Matches($page.Content, $pattern) | ForEach-Object { $_.Value } |
            Sort-Object { [version](($_ -replace '.*OpenVPN-', '') -replace '-I.*', '') } -Descending |
            Select-Object -First 1
        if ($latest) { return $latest }
    } catch {
        Write-Host 'Could not read the latest version from openvpn.net, using the known-good one.'
    }
    return "https://swupdate.openvpn.org/community/releases/OpenVPN-$FallbackVersion-$Architecture.msi"
}

# --- Setting it up ------------------------------------------------------------

function Set-ProfileFile([string]$ProfileText) {
    $paths = Get-OpenVpnPaths
    if (-not (Test-Path -LiteralPath $paths.ConfigAuto)) {
        New-Item -ItemType Directory -Path $paths.ConfigAuto | Out-Null
    }
    $target = Join-Path $paths.ConfigAuto "$ConfigName.ovpn"
    [IO.File]::WriteAllText($target, $ProfileText, (New-Object System.Text.ASCIIEncoding))

    # The folder inherits read access for all Users, but this file holds a private
    # key. Keep Administrators, SYSTEM, and the account OpenVPNService runs under.
    $result = & icacls.exe $target /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' /grant 'NT SERVICE\OpenVPNService:R' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not protect the profile file: $result" }
}

function Save-ManagementCopy {
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir | Out-Null
    }
    $target = Join-Path $StateDir 'client.ps1'
    if ($PSCommandPath -and ($PSCommandPath -ne $target)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force
    }
}

function Start-VpnService {
    # The installer leaves this service disabled.
    Set-Service -Name $ServiceName -StartupType Automatic
    if ((Get-Service -Name $ServiceName).Status -eq 'Running') {
        Restart-Service -Name $ServiceName -Force
    } else {
        Start-Service -Name $ServiceName
    }
}

function Stop-VpnService {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Set-Service -Name $ServiceName -StartupType Disabled
}

function Wait-VpnConnection([datetime]$Since) {
    $log = Get-LogPath
    $deadline = (Get-Date).AddSeconds($ConnectTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path -LiteralPath $log) -and ((Get-Item -LiteralPath $log).LastWriteTime -ge $Since)) {
            # OpenVPN has the file open for writing, so share it when reading.
            $stream = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
            $reader = New-Object IO.StreamReader($stream)
            $content = $reader.ReadToEnd()
            $reader.Dispose()
            if ($content -match 'Initialization Sequence Completed') { return $true }
        }
        Start-Sleep -Seconds 2
        Write-Host '.' -NoNewline
    }
    Write-Host ''
    return $false
}

# ==============================================================================
#  The other actions
# ==============================================================================

function Show-Status {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Host 'VPN: not installed'
        return
    }
    Write-Host "Service: $($service.Status)"
    try {
        $address = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).ToString().Trim()
    } catch {
        $address = 'unknown'
    }
    Write-Host "Public IP: $address"
}

# --- The live view ------------------------------------------------------------

function Format-Bytes([double]$Bytes) {
    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $index = 0
    while (($Bytes -ge 1024) -and ($index -lt 4)) {
        $Bytes /= 1024
        $index++
    }
    if ($index -eq 0) { return ('{0:0} B' -f $Bytes) }
    return ('{0:0.0} {1}' -f $Bytes, $units[$index])
}

# Networks drop the odd packet, so one lost ping means nothing: it takes several
# in a row to say the internet is gone, and a few pings to judge the loss.
function Get-VpnHealth([bool]$Connected, $LatencyMs, [int]$Sent, [int]$Lost, [int]$Misses) {
    if (-not $Connected) { return 'not connected' }
    if ($Sent -eq 0) { return 'checking' }
    if ($Misses -ge 3) { return 'no internet' }
    if (($null -ne $LatencyMs) -and ($LatencyMs -ge 300)) { return 'slow' }
    if (($Sent -ge 5) -and (($Lost * 100 / $Sent) -ge 10)) { return 'slow' }
    return 'good'
}

# The adapter internet traffic leaves by, if it is OpenVPN's.
function Get-VpnAdapter {
    try {
        $route = Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction Stop | Where-Object { $_.InterfaceAlias } | Select-Object -First 1
        if (-not $route) { return $null }
        $adapter = Get-NetAdapter -InterfaceAlias $route.InterfaceAlias -ErrorAction Stop
        if ($adapter.InterfaceDescription -match 'OpenVPN|TAP-Win|Wintun') { return $adapter }
    } catch {
        return $null
    }
    return $null
}

function Get-PingMs {
    try {
        $reply = (New-Object Net.NetworkInformation.Ping).Send('1.1.1.1', 1000)
        if ($reply.Status -eq 'Success') { return [int]$reply.RoundtripTime }
    } catch {
        return $null
    }
    return $null
}

function Get-PublicIp {
    try {
        return (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 3).ToString().Trim()
    } catch {
        return 'unknown'
    }
}

function Write-TopFrame($State) {
    $health = Get-VpnHealth $State.Connected $State.LatencyMs $State.Sent $State.Lost $State.Misses
    $color = switch ($health) {
        'good' { 'Green' }
        { $_ -in 'slow', 'checking' } { 'Yellow' }
        default { 'Red' }
    }
    Write-Host "ur-vpn top  $Version   $(Get-Date -Format 'HH:mm:ss')   press q to quit"
    Write-Host ''
    Write-Host 'Health     ' -NoNewline
    Write-Host $health -ForegroundColor $color
    if (-not $State.Connected) {
        Write-Host 'Connect with: -Action start'
        return
    }
    Write-Host 'VPN        connected'
    Write-Host "Public IP  $($State.PublicIp)"
    $loss = if ($State.Sent -gt 0) { [int]($State.Lost * 100 / $State.Sent) } else { 0 }
    $latency = if ($null -eq $State.LatencyMs) { 'no reply' } else { "$($State.LatencyMs) ms" }
    Write-Host "Latency    $latency   loss $loss%"
    Write-Host ('Speed      down {0,-12} up {1}' -f ((Format-Bytes $State.DownRate) + '/s'), ((Format-Bytes $State.UpRate) + '/s'))
    Write-Host ('Total      down {0,-12} up {1}' -f (Format-Bytes $State.Down), (Format-Bytes $State.Up))
}

function Update-TopState($State) {
    $adapter = Get-VpnAdapter
    $State.Connected = [bool]$adapter
    if (-not $adapter) {
        $State.DownRate = 0
        $State.UpRate = 0
        return
    }
    $stats = Get-NetAdapterStatistics -Name $adapter.Name
    $now = Get-Date
    $seconds = ($now - $State.At).TotalSeconds
    if (($State.At -ne [datetime]::MinValue) -and ($seconds -gt 0) -and ($stats.ReceivedBytes -ge $State.Down)) {
        $State.DownRate = ($stats.ReceivedBytes - $State.Down) / $seconds
        $State.UpRate = [Math]::Max(0, ($stats.SentBytes - $State.Up) / $seconds)
    }
    $State.Down = $stats.ReceivedBytes
    $State.Up = $stats.SentBytes
    $State.At = $now

    $State.LatencyMs = Get-PingMs
    $State.Sent++
    if ($null -eq $State.LatencyMs) {
        $State.Lost++
        $State.Misses++
    } else {
        $State.Misses = 0
    }
    if ($State.Sent -ge 40) {
        $State.Sent = [int]($State.Sent / 2)
        $State.Lost = [int]($State.Lost / 2)
    }
    if (($State.Ticks % 30) -eq 0) { $State.PublicIp = Get-PublicIp }
    $State.Ticks++
}

function Show-Top([bool]$PrintOnce) {
    $state = @{
        Connected = $false; LatencyMs = $null; Sent = 0; Lost = 0; Misses = 0; Ticks = 0; PublicIp = 'checking'
        Down = 0; Up = 0; DownRate = 0; UpRate = 0; At = [datetime]::MinValue
    }
    if ($PrintOnce -or [Console]::IsOutputRedirected -or [Console]::IsInputRedirected) {
        Update-TopState $state
        Start-Sleep -Seconds 1
        Update-TopState $state
        Write-TopFrame $state
        return
    }
    while ($true) {
        Update-TopState $state
        Clear-Host
        Write-TopFrame $state
        $deadline = (Get-Date).AddSeconds(1)
        while ((Get-Date) -lt $deadline) {
            if ([Console]::KeyAvailable) {
                if ([Console]::ReadKey($true).KeyChar -in 'q', 'Q') { return }
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

# Only this script changes: the VPN stays as it is, connected or off.
function Update-Vpn {
    $work = Join-Path $env:TEMP ('ur-vpn-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $file = Join-Path $work 'client.ps1'
        $sums = Join-Path $work 'SHA256SUMS'
        Write-Step 'Checking for a new release'
        Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseBase/client.ps1" -OutFile $file
        Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseBase/SHA256SUMS" -OutFile $sums

        $latest = Get-ReleaseVersion $file $sums
        if ($latest -eq $Version) {
            Write-Host "Already on the latest release, $Version."
            return
        }
        if (-not (Test-Path -LiteralPath $StateDir)) {
            New-Item -ItemType Directory -Path $StateDir | Out-Null
        }
        Copy-Item -LiteralPath $file -Destination (Join-Path $StateDir 'client.ps1') -Force
        Write-Host "Updated from $Version to $latest."
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Returns the version of a downloaded release, or throws if it is not intact.
function Get-ReleaseVersion([string]$File, [string]$Sums) {
    $entry = Get-Content -LiteralPath $Sums | Where-Object { $_ -match '\sclient\.ps1$' } | Select-Object -First 1
    $expected = if ($entry) { ($entry -split '\s+')[0] } else { '' }
    if ((-not $expected) -or ($expected -ne (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash)) {
        throw 'The download failed its checksum. Nothing was changed.'
    }

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$tokens, [ref]$errors)
    if ($errors) { throw 'The download is not a valid script. Nothing was changed.' }

    $line = Select-String -LiteralPath $File -Pattern "^\`$Version = '(.+)'" | Select-Object -First 1
    if (-not $line) { throw 'The download has no version. Nothing was changed.' }
    return $line.Matches[0].Groups[1].Value
}

function Remove-Vpn {
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { Stop-VpnService }
    $paths = Get-OpenVpnPaths
    Remove-Item -LiteralPath (Join-Path $paths.ConfigAuto "$ConfigName.ovpn") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Get-LogPath) -Force -ErrorAction SilentlyContinue
    # PowerShell holds no lock on a running script, so it can delete its own copy.
    Remove-Item -LiteralPath $StateDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Removed the VPN profile. OpenVPN itself is still installed; remove it from Settings > Apps if you want.'
}

# Reopen as Administrator. Under "irm | iex" there is no file to relaunch, so
# download one. -NoExit keeps the new window open so the result can be read.
function Invoke-Elevated {
    $script = $PSCommandPath
    if (-not $script) {
        $script = Join-Path $env:TEMP 'ur-vpn-client.ps1'
        Invoke-WebRequest -UseBasicParsing -Uri "$RawBase/client.ps1" -OutFile $script
    }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$script`" -Action $Action"
    if ($ProfilePath) {
        $arguments += " -ProfilePath `"$((Resolve-Path -LiteralPath $ProfilePath).Path)`""
    }
    Write-Host 'Opening an Administrator window. Approve the prompt and continue there.'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments
}

function Invoke-Main {
    # Windows PowerShell 5.1 can default to TLS 1.0, which these sites reject.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if ($Action -eq 'version') {
        Write-Host $Version
        return
    }
    if ($Action -eq 'top') {
        Show-Top $Once.IsPresent
        return
    }
    if (-not (Test-Admin)) {
        Invoke-Elevated
        return
    }
    switch ($Action) {
        'install' { Invoke-Install $ProfilePath }
        { $_ -in 'start', 'on' } { Start-VpnService; Write-Host 'VPN starting.' }
        { $_ -in 'stop', 'off' } { Stop-VpnService; Write-Host 'VPN off. It stays off until you run -Action start.' }
        'restart' { Start-VpnService; Write-Host 'VPN restarting.' }
        'status'  { Show-Status }
        'update'  { Update-Vpn }
        'remove'  { Remove-Vpn }
    }
}

# Tests dot-source this file to reach the functions without side effects.
if ($env:UR_VPN_PS_TEST -ne '1') {
    try {
        Invoke-Main
    } catch {
        # No "exit" here: under "irm | iex" it would close the user's window.
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }
}
