param(
    [ValidateSet('AllNodes','RoleGrouped')]
    [string]$PermutationMode = 'AllNodes',

    [ValidateRange(4,60)]
    [int]$ObservationSeconds = 8,

    [ValidateRange(0,31)]
    [int]$StartMask = 0,

    [ValidateRange(0,31)]
    [int]$EndMask = 31
)

$ErrorActionPreference = 'Stop'

# ============================================================
# EKSPERIMENT 09 - TLS PERMUTACIJE
#
# Default: AllNodes
#   SERVER, NIDS, AGENT-01, AGENT-02, AGENT-03 imaju svaki
#   vlastiti TLS bit -> 2^5 = 32 permutacije.
#
# RoleGrouped:
#   sva 3 agenta imaju isti TLS bit -> SERVER/NIDS/AGENTS
#   -> 2^3 = 8 permutacija.
#
# Za SVAKU permutaciju:
#   1) clean.sh na svih 5 TLS cvorova
#   2) iz originalnih configa napravi potpune nove config datoteke
#   3) SCP upload configa na odgovarajuce cvorove
#   4) provjeri stvarno postavljene TLS vrijednosti
#   5) pokreni server, NIDS i sva 3 agenta
#   6) pricekaj kratki runtime
#   7) napravi benigni komunikacijski probe bez napada
#   8) spremi sto su ispisali SERVER/NIDS/AGENT-01/02/03
#   9) clean.sh na svih 5 cvorova
#
# Na kraju se originalni configi VRACAJU na sve cvorove.
#
# OVA SKRIPTA NE RADI ICMP FLOOD I NE BLOKIRA NIKOGA.
# ============================================================

if ($StartMask -gt $EndMask) {
    throw 'StartMask mora biti <= EndMask.'
}

$SshUser = 'user'

$ServerIp  = '192.168.56.101'
$Agent01Ip = '192.168.56.102'
$Agent02Ip = '192.168.56.103'
$Agent03Ip = '192.168.56.104'
$NidsIp    = '192.168.56.106'

$ServerDir = '/home/user/diplomski/server'
$NidsDir   = '/home/user/diplomski/nids'
$AgentDir  = '/home/user/diplomski/agent'

$ServerConfig = "$ServerDir/server.conf"
$NidsConfig   = "$NidsDir/nids.conf"
$AgentConfig  = "$AgentDir/agent.conf"

$ServerLog = "$ServerDir/log/promet.log"
$NidsLog   = "$NidsDir/log/nids.log"
$AgentLog  = "$AgentDir/log/agent.log"

$ServerPort = 5000
$NidsPort   = 5001
$AgentPort  = 6000

$resultsDir = Join-Path $PSScriptRoot 'rezultati'
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$workDir = Join-Path $resultsDir ("09-tls-work-{0}" -f $stamp)
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$evidencePath = Join-Path $resultsDir ("09-tls-all-permutations-{0}.txt" -f $stamp)
$csvPath      = Join-Path $resultsDir ("09-tls-all-permutations-{0}.csv" -f $stamp)

$remoteBackupSuffix = ".exp09-$stamp.bak"

$Originals = @{
    SERVER   = Join-Path $workDir 'server-original.conf'
    NIDS     = Join-Path $workDir 'nids-original.conf'
    AGENT01  = Join-Path $workDir 'agent01-original.conf'
    AGENT02  = Join-Path $workDir 'agent02-original.conf'
    AGENT03  = Join-Path $workDir 'agent03-original.conf'
}

$evidence = [System.Collections.Generic.List[string]]::new()
$rows = [System.Collections.Generic.List[object]]::new()

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Text
    )

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Invoke-SshText {
    param(
        [string]$Ip,
        [string]$Command,
        [switch]$AllowFailure
    )

    $old = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'

    $out = @()
    $code = 255

    try {
        $out = @(
            & ssh.exe `
                -o BatchMode=yes `
                -o ConnectTimeout=6 `
                -o ConnectionAttempts=1 `
                "$SshUser@$Ip" `
                $Command 2>&1
        )
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
    }

    if ($code -ne 0 -and -not $AllowFailure) {
        $detail = ($out | Select-Object -Last 20) -join "`n"

        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = '(bez detalja)'
        }

        throw "SSH greska $Ip exit=$code`n$detail"
    }

    return @($out)
}

function Invoke-ScpDownload {
    param(
        [string]$Ip,
        [string]$RemotePath,
        [string]$LocalPath
    )

    $old = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'

    try {
        & scp.exe `
            -q `
            -o BatchMode=yes `
            -o ConnectTimeout=6 `
            "${SshUser}@${Ip}:$RemotePath" `
            $LocalPath

        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
    }

    if ($code -ne 0) {
        throw "SCP download nije uspio: ${Ip}:$RemotePath"
    }
}

function Invoke-ScpUpload {
    param(
        [string]$Ip,
        [string]$LocalPath,
        [string]$RemotePath
    )

    $old = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'

    try {
        & scp.exe `
            -q `
            -o BatchMode=yes `
            -o ConnectTimeout=6 `
            $LocalPath `
            "${SshUser}@${Ip}:$RemotePath"

        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
    }

    if ($code -ne 0) {
        throw "SCP upload nije uspio: $LocalPath -> ${Ip}:$RemotePath"
    }
}

