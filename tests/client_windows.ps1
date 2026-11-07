# Tests client.ps1 on Windows: reading profiles, and with -Install, downloading and
# verifying the real OpenVPN installer and locking down the profile file. No tunnel:
# that needs a server, which tests/e2e.sh covers on Linux.
#
#     powershell -ExecutionPolicy Bypass -File tests\client_windows.ps1 [-Install]
#
# -Install really changes the machine, so it is meant for a throwaway CI runner.

param([switch]$Install)

$env:UR_VPN_PS_TEST = '1'
. (Join-Path $PSScriptRoot '..\client.ps1')

$passed = 0
$failed = 0

function Report([bool]$Success, [string]$Name) {
    if ($Success) {
        Write-Host "  ok    $Name"
        $script:passed++
    } else {
        Write-Host "  FAIL  $Name"
        $script:failed++
    }
}

function Expect([string]$Name, [scriptblock]$Test) {
    try {
        Report ([bool](& $Test)) $Name
    } catch {
        Report $false "$Name ($($_.Exception.Message))"
    }
}

function Refuses([string]$Name, [scriptblock]$Test) {
    try {
        & $Test | Out-Null
        Report $false $Name
    } catch {
        Report $true $Name
    }
}

# --- Fixtures -----------------------------------------------------------------

# Built with lines, not a here-string, so the file's own line endings can't leak in.
$sample = ('client', 'dev tun', 'proto udp', 'remote 203.0.113.9 1194', '<ca>', 'x', '</ca>', '<key>', 'y', '</key>', '') -join "`n"

# What the server prints: gzip -9nc | base64 | fold -w 64
$base64Lines = @(
    'H4sIAAAAAAACA0vOyUzNK+FKSS1TKCnN4yooyi/JVyhNKeAqSs3NL0lVMDIw1jPQ'
    'MzQ01rNUMDS0NOGySU6046rgstEH0TbZqZV2XJVAHpgBAIGqlT1NAAAA'
)
$begin = '-----BEGIN UR-VPN PROFILE-----'
$end = '-----END UR-VPN PROFILE-----'

$block = (@($begin) + $base64Lines + @($end)) -join "`n"
$dirty = "some terminal noise`r`n" + (((@($begin) + $base64Lines + @($end)) | ForEach-Object { "   $_  " }) -join "`r`n") + "`r`nprompt> `r`n"
$damaged = (@($begin) + @(('A' * 32) + $base64Lines[0].Substring(32)) + $base64Lines[1] + @($end)) -join "`n"
$cutOff = (@($begin) + $base64Lines) -join "`n"

function Write-Fixture([string]$Text) {
    $path = Join-Path $env:TEMP ('ur-vpn-test-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($path, $Text)
    return $path
}

# --- Reading the profile ------------------------------------------------------

Expect 'block decodes to the exact profile' { (ConvertFrom-ProfileBlock $block) -ceq $sample }
Expect 'survives CRLF, indents and surrounding text' { (ConvertFrom-ProfileBlock $dirty) -ceq $sample }
Refuses 'rejects a damaged block' { ConvertFrom-ProfileBlock $damaged }
Refuses 'rejects a block with no END line' { ConvertFrom-ProfileBlock $cutOff }

Expect 'reads a block from a file' { (Get-VpnProfile (Write-Fixture $block)) -ceq $sample }
Expect 'accepts a plain .ovpn' { (Get-VpnProfile (Write-Fixture $sample)) -ceq $sample }
Refuses "rejects a file that isn't a profile" { Get-VpnProfile (Write-Fixture 'not a profile') }
Refuses 'rejects a missing file' { Get-VpnProfile 'C:\does\not\exist.ovpn' }

# --- Checking a downloaded release --------------------------------------------

$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\client.ps1'))
$stamped = $source -replace "(?m)^\`$Version = 'dev'", "`$Version = 'v9.9.9'"

function Write-Release([string]$Text) {
    $file = Write-Fixture $Text
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
    return @{ File = $file; Sums = (Write-Fixture "$hash  client.ps1`n") }
}

$good = Write-Release $stamped
$broken = Write-Release 'function {'
$unstamped = Write-Release '# no version here'
$tampered = Write-Release $stamped
Add-Content -LiteralPath $tampered.File -Value '# changed after the checksum'

Expect 'release reports its version' { (Get-ReleaseVersion $good.File $good.Sums) -ceq 'v9.9.9' }
Refuses 'rejects a tampered release' { Get-ReleaseVersion $tampered.File $tampered.Sums }
Refuses 'rejects a release that does not parse' { Get-ReleaseVersion $broken.File $broken.Sums }
Refuses 'rejects a release with no version' { Get-ReleaseVersion $unstamped.File $unstamped.Sums }

# --- The live view ------------------------------------------------------------

Expect 'formats bytes' { (Format-Bytes 512) -ceq '512 B' }
Expect 'formats megabytes' { (Format-Bytes (5 * 1024 * 1024)) -ceq '5.0 MB' }
Expect 'health: not connected' { (Get-VpnHealth $false $null 0 0 0) -ceq 'not connected' }
Expect 'health: checking' { (Get-VpnHealth $true $null 0 0 0) -ceq 'checking' }
Expect 'health: good' { (Get-VpnHealth $true 30 5 0 0) -ceq 'good' }
Expect 'health: slow on latency' { (Get-VpnHealth $true 400 5 0 0) -ceq 'slow' }
Expect 'health: slow on packet loss' { (Get-VpnHealth $true 30 10 2 0) -ceq 'slow' }
Expect 'health: one lost ping is not an outage' { (Get-VpnHealth $true $null 1 1 1) -ceq 'good' }
Expect 'health: no internet after several lost pings' { (Get-VpnHealth $true $null 5 3 3) -ceq 'no internet' }
Expect 'top prints once without a VPN' { Show-Top $true; $true }

# --- Installing, on a throwaway machine ---------------------------------------

if ($Install) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Expect 'signed installer downloads and installs' { Install-OpenVpn; $true }
    Expect 'openvpn.exe is in place' { Test-Path -LiteralPath (Get-OpenVpnPaths).Exe }
    Expect 'auto-start service exists' { Get-Service -Name $ServiceName }
    Expect 'running it again changes nothing' { Install-OpenVpn; $true }

    Set-ProfileFile $sample
    $target = Join-Path (Get-OpenVpnPaths).ConfigAuto "$ConfigName.ovpn"
    $acl = Get-Acl -LiteralPath $target
    $people = @($acl.Access | ForEach-Object { $_.IdentityReference.Value })

    Expect 'profile file is written as given' { [IO.File]::ReadAllText($target) -ceq $sample }
    Expect 'profile file inherits nothing' { $acl.AreAccessRulesProtected }
    Expect 'ordinary users cannot read the private key' { -not ($people -match 'Users|Everyone') }
    Expect 'the OpenVPN service can read it' { $people -contains 'NT SERVICE\OpenVPNService' }
}

Write-Host ''
Write-Host "$passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
