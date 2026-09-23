param(
    # Koristi samo ako je VM vec pokrenut iz prethodnog neuspjelog pokusaja
    # i zelis zadrzati tocno vrijeme originalnog paljenja VM-a.
    # Primjer:
    # .\04-recovery.ps1 -VmStartServerTime "2026-09-13 17:26:10.004"
    [string]$VmStartServerTime = ''
)

# DIPLOMSKI - EKSPERIMENT 04: OPORAVAK CVORA
#
# PRETPOSTAVKA:
# - server NIJE restartan nakon NODE_FAILURE
# - agent-01 je prethodno bio u NODE_FAILURE
#
# Skripta:
# 1) pronalazi zadnji NODE_FAILURE
# 2) ako je VM ugasen, pali ga
# 3) ceka SSH do 300 s
# 4) NE ubija agent.sh ako vec radi
# 5) ako agent.sh ne radi, pokusava ga pokrenuti
# 6) ceka prvi novi HEARTBEAT i RECOVERY nakon zadnjeg NODE_FAILURE
# 7) sprema rezultat u 04-recovery.csv

$ErrorActionPreference = 'Stop'

$SshUser   = 'user'
$ServerIp  = '192.168.56.101'
$Agent01Ip = '192.168.56.102'

$ServerLog = '/home/user/diplomski/server/log/promet.log'
$AgentDir  = '/home/user/diplomski/agent'

$Agent01VmName = 'Parrot OS 7.3 KDE Security Edition Agent 01'

# --------------------------------------------------
# Pomocne funkcije
# --------------------------------------------------

function Get-LogTimestamp {
    param([string]$Line)

    if ($Line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\]') {
        return [DateTime]::ParseExact(
            $Matches[1],
            'yyyy-MM-dd HH:mm:ss.fff',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }

    return $null
}