function Add-Evidence {
    param([string]$Text = '')

    $evidence.Add($Text)
    $evidence | Set-Content -Path $evidencePath -Encoding UTF8
}

function Add-EvidenceLines {
    param([object[]]$Lines)

    foreach ($line in $Lines) {
        $evidence.Add([string]$line)
    }

    $evidence | Set-Content -Path $evidencePath -Encoding UTF8
}

function Invoke-CleanNode {
    param(
        [string]$Name,
        [string]$Ip,
        [string]$Dir
    )

    Write-Host ("[CLEAN] {0}" -f $Name) -ForegroundColor DarkYellow

    $out = Invoke-SshText `
        -Ip $Ip `
        -Command "cd '$Dir' && sudo -n bash ./clean.sh" `
        -AllowFailure

    if (($out -join "`n") -notmatch 'Gotovo') {
        Write-Host '  clean.sh nije vratio standardni marker Gotovo.' -ForegroundColor DarkGray
    }
}

function Invoke-CleanAll {
    Invoke-CleanNode -Name 'SERVER'   -Ip $ServerIp  -Dir $ServerDir
    Invoke-CleanNode -Name 'NIDS'     -Ip $NidsIp    -Dir $NidsDir
    Invoke-CleanNode -Name 'AGENT-01' -Ip $Agent01Ip -Dir $AgentDir
    Invoke-CleanNode -Name 'AGENT-02' -Ip $Agent02Ip -Dir $AgentDir
    Invoke-CleanNode -Name 'AGENT-03' -Ip $Agent03Ip -Dir $AgentDir
}

function New-ServerVariant {
    param(
        [string]$Source,
        [string]$Destination,
        [int]$Tls
    )

    $text = [System.IO.File]::ReadAllText($Source)

    $rx = [regex]'(?m)^(\s*tls_enable\s*:\s*)[01](\s*(?:#.*)?)$'
    $matches = $rx.Matches($text)

    if ($matches.Count -ne 1) {
        throw "SERVER config: ocekivana tocno 1 tls_enable linija, pronadeno $($matches.Count)."
    }

    $newText = $rx.Replace(
        $text,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($m)
            return $m.Groups[1].Value + $Tls + $m.Groups[2].Value
        },
        1
    )

    Write-Utf8NoBom -Path $Destination -Text $newText
}

function New-NidsVariant {
    param(
        [string]$Source,
        [string]$Destination,
        [int]$Tls
    )

    $text = [System.IO.File]::ReadAllText($Source)

    $rx = [regex]'(?m)^(\s*TLS_ENABLE\s*=\s*)[01](\s*(?:#.*)?)$'
    $matches = $rx.Matches($text)

    if ($matches.Count -ne 1) {
        throw "NIDS config: ocekivana tocno 1 TLS_ENABLE linija, pronadeno $($matches.Count)."
    }

    $newText = $rx.Replace(
        $text,
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($m)
            return $m.Groups[1].Value + $Tls + $m.Groups[2].Value
        },
        1
    )

    Write-Utf8NoBom -Path $Destination -Text $newText
}

function New-AgentVariant {
    param(
        [string]$Source,
        [string]$Destination,
        [int]$Tls
    )

    $lines = [System.IO.File]::ReadAllLines($Source)
    $tlsIndex = -1
    $tlsIndent = -1
    $enableIndex = -1

    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match '^(\s*)tls\s*:\s*(?:#.*)?$') {
            $tlsIndex = $i
            $tlsIndent = $Matches[1].Length
            break
        }
    }

    if ($tlsIndex -lt 0) {
        throw "AGENT config: tls: blok nije pronaden u $Source"
    }

    for ($i = $tlsIndex + 1; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $leading = ([regex]::Match($line, '^\s*')).Value.Length

        if ($leading -le $tlsIndent) {
            break
        }

        if ($line -match '^(\s*)enable\s*:\s*[01](\s*(?:#.*)?)$') {
            $enableIndex = $i
            $prefix = $Matches[1]
            $suffix = $Matches[2]
            $lines[$i] = "${prefix}enable: $Tls$suffix"
            break
        }
    }

    if ($enableIndex -lt 0) {
        throw "AGENT config: tls.enable nije pronaden u $Source"
    }

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Destination, $lines, $enc)
}

function Get-RemoteTlsValue {
    param(
        [ValidateSet('SERVER','NIDS','AGENT')]
        [string]$Type,
        [string]$Ip
    )

    switch ($Type) {
        'SERVER' {
            $cmd = "grep -E '^[[:space:]]*tls_enable[[:space:]]*:' '$ServerConfig' | tail -n 1"
        }

        'NIDS' {
            $cmd = "grep -E '^[[:space:]]*TLS_ENABLE[[:space:]]*=' '$NidsConfig' | tail -n 1"
        }

        'AGENT' {
            $cmd = "awk '/^[[:space:]]*tls:[[:space:]]*$/ {in_tls=1; next} in_tls && /^[[:space:]]+enable:[[:space:]]*[01]/ {print; exit} in_tls && /^[^[:space:]]/ {exit}' '$AgentConfig'"
        }
    }

    $line = Invoke-SshText -Ip $Ip -Command $cmd -AllowFailure | Select-Object -Last 1

    if (-not $line) {
        return $null
    }

    if ($line -match '([01])') {
        return [int]$Matches[1]
    }

    return $null
}