function Get-PlainTimestamp {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    try {
        return [DateTime]::ParseExact(
            $Text.Trim(),
            'yyyy-MM-dd HH:mm:ss.fff',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch {
        return $null
    }
}

# SSH timeout je ovdje OCEKIVAN tijekom bootanja VM-a.
# Zato privremeno gasimo Stop ponasanje i vracamo exit code + output.
function Invoke-SshQuiet {
    param(
        [string]$Target,
        [string]$Command,
        [int]$ConnectTimeout = 4
    )

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'

    try {
        $output = @(
            & ssh.exe `
                -o BatchMode=yes `
                -o ConnectTimeout=$ConnectTimeout `
                -o ConnectionAttempts=1 `
                $Target `
                $Command 2>$null
        )

        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = @()
        $exitCode = 255
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Test-SshReady {
    param([string]$Target)

    $r = Invoke-SshQuiet `
        -Target $Target `
        -Command 'echo READY' `
        -ConnectTimeout 4

    return (
        $r.ExitCode -eq 0 -and
        (($r.Output | Select-Object -First 1) -eq 'READY')
    )
}

# --------------------------------------------------
# VBoxManage
# --------------------------------------------------

$VBoxManage = @(
    (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Oracle\VirtualBox\VBoxManage.exe')
) |
Where-Object { $_ -and (Test-Path $_) } |
Select-Object -First 1

if (-not $VBoxManage) {
    $vboxCmd = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
    if ($vboxCmd) {
        $VBoxManage = $vboxCmd.Source
    }
}

if (-not $VBoxManage) {
    throw 'VBoxManage.exe nije pronaden.'
}

function Get-VmState {
    param([string]$Name)

    $line = & $VBoxManage showvminfo $Name --machinereadable 2>$null |
        Where-Object { $_ -like 'VMState=*' } |
        Select-Object -First 1

    if ($line -match '^VMState="([^"]+)"') {
        return $Matches[1]
    }

    return $null
}

# --------------------------------------------------
# Pocetak
# --------------------------------------------------

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ' EKSPERIMENT 04 - OPORAVAK CVORA' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ''

# --------------------------------------------------
# 1. Server mora ostati isti proces nakon NODE_FAILURE
# --------------------------------------------------

Write-Host '[CHECK] Provjeravam server...' -ForegroundColor Yellow

if (-not (Test-SshReady -Target "$SshUser@$ServerIp")) {
    throw 'Server nije dostupan preko SSH-a.'
}

Write-Host '[OK] Server je dostupan.' -ForegroundColor Green

# --------------------------------------------------
# 2. Pronadi zadnji NODE_FAILURE i njegov broj retka
# --------------------------------------------------

$failureLookup =
    "grep -n -E '\[CORRELATION\].*state=NODE_FAILURE.*host=agent-01' '$ServerLog' | tail -n 1"

$failureResult = Invoke-SshQuiet `
    -Target "$SshUser@$ServerIp" `
    -Command $failureLookup `
    -ConnectTimeout 5

$failureRaw = $failureResult.Output | Select-Object -First 1

if (-not $failureRaw) {
    throw 'U server logu nema NODE_FAILURE za agent-01. Najprije izvedi eksperiment 03.'
}

if ($failureRaw -notmatch '^(\d+):(.*)$') {
    throw 'Ne mogu parsirati zadnji NODE_FAILURE iz server loga.'
}

$failureLineNumber = [int]$Matches[1]
$failureLine = $Matches[2].Trim()
$failureTs = Get-LogTimestamp $failureLine
$searchStartLine = $failureLineNumber + 1

Write-Host ''
Write-Host '[PRETHODNO STANJE]' -ForegroundColor Yellow
Write-Host $failureLine -ForegroundColor White
Write-Host "[LOG] Nove zapise trazim od retka $searchStartLine nadalje." -ForegroundColor DarkGray

# --------------------------------------------------
# 3. Ako se RECOVERY vec dogodio nakon tog NODE_FAILURE,
#    nemoj dirati agent. Samo ga pronadi i obradi.
# --------------------------------------------------

function Get-NewHeartbeatLine {
    $cmd =
        "tail -n +$searchStartLine '$ServerLog' | " +
        "grep -E '\[HEARTBEAT\] HEARTBEAT agent-01( |$)' | head -n 1"

    $r = Invoke-SshQuiet `
        -Target "$SshUser@$ServerIp" `
        -Command $cmd `
        -ConnectTimeout 5

    $line = $r.Output | Select-Object -First 1
    if ($line) { return $line.Trim() }
    return $null
}

function Get-RecoveryLine {
    $cmd =
        "tail -n +$searchStartLine '$ServerLog' | " +
        "grep -E '\[RECOVERY\].*state=HEALTHY.*host=agent-01' | head -n 1"

    $r = Invoke-SshQuiet `
        -Target "$SshUser@$ServerIp" `
        -Command $cmd `
        -ConnectTimeout 5

    $line = $r.Output | Select-Object -First 1
    if ($line) { return $line.Trim() }
    return $null
}

$heartbeatLine = Get-NewHeartbeatLine
$recoveryLine = Get-RecoveryLine

if ($recoveryLine) {
    Write-Host ''
    Write-Host '[INFO] RECOVERY se vec dogodio nakon zadnjeg NODE_FAILURE.' -ForegroundColor Green
    Write-Host 'Ne diram agent.sh ni VM; samo obradujem postojeci rezultat.' -ForegroundColor DarkGray
}

# --------------------------------------------------
# 4. Ako recovery jos nije dosao, pripremi/pokreni VM
# --------------------------------------------------

$vmStartServerText = $VmStartServerTime
$vmStartServerTs = Get-PlainTimestamp $vmStartServerText

if (-not $recoveryLine) {
    $vmState = Get-VmState $Agent01VmName

    Write-Host ''
    Write-Host "[VM] Trenutno stanje: $vmState" -ForegroundColor Yellow

    if ($vmState -ne 'running') {
        $timeResult = Invoke-SshQuiet `
            -Target "$SshUser@$ServerIp" `
            -Command "date '+%Y-%m-%d %H:%M:%S.%3N'" `
            -ConnectTimeout 5

        $vmStartServerText = (
            $timeResult.Output |
            Select-Object -First 1
        ).Trim()

        $vmStartServerTs = Get-PlainTimestamp $vmStartServerText

        Write-Host '[VM] Pokrecem agent-01...' -ForegroundColor Yellow
        Write-Host "[TRIGGER-SERVER-TIME] $vmStartServerText" -ForegroundColor DarkGray

        & $VBoxManage startvm $Agent01VmName --type headless | Out-Host

        if ($LASTEXITCODE -ne 0) {
            throw 'VirtualBox nije uspio pokrenuti agent-01.'
        }
    }
    else {
        Write-Host '[VM] VM je vec running.' -ForegroundColor Green

        if ($vmStartServerTs) {
            Write-Host "[VM] Koristim zadano originalno vrijeme paljenja: $vmStartServerText" -ForegroundColor DarkGray
        }
        else {
            Write-Warning 'VM je vec running, a originalno vrijeme paljenja nije zadano.'
            Write-Warning 'Recovery se moze testirati, ali VM -> recovery metrika nece biti izracunata.'
        }
    }

    # --------------------------------------------------
    # 5. Cekaj SSH do 300 s
    # --------------------------------------------------

    Write-Host ''
    Write-Host '[SSH] Cekam da agent-01 postane dostupan...' -ForegroundColor Yellow
    Write-Host 'Maksimalno cekanje: 300 s.' -ForegroundColor DarkGray

    $sshReady = $false
    $sshStart = Get-Date
    $sshDeadline = $sshStart.AddSeconds(300)
    $attempt = 0

    while ((Get-Date) -lt $sshDeadline) {
        $attempt++

        if (Test-SshReady -Target "$SshUser@$Agent01Ip") {
            $sshReady = $true
            break
        }

        $elapsed = [int]((Get-Date) - $sshStart).TotalSeconds

        Write-Host (
            "  pokusaj {0}: SSH jos nije dostupan ({1} s)" -f
            $attempt,
            $elapsed
        ) -ForegroundColor DarkGray

        Start-Sleep -Seconds 5
    }

    if (-not $sshReady) {
        throw 'SSH na agent-01 nije postao dostupan unutar 300 s.'
    }

    $sshElapsed = ((Get-Date) - $sshStart).TotalSeconds

    Write-Host (
        "[OK] SSH dostupan nakon {0:N1} s ({1} pokusaja)." -f
        $sshElapsed,
        $attempt
    ) -ForegroundColor Green

    # --------------------------------------------------
    # 6. KLJUCNA PROMJENA:
    #    prvo provjeri radi li agent.sh.
    #    NE ubijaj ga ako vec radi.
    # --------------------------------------------------

    Write-Host ''
    Write-Host '[AGENT] Provjeravam agent.sh...' -ForegroundColor Yellow

    $agentCheck = Invoke-SshQuiet `
        -Target "$SshUser@$Agent01Ip" `
        -Command "pgrep -af '[a]gent.sh'" `
        -ConnectTimeout 5

    if ($agentCheck.ExitCode -eq 0 -and $agentCheck.Output.Count -gt 0) {
        Write-Host '[OK] agent.sh vec radi. Ne restartam ga.' -ForegroundColor Green

        foreach ($line in $agentCheck.Output) {
            Write-Host "  $line" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host '[AGENT] agent.sh ne radi. Pokusavam ga pokrenuti...' -ForegroundColor Yellow

        $agentStarted = $false

        for ($agentAttempt = 1; $agentAttempt -le 5; $agentAttempt++) {
            Write-Host (
                "  pokusaj pokretanja {0}/5" -f $agentAttempt
            ) -ForegroundColor DarkGray

            $startCmd = @"
cd '$AgentDir' || exit 1
nohup sudo -n bash ./agent.sh >/tmp/diplomski-recovery-agent.log 2>&1 &
sleep 5
pgrep -af '[a]gent.sh'
"@

            $startResult = Invoke-SshQuiet `
                -Target "$SshUser@$Agent01Ip" `
                -Command $startCmd `
                -ConnectTimeout 5

            if ($startResult.ExitCode -eq 0 -and $startResult.Output.Count -gt 0) {
                $agentStarted = $true
                Write-Host '[OK] agent.sh je pokrenut.' -ForegroundColor Green

                foreach ($line in $startResult.Output) {
                    Write-Host "  $line" -ForegroundColor DarkGray
                }

                break
            }

            Write-Warning "agent.sh jos nije potvrden nakon pokusaja $agentAttempt."
            Start-Sleep -Seconds 8
        }

        if (-not $agentStarted) {
            Write-Host ''
            Write-Host '[STARTUP LOG]' -ForegroundColor Yellow

            $startupLog = Invoke-SshQuiet `
                -Target "$SshUser@$Agent01Ip" `
                -Command "tail -n 80 /tmp/diplomski-recovery-agent.log 2>/dev/null || true" `
                -ConnectTimeout 5

            $startupLog.Output | ForEach-Object {
                Write-Host $_ -ForegroundColor White
            }

            throw 'agent.sh nije potvrden nakon 5 pokusaja.'
        }
    }

    # --------------------------------------------------
    # 7. Cekaj novi HEARTBEAT i RECOVERY
    # --------------------------------------------------

    Write-Host ''
    Write-Host '[WAIT] Cekam HEARTBEAT i RECOVERY...' -ForegroundColor Yellow
    Write-Host 'Maksimalno cekanje: 180 s.' -ForegroundColor DarkGray

    $waitStart = Get-Date
    $deadline = $waitStart.AddSeconds(180)
    $nextStatus = 0

    while ((Get-Date) -lt $deadline) {
        if (-not $heartbeatLine) {
            $heartbeatLine = Get-NewHeartbeatLine

            if ($heartbeatLine) {
                Write-Host '[OK] Novi HEARTBEAT primljen.' -ForegroundColor Green
            }
        }

        if (-not $recoveryLine) {
            $recoveryLine = Get-RecoveryLine
        }

        if ($recoveryLine) {
            break
        }

        $elapsed = [int]((Get-Date) - $waitStart).TotalSeconds

        if ($elapsed -ge $nextStatus) {
            Write-Host (
                "  cekanje recoveryja: {0} s" -f $elapsed
            ) -ForegroundColor DarkGray

            $nextStatus += 10
        }

        Start-Sleep -Seconds 2
    }
}

# --------------------------------------------------
# 8. Rezultat
# --------------------------------------------------

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ' REZULTAT - RECOVERY' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

if (-not $heartbeatLine) {
    $heartbeatLine = Get-NewHeartbeatLine
}

if (-not $recoveryLine) {
    $recoveryLine = Get-RecoveryLine
}

if ($heartbeatLine) {
    Write-Host '[PRVI HEARTBEAT NAKON NODE_FAILURE]' -ForegroundColor Yellow
    Write-Host $heartbeatLine -ForegroundColor White
}
else {
    Write-Warning 'Novi HEARTBEAT nakon NODE_FAILURE nije pronaden.'
}

if ($recoveryLine) {
    Write-Host ''
    Write-Host '[RECOVERY]' -ForegroundColor Yellow
    Write-Host $recoveryLine -ForegroundColor White
}
else {
    Write-Host ''
    Write-Host '[ERROR] RECOVERY nije pronaden.' -ForegroundColor Red

    Write-Host ''
    Write-Host '[ZAPISI NAKON NODE_FAILURE]' -ForegroundColor Yellow

    $debugResult = Invoke-SshQuiet `
        -Target "$SshUser@$ServerIp" `
        -Command "tail -n +$searchStartLine '$ServerLog' | grep -E 'agent-01|RECOVERY|NODE_FAILURE|NODE_STATE_UNCERTAIN' | tail -n 80" `
        -ConnectTimeout 5

    $debugResult.Output | ForEach-Object {
        Write-Host $_ -ForegroundColor White
    }

    exit 1
}

# --------------------------------------------------
# 9. Izracuni
# --------------------------------------------------

$heartbeatTs = Get-LogTimestamp $heartbeatLine
$recoveryTs  = Get-LogTimestamp $recoveryLine

$vmToHeartbeat = $null
$vmToRecovery = $null
$heartbeatToRecovery = $null
$failureToRecovery = $null

if ($vmStartServerTs -and $heartbeatTs) {
    $vmToHeartbeat = ($heartbeatTs - $vmStartServerTs).TotalSeconds
}

if ($vmStartServerTs -and $recoveryTs) {
    $vmToRecovery = ($recoveryTs - $vmStartServerTs).TotalSeconds
}

if ($heartbeatTs -and $recoveryTs) {
    $heartbeatToRecovery = ($recoveryTs - $heartbeatTs).TotalSeconds
}

if ($failureTs -and $recoveryTs) {
    $failureToRecovery = ($recoveryTs - $failureTs).TotalSeconds
}

Write-Host ''

if ($null -ne $vmToHeartbeat) {
    Write-Host (
        "[MJERENJE A] paljenje VM-a -> prvi HEARTBEAT = {0:N3} s" -f
        $vmToHeartbeat
    ) -ForegroundColor Green
}
else {
    Write-Host '[MJERENJE A] nije dostupno jer ne znamo tocno vrijeme paljenja VM-a.' -ForegroundColor DarkGray
}

if ($null -ne $vmToRecovery) {
    Write-Host (
        "[MJERENJE B] paljenje VM-a -> RECOVERY = {0:N3} s" -f
        $vmToRecovery
    ) -ForegroundColor Green
}
else {
    Write-Host '[MJERENJE B] nije dostupno jer ne znamo tocno vrijeme paljenja VM-a.' -ForegroundColor DarkGray
}

if ($null -ne $heartbeatToRecovery) {
    Write-Host (
        "[MJERENJE C] HEARTBEAT -> RECOVERY = {0:N3} s" -f
        $heartbeatToRecovery
    ) -ForegroundColor Green
}

if ($null -ne $failureToRecovery) {
    Write-Host (
        "[DODATNO] NODE_FAILURE -> RECOVERY = {0:N3} s" -f
        $failureToRecovery
    ) -ForegroundColor DarkGray
}

# --------------------------------------------------
# 10. CSV
# --------------------------------------------------

$resultsDir = Join-Path $PSScriptRoot 'rezultati'

if (-not (Test-Path $resultsDir)) {
    New-Item -ItemType Directory -Path $resultsDir | Out-Null
}

$csvPath = Join-Path $resultsDir '04-recovery.csv'

[pscustomobject]@{
    run_time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    previous_node_failure = if ($failureTs) {
        $failureTs.ToString('yyyy-MM-dd HH:mm:ss.fff')
    } else {
        ''
    }
    vm_start_server_time = if ($vmStartServerTs) {
        $vmStartServerTs.ToString('yyyy-MM-dd HH:mm:ss.fff')
    } else {
        ''
    }
    first_heartbeat = if ($heartbeatTs) {
        $heartbeatTs.ToString('yyyy-MM-dd HH:mm:ss.fff')
    } else {
        ''
    }
    recovery = if ($recoveryTs) {
        $recoveryTs.ToString('yyyy-MM-dd HH:mm:ss.fff')
    } else {
        ''
    }
    vm_start_to_heartbeat_seconds = if ($null -ne $vmToHeartbeat) {
        [Math]::Round($vmToHeartbeat, 3)
    } else {
        ''
    }
    vm_start_to_recovery_seconds = if ($null -ne $vmToRecovery) {
        [Math]::Round($vmToRecovery, 3)
    } else {
        ''
    }
    heartbeat_to_recovery_seconds = if ($null -ne $heartbeatToRecovery) {
        [Math]::Round($heartbeatToRecovery, 3)
    } else {
        ''
    }
    node_failure_to_recovery_seconds = if ($null -ne $failureToRecovery) {
        [Math]::Round($failureToRecovery, 3)
    } else {
        ''
    }
} | Export-Csv `
    -Path $csvPath `
    -NoTypeInformation `
    -Append `
    -Encoding UTF8

Write-Host ''
Write-Host "[CSV] Rezultat dodan u: $csvPath" -ForegroundColor Green

Write-Host ''
Write-Host '[DOKAZ] Relevantan slijed nakon NODE_FAILURE:' -ForegroundColor Yellow

$evidence = Invoke-SshQuiet `
    -Target "$SshUser@$ServerIp" `
    -Command "tail -n +$searchStartLine '$ServerLog' | grep -E '\[HEARTBEAT\] HEARTBEAT agent-01|\[RECOVERY\].*host=agent-01|\[CORRELATION\].*host=agent-01' | tail -n 30" `
    -ConnectTimeout 5

$evidence.Output | ForEach-Object {
    Write-Host $_ -ForegroundColor White
}

Write-Host ''
Write-Host 'Eksperiment oporavka je zavrsen.' -ForegroundColor Green