function Start-Component {
    param(
        [string]$Name,
        [string]$Ip,
        [string]$Command
    )

    Write-Host ("[START] {0}" -f $Name) -ForegroundColor Yellow

    $out = Invoke-SshText -Ip $Ip -Command $Command -AllowFailure
    $ok = (($out -join "`n") -match 'COMPONENT_OK')

    if ($ok) {
        Write-Host '  COMPONENT_OK' -ForegroundColor Green
    }
    else {
        Write-Host '  COMPONENT_FAIL' -ForegroundColor Red
    }

    return [pscustomobject]@{
        Ok = $ok
        Output = ($out -join "`n")
    }
}

function Invoke-ProtocolProbe {
    param(
        [string]$SourceName,
        [string]$SourceIp,
        [string]$SourceDir,
        [int]$SourceTls,
        [string]$TargetHost,
        [int]$TargetPort,
        [string]$Label
    )

    $safeLabel = ($Label -replace '[^A-Za-z0-9_-]','_')
    $tmp = "/tmp/exp09-probe-$safeLabel.log"

    if ($SourceTls -eq 1) {
        $client = "ncat --send-only --wait 2s --ssl --ssl-verify --ssl-trustfile './ssl/ca-cert.pem' '$TargetHost' $TargetPort"
    }
    else {
        $client = "ncat --send-only --wait 2s '$TargetHost' $TargetPort"
    }

    $cmd = "cd '$SourceDir'; rm -f '$tmp'; printf 'TLS_PROBE $safeLabel\n' | $client >'$tmp' 2>&1; rc=`$?; echo PROBE_LABEL=$safeLabel; echo SOURCE=$SourceName; echo SOURCE_TLS=$SourceTls; echo TARGET=$TargetHost`:$TargetPort; echo RC=`$rc; if [ -s '$tmp' ]; then echo OUTPUT_BEGIN; cat '$tmp'; echo OUTPUT_END; fi; exit 0"

    $out = Invoke-SshText -Ip $SourceIp -Command $cmd -AllowFailure

    $rc = $null

    foreach ($line in $out) {
        if ($line -match '^RC=(\d+)$') {
            $rc = [int]$Matches[1]
        }
    }

    return [pscustomobject]@{
        Label = $Label
        Rc = $rc
        Output = ($out -join "`n")
    }
}

function Get-LogSnapshot {
    param(
        [string]$Ip,
        [string]$Path,
        [int]$Lines = 160
    )

    return @(
        Invoke-SshText `
            -Ip $Ip `
            -Command "tail -n $Lines '$Path' 2>/dev/null || true" `
            -AllowFailure
    )
}

function Test-LogContains {
    param(
        [string]$Ip,
        [string]$Path,
        [string]$Regex
    )

    $cmd = "grep -E '$Regex' '$Path' 2>/dev/null | tail -n 1 || true"
    $hit = Invoke-SshText -Ip $Ip -Command $cmd -AllowFailure | Select-Object -Last 1

    return -not [string]::IsNullOrWhiteSpace([string]$hit)
}

function Save-OriginalConfigs {
    Write-Host ''
    Write-Host '[BACKUP] Preuzimam originalne confige...' -ForegroundColor Cyan

    Invoke-ScpDownload -Ip $ServerIp  -RemotePath $ServerConfig -LocalPath $Originals.SERVER
    Invoke-ScpDownload -Ip $NidsIp    -RemotePath $NidsConfig   -LocalPath $Originals.NIDS
    Invoke-ScpDownload -Ip $Agent01Ip -RemotePath $AgentConfig  -LocalPath $Originals.AGENT01
    Invoke-ScpDownload -Ip $Agent02Ip -RemotePath $AgentConfig  -LocalPath $Originals.AGENT02
    Invoke-ScpDownload -Ip $Agent03Ip -RemotePath $AgentConfig  -LocalPath $Originals.AGENT03

    # I remote backup, cisto da eksperiment ne glumi ruski rulet s configima.
    Invoke-SshText -Ip $ServerIp  -Command "cp '$ServerConfig' '$ServerConfig$remoteBackupSuffix'" | Out-Null
    Invoke-SshText -Ip $NidsIp    -Command "cp '$NidsConfig' '$NidsConfig$remoteBackupSuffix'" | Out-Null
    Invoke-SshText -Ip $Agent01Ip -Command "cp '$AgentConfig' '$AgentConfig$remoteBackupSuffix'" | Out-Null
    Invoke-SshText -Ip $Agent02Ip -Command "cp '$AgentConfig' '$AgentConfig$remoteBackupSuffix'" | Out-Null
    Invoke-SshText -Ip $Agent03Ip -Command "cp '$AgentConfig' '$AgentConfig$remoteBackupSuffix'" | Out-Null
}

function Restore-OriginalConfigs {
    Write-Host ''
    Write-Host '[RESTORE] Vracam originalne confige...' -ForegroundColor Cyan

    $restoreErrors = @()

    $restoreList = @(
        @('SERVER',   $ServerIp,  $Originals.SERVER,  $ServerConfig),
        @('NIDS',     $NidsIp,    $Originals.NIDS,    $NidsConfig),
        @('AGENT-01', $Agent01Ip, $Originals.AGENT01, $AgentConfig),
        @('AGENT-02', $Agent02Ip, $Originals.AGENT02, $AgentConfig),
        @('AGENT-03', $Agent03Ip, $Originals.AGENT03, $AgentConfig)
    )

    foreach ($r in $restoreList) {
        try {
            Invoke-ScpUpload -Ip $r[1] -LocalPath $r[2] -RemotePath $r[3]
            Write-Host ("  {0} original vracen." -f $r[0]) -ForegroundColor Green
        }
        catch {
            $restoreErrors += $r[0]
            Write-Host ("  {0} local restore nije uspio, koristim remote backup." -f $r[0]) -ForegroundColor Yellow

            Invoke-SshText `
                -Ip $r[1] `
                -Command "test -f '$($r[3])$remoteBackupSuffix' && cp '$($r[3])$remoteBackupSuffix' '$($r[3])'" `
                -AllowFailure |
                Out-Null
        }
    }

    foreach ($r in @(
        @($ServerIp,$ServerConfig),
        @($NidsIp,$NidsConfig),
        @($Agent01Ip,$AgentConfig),
        @($Agent02Ip,$AgentConfig),
        @($Agent03Ip,$AgentConfig)
    )) {
        Invoke-SshText `
            -Ip $r[0] `
            -Command "rm -f '$($r[1])$remoteBackupSuffix'" `
            -AllowFailure |
            Out-Null
    }

    return $restoreErrors
}

function Get-Permutations {
    $list = [System.Collections.Generic.List[object]]::new()

    if ($PermutationMode -eq 'AllNodes') {
        for ($mask = $StartMask; $mask -le $EndMask; $mask++) {
            $server = if (($mask -band 16) -ne 0) { 1 } else { 0 }
            $nids   = if (($mask -band 8)  -ne 0) { 1 } else { 0 }
            $a1     = if (($mask -band 4)  -ne 0) { 1 } else { 0 }
            $a2     = if (($mask -band 2)  -ne 0) { 1 } else { 0 }
            $a3     = if (($mask -band 1)  -ne 0) { 1 } else { 0 }

            $list.Add([pscustomobject]@{
                Id = ("P{0:D2}" -f $mask)
                Mask = $mask
                Server = $server
                Nids = $nids
                Agent01 = $a1
                Agent02 = $a2
                Agent03 = $a3
            })
        }
    }
    else {
        # 3 bita: SERVER / NIDS / AGENTS
        for ($roleMask = 0; $roleMask -le 7; $roleMask++) {
            $server = if (($roleMask -band 4) -ne 0) { 1 } else { 0 }
            $nids   = if (($roleMask -band 2) -ne 0) { 1 } else { 0 }
            $agents = if (($roleMask -band 1) -ne 0) { 1 } else { 0 }

            $list.Add([pscustomobject]@{
                Id = ("R{0:D2}" -f $roleMask)
                Mask = $roleMask
                Server = $server
                Nids = $nids
                Agent01 = $agents
                Agent02 = $agents
                Agent03 = $agents
            })
        }
    }

    return $list.ToArray()
}

# ============================================================
# PREFLIGHT
# ============================================================

Add-Evidence '============================================================'
Add-Evidence 'EKSPERIMENT 09 - TLS PERMUTACIJE'
Add-Evidence '============================================================'
Add-Evidence ("started={0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Evidence ("mode={0}" -f $PermutationMode)
Add-Evidence ("observation_seconds={0}" -f $ObservationSeconds)
Add-Evidence ''

$allNodes = @(
    @('SERVER',$ServerIp),
    @('NIDS',$NidsIp),
    @('AGENT-01',$Agent01Ip),
    @('AGENT-02',$Agent02Ip),
    @('AGENT-03',$Agent03Ip)
)

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ' EKSPERIMENT 09 - TLS PERMUTACIJE' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

if ($PermutationMode -eq 'AllNodes') {
    Write-Host ' MODE: svih 5 cvorova neovisno -> do 32 permutacije' -ForegroundColor White
}
else {
    Write-Host ' MODE: SERVER/NIDS/AGENTS -> 8 permutacija' -ForegroundColor White
}

Write-Host ' NEMA ICMP FLOODA. NEMA BLOCK testa.' -ForegroundColor Green
Write-Host '==================================================' -ForegroundColor Cyan

$originalsSaved = $false
$fatal = $null

try {
    Write-Host ''
    Write-Host '[PREFLIGHT] SSH...' -ForegroundColor Cyan

    foreach ($node in $allNodes) {
        $probe = Invoke-SshText -Ip $node[1] -Command 'echo SSH_OK' -AllowFailure | Select-Object -First 1

        if ($probe -ne 'SSH_OK') {
            throw "SSH nije dostupan: $($node[0])"
        }

        Write-Host ("  {0} OK" -f $node[0]) -ForegroundColor DarkGray
    }

    Save-OriginalConfigs
    $originalsSaved = $true

    $permutations = @(Get-Permutations)
    $total = $permutations.Count
    $index = 0

    foreach ($p in $permutations) {
        $index++

        Write-Host ''
        Write-Host '==================================================' -ForegroundColor Magenta
        Write-Host (" {0}/{1}  {2}" -f $index,$total,$p.Id) -ForegroundColor Magenta
        Write-Host (" SERVER={0} NIDS={1} A1={2} A2={3} A3={4}" -f `
            $p.Server,$p.Nids,$p.Agent01,$p.Agent02,$p.Agent03) `
            -ForegroundColor White
        Write-Host '==================================================' -ForegroundColor Magenta

        Add-Evidence ''
        Add-Evidence '============================================================'
        Add-Evidence ("PERMUTATION {0}" -f $p.Id)
        Add-Evidence '============================================================'
        Add-Evidence ("SERVER_TLS={0}" -f $p.Server)
        Add-Evidence ("NIDS_TLS={0}" -f $p.Nids)
        Add-Evidence ("AGENT01_TLS={0}" -f $p.Agent01)
        Add-Evidence ("AGENT02_TLS={0}" -f $p.Agent02)
        Add-Evidence ("AGENT03_TLS={0}" -f $p.Agent03)

        $permError = $null

        $startServer = $false
        $startNids = $false
        $startA1 = $false
        $startA2 = $false
        $startA3 = $false

        $hbA1 = $false
        $hbA2 = $false
        $hbA3 = $false

        $probeA1Server = $null
        $probeA2Server = $null
        $probeA3Server = $null
        $probeServerA1 = $null
        $probeA2A1 = $null
        $probeA3A1 = $null
        $probeNidsServer = $null
        $probeServerNids = $null

        try {
            # ------------------------------------------------
            # 1) CLEAN
            # ------------------------------------------------

            Write-Host '[1] clean.sh na svih 5 cvorova' -ForegroundColor Cyan
            Invoke-CleanAll

            # ------------------------------------------------
            # 2) NAPRAVI POTPUNE CONFIG VARIJANTE
            # ------------------------------------------------

            Write-Host '[2] Generiram pune config datoteke za ovu permutaciju' -ForegroundColor Cyan

            $serverVariant = Join-Path $workDir ("{0}-server.conf" -f $p.Id)
            $nidsVariant   = Join-Path $workDir ("{0}-nids.conf" -f $p.Id)
            $a1Variant     = Join-Path $workDir ("{0}-agent01.conf" -f $p.Id)
            $a2Variant     = Join-Path $workDir ("{0}-agent02.conf" -f $p.Id)
            $a3Variant     = Join-Path $workDir ("{0}-agent03.conf" -f $p.Id)

            New-ServerVariant -Source $Originals.SERVER  -Destination $serverVariant -Tls $p.Server
            New-NidsVariant   -Source $Originals.NIDS    -Destination $nidsVariant   -Tls $p.Nids
            New-AgentVariant  -Source $Originals.AGENT01 -Destination $a1Variant     -Tls $p.Agent01
            New-AgentVariant  -Source $Originals.AGENT02 -Destination $a2Variant     -Tls $p.Agent02
            New-AgentVariant  -Source $Originals.AGENT03 -Destination $a3Variant     -Tls $p.Agent03

            # ------------------------------------------------
            # 3) UPLOAD
            # ------------------------------------------------

            Write-Host '[3] Upload configa na cvorove' -ForegroundColor Cyan

            Invoke-ScpUpload -Ip $ServerIp  -LocalPath $serverVariant -RemotePath $ServerConfig
            Invoke-ScpUpload -Ip $NidsIp    -LocalPath $nidsVariant   -RemotePath $NidsConfig
            Invoke-ScpUpload -Ip $Agent01Ip -LocalPath $a1Variant     -RemotePath $AgentConfig
            Invoke-ScpUpload -Ip $Agent02Ip -LocalPath $a2Variant     -RemotePath $AgentConfig
            Invoke-ScpUpload -Ip $Agent03Ip -LocalPath $a3Variant     -RemotePath $AgentConfig

            # ------------------------------------------------
            # 4) VERIFY CONFIG
            # ------------------------------------------------

            Write-Host '[4] Provjera uploadanih TLS vrijednosti' -ForegroundColor Cyan

            $actualServer = Get-RemoteTlsValue -Type SERVER -Ip $ServerIp
            $actualNids   = Get-RemoteTlsValue -Type NIDS   -Ip $NidsIp
            $actualA1     = Get-RemoteTlsValue -Type AGENT  -Ip $Agent01Ip
            $actualA2     = Get-RemoteTlsValue -Type AGENT  -Ip $Agent02Ip
            $actualA3     = Get-RemoteTlsValue -Type AGENT  -Ip $Agent03Ip

            $configOk = (
                $actualServer -eq $p.Server -and
                $actualNids   -eq $p.Nids -and
                $actualA1     -eq $p.Agent01 -and
                $actualA2     -eq $p.Agent02 -and
                $actualA3     -eq $p.Agent03
            )

            Add-Evidence ("CONFIG_VERIFY server={0} nids={1} a1={2} a2={3} a3={4} ok={5}" -f `
                $actualServer,$actualNids,$actualA1,$actualA2,$actualA3,$configOk)

            if (-not $configOk) {
                throw 'Uploadani config ne odgovara trazenoj TLS permutaciji.'
            }

            # ------------------------------------------------
            # 5) START
            # ------------------------------------------------

            Write-Host '[5] Pokretanje procesa' -ForegroundColor Cyan

            $serverCmd = "cd '$ServerDir'; nohup bash ./server.sh >/tmp/exp09-server-start.log 2>&1 </dev/null & sleep 2; if pgrep -f '[s]erver.sh' >/dev/null; then echo COMPONENT_OK; else echo COMPONENT_FAIL; fi; tail -n 20 /tmp/exp09-server-start.log 2>/dev/null || true"

            $nidsCmd = "cd '$NidsDir'; nohup sudo -n bash ./nids.sh >/tmp/exp09-nids-start.log 2>&1 </dev/null & sleep 3; if sudo -n pgrep -f '[n]ids.sh' >/dev/null && sudo -n pgrep -f '[c]ontrol.sh' >/dev/null; then echo COMPONENT_OK; else echo COMPONENT_FAIL; fi; tail -n 30 /tmp/exp09-nids-start.log 2>/dev/null || true"

            $agentCmd = "cd '$AgentDir'; nohup sudo -n bash ./agent.sh >/tmp/exp09-agent-start.log 2>&1 </dev/null & sleep 3; if sudo -n pgrep -f '[a]gent.sh' >/dev/null; then echo COMPONENT_OK; else echo COMPONENT_FAIL; fi; tail -n 25 /tmp/exp09-agent-start.log 2>/dev/null || true"

            $s = Start-Component -Name 'SERVER'   -Ip $ServerIp  -Command $serverCmd
            $n = Start-Component -Name 'NIDS'     -Ip $NidsIp    -Command $nidsCmd
            $a = Start-Component -Name 'AGENT-01' -Ip $Agent01Ip -Command $agentCmd
            $b = Start-Component -Name 'AGENT-02' -Ip $Agent02Ip -Command $agentCmd
            $c = Start-Component -Name 'AGENT-03' -Ip $Agent03Ip -Command $agentCmd

            $startServer = $s.Ok
            $startNids = $n.Ok
            $startA1 = $a.Ok
            $startA2 = $b.Ok
            $startA3 = $c.Ok

            Add-Evidence '[START OUTPUT - SERVER]'
            Add-EvidenceLines @($s.Output)
            Add-Evidence '[START OUTPUT - NIDS]'
            Add-EvidenceLines @($n.Output)
            Add-Evidence '[START OUTPUT - AGENT-01]'
            Add-EvidenceLines @($a.Output)
            Add-Evidence '[START OUTPUT - AGENT-02]'
            Add-EvidenceLines @($b.Output)
            Add-Evidence '[START OUTPUT - AGENT-03]'
            Add-EvidenceLines @($c.Output)

            # ------------------------------------------------
            # 6) KRATKI RUNTIME
            # ------------------------------------------------

            Write-Host ("[6] Runtime {0}s" -f $ObservationSeconds) -ForegroundColor Cyan
            Start-Sleep -Seconds $ObservationSeconds

            # ------------------------------------------------
            # 7) BENIGNI PROBEOVI - NEMA NAPADA
            # ------------------------------------------------

            Write-Host '[7] Benigni komunikacijski probeovi' -ForegroundColor Cyan

            $probeA1Server = Invoke-ProtocolProbe `
                -SourceName 'AGENT-01' -SourceIp $Agent01Ip -SourceDir $AgentDir `
                -SourceTls $p.Agent01 -TargetHost 'server' -TargetPort $ServerPort `
                -Label "$($p.Id)-a1-to-server"

            $probeA2Server = Invoke-ProtocolProbe `
                -SourceName 'AGENT-02' -SourceIp $Agent02Ip -SourceDir $AgentDir `
                -SourceTls $p.Agent02 -TargetHost 'server' -TargetPort $ServerPort `
                -Label "$($p.Id)-a2-to-server"

            $probeA3Server = Invoke-ProtocolProbe `
                -SourceName 'AGENT-03' -SourceIp $Agent03Ip -SourceDir $AgentDir `
                -SourceTls $p.Agent03 -TargetHost 'server' -TargetPort $ServerPort `
                -Label "$($p.Id)-a3-to-server"

            $probeServerA1 = Invoke-ProtocolProbe `
                -SourceName 'SERVER' -SourceIp $ServerIp -SourceDir $ServerDir `
                -SourceTls $p.Server -TargetHost 'agent-01' -TargetPort $AgentPort `
                -Label "$($p.Id)-server-to-a1"

            $probeA2A1 = Invoke-ProtocolProbe `
                -SourceName 'AGENT-02' -SourceIp $Agent02Ip -SourceDir $AgentDir `
                -SourceTls $p.Agent02 -TargetHost 'agent-01' -TargetPort $AgentPort `
                -Label "$($p.Id)-a2-to-a1"

            $probeA3A1 = Invoke-ProtocolProbe `
                -SourceName 'AGENT-03' -SourceIp $Agent03Ip -SourceDir $AgentDir `
                -SourceTls $p.Agent03 -TargetHost 'agent-01' -TargetPort $AgentPort `
                -Label "$($p.Id)-a3-to-a1"

            $probeNidsServer = Invoke-ProtocolProbe `
                -SourceName 'NIDS' -SourceIp $NidsIp -SourceDir $NidsDir `
                -SourceTls $p.Nids -TargetHost 'server' -TargetPort $ServerPort `
                -Label "$($p.Id)-nids-to-server"

            $probeServerNids = Invoke-ProtocolProbe `
                -SourceName 'SERVER' -SourceIp $ServerIp -SourceDir $ServerDir `
                -SourceTls $p.Server -TargetHost 'nids' -TargetPort $NidsPort `
                -Label "$($p.Id)-server-to-nids"

            foreach ($pr in @(
                $probeA1Server,$probeA2Server,$probeA3Server,$probeServerA1,
                $probeA2A1,$probeA3A1,$probeNidsServer,$probeServerNids
            )) {
                Add-Evidence ("[PROBE {0}]" -f $pr.Label)
                Add-EvidenceLines @($pr.Output)
            }

            Start-Sleep -Seconds 2

            # ------------------------------------------------
            # 8) LOGOVI SVIH CVOROVA
            # ------------------------------------------------

            Write-Host '[8] Spremam ispise svih cvorova' -ForegroundColor Cyan

            $serverLines = @(Get-LogSnapshot -Ip $ServerIp -Path $ServerLog -Lines 220)
            $nidsLines   = @(Get-LogSnapshot -Ip $NidsIp -Path $NidsLog -Lines 180)
            $a1Lines     = @(Get-LogSnapshot -Ip $Agent01Ip -Path $AgentLog -Lines 180)
            $a2Lines     = @(Get-LogSnapshot -Ip $Agent02Ip -Path $AgentLog -Lines 180)
            $a3Lines     = @(Get-LogSnapshot -Ip $Agent03Ip -Path $AgentLog -Lines 180)

            Add-Evidence '[NODE OUTPUT - SERVER]'
            Add-EvidenceLines $serverLines
            Add-Evidence '[NODE OUTPUT - NIDS]'
            Add-EvidenceLines $nidsLines
            Add-Evidence '[NODE OUTPUT - AGENT-01]'
            Add-EvidenceLines $a1Lines
            Add-Evidence '[NODE OUTPUT - AGENT-02]'
            Add-EvidenceLines $a2Lines
            Add-Evidence '[NODE OUTPUT - AGENT-03]'
            Add-EvidenceLines $a3Lines

            $hbA1 = (($serverLines -join "`n") -match '\[HEARTBEAT\] HEARTBEAT agent-01( |$)')
            $hbA2 = (($serverLines -join "`n") -match '\[HEARTBEAT\] HEARTBEAT agent-02( |$)')
            $hbA3 = (($serverLines -join "`n") -match '\[HEARTBEAT\] HEARTBEAT agent-03( |$)')

            $serverTlsMatchA1 = ($p.Server -eq $p.Agent01)
            $serverTlsMatchA2 = ($p.Server -eq $p.Agent02)
            $serverTlsMatchA3 = ($p.Server -eq $p.Agent03)
            $serverTlsMatchNids = ($p.Server -eq $p.Nids)
            $peerA2A1Match = ($p.Agent02 -eq $p.Agent01)
            $peerA3A1Match = ($p.Agent03 -eq $p.Agent01)

            Add-Evidence '[SUMMARY]'
            Add-Evidence ("heartbeat_a1_seen={0} expected_pair_match={1}" -f $hbA1,$serverTlsMatchA1)
            Add-Evidence ("heartbeat_a2_seen={0} expected_pair_match={1}" -f $hbA2,$serverTlsMatchA2)
            Add-Evidence ("heartbeat_a3_seen={0} expected_pair_match={1}" -f $hbA3,$serverTlsMatchA3)
            Add-Evidence ("probe_a1_server_rc={0}" -f $probeA1Server.Rc)
            Add-Evidence ("probe_a2_server_rc={0}" -f $probeA2Server.Rc)
            Add-Evidence ("probe_a3_server_rc={0}" -f $probeA3Server.Rc)
            Add-Evidence ("probe_server_a1_rc={0}" -f $probeServerA1.Rc)
            Add-Evidence ("probe_a2_a1_rc={0}" -f $probeA2A1.Rc)
            Add-Evidence ("probe_a3_a1_rc={0}" -f $probeA3A1.Rc)
            Add-Evidence ("probe_nids_server_rc={0}" -f $probeNidsServer.Rc)
            Add-Evidence ("probe_server_nids_rc={0}" -f $probeServerNids.Rc)

            $rows.Add([pscustomobject]@{
                permutation = $p.Id
                mask = $p.Mask

                server_tls = $p.Server
                nids_tls = $p.Nids
                agent01_tls = $p.Agent01
                agent02_tls = $p.Agent02
                agent03_tls = $p.Agent03

                server_started = $startServer
                nids_started = $startNids
                agent01_started = $startA1
                agent02_started = $startA2
                agent03_started = $startA3

                heartbeat_agent01_seen = $hbA1
                heartbeat_agent02_seen = $hbA2
                heartbeat_agent03_seen = $hbA3

                expected_server_agent01_match = $serverTlsMatchA1
                expected_server_agent02_match = $serverTlsMatchA2
                expected_server_agent03_match = $serverTlsMatchA3
                expected_server_nids_match = $serverTlsMatchNids
                expected_agent02_agent01_match = $peerA2A1Match
                expected_agent03_agent01_match = $peerA3A1Match

                probe_agent01_to_server_rc = $probeA1Server.Rc
                probe_agent02_to_server_rc = $probeA2Server.Rc
                probe_agent03_to_server_rc = $probeA3Server.Rc
                probe_server_to_agent01_rc = $probeServerA1.Rc
                probe_agent02_to_agent01_rc = $probeA2A1.Rc
                probe_agent03_to_agent01_rc = $probeA3A1.Rc
                probe_nids_to_server_rc = $probeNidsServer.Rc
                probe_server_to_nids_rc = $probeServerNids.Rc

                permutation_error = ''
            })

            Write-Host ("  HEARTBEAT A1={0} A2={1} A3={2}" -f $hbA1,$hbA2,$hbA3) -ForegroundColor White
        }
        catch {
            $permError = $_.Exception.Message

            Write-Host ("[PERMUTATION ERROR] {0}" -f $permError) -ForegroundColor Red
            Add-Evidence '[PERMUTATION ERROR]'
            Add-Evidence $permError

            $rows.Add([pscustomobject]@{
                permutation = $p.Id
                mask = $p.Mask

                server_tls = $p.Server
                nids_tls = $p.Nids
                agent01_tls = $p.Agent01
                agent02_tls = $p.Agent02
                agent03_tls = $p.Agent03

                server_started = $startServer
                nids_started = $startNids
                agent01_started = $startA1
                agent02_started = $startA2
                agent03_started = $startA3

                heartbeat_agent01_seen = $hbA1
                heartbeat_agent02_seen = $hbA2
                heartbeat_agent03_seen = $hbA3

                expected_server_agent01_match = ($p.Server -eq $p.Agent01)
                expected_server_agent02_match = ($p.Server -eq $p.Agent02)
                expected_server_agent03_match = ($p.Server -eq $p.Agent03)
                expected_server_nids_match = ($p.Server -eq $p.Nids)
                expected_agent02_agent01_match = ($p.Agent02 -eq $p.Agent01)
                expected_agent03_agent01_match = ($p.Agent03 -eq $p.Agent01)

                probe_agent01_to_server_rc = $(if ($probeA1Server) { $probeA1Server.Rc } else { $null })
                probe_agent02_to_server_rc = $(if ($probeA2Server) { $probeA2Server.Rc } else { $null })
                probe_agent03_to_server_rc = $(if ($probeA3Server) { $probeA3Server.Rc } else { $null })
                probe_server_to_agent01_rc = $(if ($probeServerA1) { $probeServerA1.Rc } else { $null })
                probe_agent02_to_agent01_rc = $(if ($probeA2A1) { $probeA2A1.Rc } else { $null })
                probe_agent03_to_agent01_rc = $(if ($probeA3A1) { $probeA3A1.Rc } else { $null })
                probe_nids_to_server_rc = $(if ($probeNidsServer) { $probeNidsServer.Rc } else { $null })
                probe_server_to_nids_rc = $(if ($probeServerNids) { $probeServerNids.Rc } else { $null })

                permutation_error = $permError
            })
        }
        finally {
            Write-Host '[9] clean.sh nakon permutacije' -ForegroundColor Cyan

            try {
                Invoke-CleanAll
            }
            catch {
                Write-Host ("  Cleanup warning: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }

            if ($rows.Count -gt 0) {
                $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
            }
        }
    }
}
catch {
    $fatal = $_.Exception.Message

    Write-Host ''
    Write-Host ("[FATAL] {0}" -f $fatal) -ForegroundColor Red

    Add-Evidence ''
    Add-Evidence '[FATAL]'
    Add-Evidence $fatal
}
finally {
    Write-Host ''
    Write-Host '==================================================' -ForegroundColor Cyan
    Write-Host ' ZAVRSNI CLEAN + RESTORE ORIGINALNIH CONFIGA' -ForegroundColor Cyan
    Write-Host '==================================================' -ForegroundColor Cyan

    try {
        Invoke-CleanAll
    }
    catch {
        Write-Host ("[FINAL CLEAN WARNING] {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

    if ($originalsSaved) {
        try {
            $restoreErrors = @(Restore-OriginalConfigs)

            if ($restoreErrors.Count -eq 0) {
                Add-Evidence ''
                Add-Evidence 'ORIGINAL_CONFIG_RESTORE=OK'
            }
            else {
                Add-Evidence ''
                Add-Evidence ("ORIGINAL_CONFIG_RESTORE=FALLBACK_USED nodes={0}" -f ($restoreErrors -join ','))
            }
        }
        catch {
            Add-Evidence ''
            Add-Evidence ("ORIGINAL_CONFIG_RESTORE=ERROR {0}" -f $_.Exception.Message)
            Write-Host ("[RESTORE ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    }

    if ($rows.Count -gt 0) {
        $rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    }

    Add-Evidence ("finished={0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

    Write-Host ''
    Write-Host ("[EVIDENCE] {0}" -f $evidencePath) -ForegroundColor Yellow
    Write-Host ("[CSV]      {0}" -f $csvPath) -ForegroundColor Yellow
    Write-Host ("[WORK]     {0}" -f $workDir) -ForegroundColor DarkGray
}

if ($fatal) {
    exit 1
}

exit 0
