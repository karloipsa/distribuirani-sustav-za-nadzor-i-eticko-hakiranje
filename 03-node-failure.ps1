# DIPLOMSKI - EKSPERIMENT 03: NEDOSTUPNOST CIJELOG CVORA
#
# FIKSNI LAYOUT ZA SVE EKSPERIMENTE:
#   SERVER | NIDS    | ATTACKER (samo kad je potreban)
#   AGENT1 | AGENT2  | AGENT3
#
# U ovom scenariju ATTACKER se ne otvara pa je gornje desno polje prazno.
#
# Svaka komponenta:
# 1) zaustavi stari proces ako postoji
# 2) pokrene novi proces
# 3) kratko provjeri je li ostao aktivan
# 4) ako je startup pao, ispiše startup stdout/stderr
# 5) ako radi, prati STVARNU log datoteku s tail -F

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$SshUser = 'user'

$ServerIp     = '192.168.56.101'
$Agent01Ip    = '192.168.56.102'
$ServerLog    = '/home/user/diplomski/server/log/promet.log'
$Agent01VmName = 'Parrot OS 7.3 KDE Security Edition Agent 01'

# VBoxManage je potreban jer u ovom scenariju gasimo CIJELI VM agent-01.
$VBoxManage = @(
    (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Oracle\VirtualBox\VBoxManage.exe')
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $VBoxManage) {
    $vboxCmd = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
    if ($vboxCmd) { $VBoxManage = $vboxCmd.Source }
}

if (-not $VBoxManage) {
    throw 'VBoxManage.exe nije pronaden. Provjeri instalaciju VirtualBoxa.'
}

function Get-ExperimentVmState {
    param([string]$Name)

    $line = & $VBoxManage showvminfo $Name --machinereadable 2>$null |
        Where-Object { $_ -like 'VMState=*' } |
        Select-Object -First 1

    if ($line -match '^VMState="([^"]+)"') {
        return $Matches[1]
    }

    return $null
}

# Provjeri postoji li tocno VM "agent-01".
$vmPattern = '^"' + [regex]::Escape($Agent01VmName) + '"\s+\{'
$vmExists = (& $VBoxManage list vms 2>$null) | Where-Object { $_ -match $vmPattern }
if (-not $vmExists) {
    Write-Host '[ERROR] VirtualBox VM agent-01 nije pronaden.' -ForegroundColor Red
    Write-Host 'Dostupni VM-ovi:' -ForegroundColor Yellow
    & $VBoxManage list vms
    throw 'Provjeri vrijednost $Agent01VmName na vrhu skripte.'
}

# Ako je prethodni run ostavio agent-01 ugasen, podigni ga prije novog mjerenja.
# SSH cekamo neovisno o tome je li VM upravo pokrenut ili je vec bio u stanju running.
# To pokriva i slucaj kada je VirtualBox VM vec podignuo, ali se OS/sshd jos nisu stigli inicijalizirati.
function Wait-Agent01Ssh {
    param(
        [int]$TimeoutSeconds = 300,
        [int]$RetryDelaySeconds = 5
    )

    Write-Host "[VM] Cekam SSH na $Agent01Ip (maks. $TimeoutSeconds s)..." -ForegroundColor Yellow

    $sshReady = $false
    $sshStart = Get-Date
    $sshDeadline = $sshStart.AddSeconds($TimeoutSeconds)
    $attempt = 0

    while ((Get-Date) -lt $sshDeadline) {
        $attempt++

        # Windows PowerShell 5.1 pretvara stderr native programa u ErrorRecord.
        # SSH timeout je ovdje ocekivan tijekom bootanja VM-a, pa ga privremeno
        # ne smijemo tretirati kao terminating error zbog globalnog 'Stop'.
        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $probe = $null
        $sshExitCode = 255

        try {
            $probe = & ssh.exe `
                -o BatchMode=yes `
                -o ConnectTimeout=4 `
                -o ConnectionAttempts=1 `
                "$SshUser@$Agent01Ip" `
                'echo READY' 2>$null

            $sshExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }

        if ($sshExitCode -eq 0 -and (($probe | Select-Object -First 1) -eq 'READY')) {
            $sshReady = $true
            break
        }

        $elapsed = [int]((Get-Date) - $sshStart).TotalSeconds
        Write-Host ("  pokusaj {0}: SSH jos nije dostupan ({1} s)" -f $attempt, $elapsed) -ForegroundColor DarkGray

        Start-Sleep -Seconds $RetryDelaySeconds
    }

    if (-not $sshReady) {
        throw "agent-01 VM radi, ali SSH nije postao dostupan unutar $TimeoutSeconds s."
    }

    $sshElapsed = [int]((Get-Date) - $sshStart).TotalSeconds
    Write-Host ("[VM] agent-01 je dostupan preko SSH-a nakon {0} s ({1} pokusaja)." -f $sshElapsed, $attempt) -ForegroundColor Green
}

$initialVmState = Get-ExperimentVmState $Agent01VmName

if ($initialVmState -ne 'running') {
    Write-Host "[VM] agent-01 je $initialVmState. Pokrecem VM..." -ForegroundColor Yellow
    & $VBoxManage startvm $Agent01VmName --type headless | Out-Host

    if ($LASTEXITCODE -ne 0) {
        throw 'Ne mogu pokrenuti VM agent-01.'
    }
}
else {
    Write-Host '[VM] agent-01 je vec pokrenut. Provjeravam SSH...' -ForegroundColor DarkGray
}

Wait-Agent01Ssh -TimeoutSeconds 300 -RetryDelaySeconds 5

if (-not ("Exp03WindowTools" -as [type])) {
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class Exp03WindowTools {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool MoveWindow(IntPtr hWnd, int x, int y, int width, int height, bool repaint);

    public static IntPtr Find(string titlePart) {
        IntPtr result = IntPtr.Zero;

        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) return true;

            StringBuilder title = new StringBuilder(512);
            GetWindowText(hWnd, title, title.Capacity);

            if (title.ToString().Contains(titlePart)) {
                result = hWnd;
                return false;
            }

            return true;
        }, IntPtr.Zero);

        return result;
    }

    public static void MinimizeContaining(string titlePart) {
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) return true;

            StringBuilder title = new StringBuilder(512);
            GetWindowText(hWnd, title, title.Capacity);

            if (title.ToString().Contains(titlePart))
                ShowWindowAsync(hWnd, 6);

            return true;
        }, IntPtr.Zero);
    }
}
"@
}

# SlotIndex:
# 0 SERVER       1 NIDS        2 ATTACKER
# 3 AGENT-01     4 AGENT-02    5 AGENT-03

$Nodes = @(
    [pscustomobject]@{
        Name='SERVER'
        Title='EXP03-SERVER'
        Ip='192.168.56.101'
        Dir='/home/user/diplomski/server'
        SlotIndex=0
        Run=@'
STARTUP_LOG=/tmp/diplomski-exp03-server-startup.log
: > "$STARTUP_LOG"

echo "[PREP] Zaustavljam stari SERVER proces ako postoji..."
pkill -f "[s]erver.sh" 2>/dev/null || true
sleep 1

echo "[START] bash ./server.sh"
bash ./server.sh >"$STARTUP_LOG" 2>&1 &
sleep 2

if ! pgrep -f "[s]erver.sh" >/dev/null; then
    echo
    echo "[ERROR] SERVER nije ostao aktivan."
    echo "-------- STARTUP OUTPUT --------"
    cat "$STARTUP_LOG"
    echo "--------------------------------"
    exec bash -i
fi

echo "[OK] SERVER proces radi."
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '(:|\])5000$'; then
    echo "[OK] Port 5000 slusa."
else
    echo "[WARN] Port 5000 jos nije pronaden."
fi

echo
echo "[LOG] /home/user/diplomski/server/log/promet.log"
echo "--------------------------------------------------"
tail -n 35 -F /home/user/diplomski/server/log/promet.log
'@
    },

    [pscustomobject]@{
        Name='NIDS'
        Title='EXP03-NIDS'
        Ip='192.168.56.106'
        Dir='/home/user/diplomski/nids'
        SlotIndex=1
        Run=@'
STARTUP_LOG=/tmp/diplomski-exp03-nids-startup.log
: > "$STARTUP_LOG"

echo "[PREP] Zaustavljam stari NIDS proces ako postoji..."
sudo -n pkill -f "[n]ids.sh" 2>/dev/null || true
sleep 1

echo "[START] sudo -n bash ./nids.sh"
sudo -n bash ./nids.sh >"$STARTUP_LOG" 2>&1 &
sleep 3

if ! pgrep -f "[n]ids.sh" >/dev/null; then
    echo
    echo "[ERROR] NIDS nije ostao aktivan."
    echo "-------- STARTUP OUTPUT --------"
    cat "$STARTUP_LOG"
    echo "--------------------------------"
    exec bash -i
fi

echo "[OK] NIDS proces radi."
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '(:|\])5001$'; then
    echo "[OK] Control port 5001 slusa."
else
    echo "[WARN] Control port 5001 jos nije pronaden."
fi

echo
echo "[STARTUP] Zadnjih nekoliko startup redaka:"
tail -n 8 "$STARTUP_LOG" 2>/dev/null || true
echo
echo "[LOG] /home/user/diplomski/nids/log/nids.log"
echo "--------------------------------------------------"
tail -n 35 -F /home/user/diplomski/nids/log/nids.log
'@
    },

    [pscustomobject]@{
        Name='AGENT-01'
        Title='EXP03-AGENT-01'
        Ip='192.168.56.102'
        Dir='/home/user/diplomski/agent'
        SlotIndex=3
        Run=@'
STARTUP_LOG=/tmp/diplomski-exp03-agent-startup.log
: > "$STARTUP_LOG"

echo "[PREP] Zaustavljam stari AGENT proces ako postoji..."
sudo -n pkill -f "[a]gent.sh" 2>/dev/null || true
sleep 1

echo "[START] sudo -n ./agent.sh"
sudo -n ./agent.sh >"$STARTUP_LOG" 2>&1 &
sleep 3

if ! pgrep -f "[a]gent.sh" >/dev/null; then
    echo
    echo "[ERROR] AGENT-01 nije ostao aktivan."
    echo "-------- STARTUP OUTPUT --------"
    cat "$STARTUP_LOG"
    echo "--------------------------------"
    exec bash -i
fi

echo "[OK] AGENT-01 proces radi."
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '(:|\])6000$'; then
    echo "[OK] Port 6000 slusa."
else
    echo "[WARN] Port 6000 jos nije pronaden."
fi

echo
echo "[LOG] /home/user/diplomski/agent/log/agent.log"
echo "--------------------------------------------------"
tail -n 35 -F /home/user/diplomski/agent/log/agent.log
'@
    },

    [pscustomobject]@{
        Name='AGENT-02'
        Title='EXP03-AGENT-02'
        Ip='192.168.56.103'
        Dir='/home/user/diplomski/agent'
        SlotIndex=4
        Run=@'
STARTUP_LOG=/tmp/diplomski-exp03-agent-startup.log
: > "$STARTUP_LOG"

echo "[PREP] Zaustavljam stari AGENT proces ako postoji..."
sudo -n pkill -f "[a]gent.sh" 2>/dev/null || true
sleep 1

echo "[START] sudo -n ./agent.sh"
sudo -n ./agent.sh >"$STARTUP_LOG" 2>&1 &
sleep 3

if ! pgrep -f "[a]gent.sh" >/dev/null; then
    echo
    echo "[ERROR] AGENT-02 nije ostao aktivan."
    echo "-------- STARTUP OUTPUT --------"
    cat "$STARTUP_LOG"
    echo "--------------------------------"
    exec bash -i
fi

echo "[OK] AGENT-02 proces radi."
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '(:|\])6000$'; then
    echo "[OK] Port 6000 slusa."
else
    echo "[WARN] Port 6000 jos nije pronaden."
fi

echo
echo "[LOG] /home/user/diplomski/agent/log/agent.log"
echo "--------------------------------------------------"
tail -n 35 -F /home/user/diplomski/agent/log/agent.log
'@
    },

    [pscustomobject]@{
        Name='AGENT-03'
        Title='EXP03-AGENT-03'
        Ip='192.168.56.104'
        Dir='/home/user/diplomski/agent'
        SlotIndex=5
        Run=@'
STARTUP_LOG=/tmp/diplomski-exp03-agent-startup.log
: > "$STARTUP_LOG"

echo "[PREP] Zaustavljam stari AGENT proces ako postoji..."
sudo -n pkill -f "[a]gent.sh" 2>/dev/null || true
sleep 1

echo "[START] sudo -n ./agent.sh"
sudo -n ./agent.sh >"$STARTUP_LOG" 2>&1 &
sleep 3

if ! pgrep -f "[a]gent.sh" >/dev/null; then
    echo
    echo "[ERROR] AGENT-03 nije ostao aktivan."
    echo "-------- STARTUP OUTPUT --------"
    cat "$STARTUP_LOG"
    echo "--------------------------------"
    exec bash -i
fi

echo "[OK] AGENT-03 proces radi."
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '(:|\])6000$'; then
    echo "[OK] Port 6000 slusa."
else
    echo "[WARN] Port 6000 jos nije pronaden."
fi

echo
echo "[LOG] /home/user/diplomski/agent/log/agent.log"
echo "--------------------------------------------------"
tail -n 35 -F /home/user/diplomski/agent/log/agent.log
'@
    }
)

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ' EKSPERIMENT 03 - NEDOSTUPNOST CIJELOG CVORA' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

Write-Host '[CONFIG] response_mode -> correlated' -ForegroundColor DarkGray
ssh "$SshUser@192.168.56.101" "cd /home/user/diplomski/server && sed -i -E 's/^response_mode:.*/response_mode: correlated/' server.conf && grep '^response_mode:' server.conf"

if ($LASTEXITCODE -ne 0) {
    throw 'Ne mogu pripremiti server.conf.'
}

[Exp03WindowTools]::MinimizeContaining('DIPLOMSKI-')
[Exp03WindowTools]::MinimizeContaining('EXP0')

Start-Sleep -Milliseconds 300

$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$w = [int]($area.Width / 3)
$h = [int]($area.Height / 2)

$slots = @(
    [pscustomobject]@{X=$area.Left;        Y=$area.Top;      W=$w; H=$h}, # SERVER
    [pscustomobject]@{X=$area.Left+$w;     Y=$area.Top;      W=$w; H=$h}, # NIDS
    [pscustomobject]@{X=$area.Left+2*$w;   Y=$area.Top;      W=$w; H=$h}, # ATTACKER
    [pscustomobject]@{X=$area.Left;        Y=$area.Top+$h;   W=$w; H=$h}, # AGENT-01
    [pscustomobject]@{X=$area.Left+$w;     Y=$area.Top+$h;   W=$w; H=$h}, # AGENT-02
    [pscustomobject]@{X=$area.Left+2*$w;   Y=$area.Top+$h;   W=$w; H=$h}  # AGENT-03
)

function Start-LiveNodeWindow {
    param($Node, $Slot)

    $remote = @"
cd $($Node.Dir) || exit 1

echo "=================================================="
echo " EKSPERIMENT 03 - NEDOSTUPNOST CIJELOG CVORA"
echo " NODE: $($Node.Name)"
echo " IP:   $($Node.Ip)"
echo "=================================================="
echo

$($Node.Run)
"@

    $remote = $remote -replace "`r", ''
    $remote64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))

    $window = @"
`$Host.UI.RawUI.WindowTitle = '$($Node.Title)'
`$Host.UI.RawUI.BackgroundColor = 'Black'
`$Host.UI.RawUI.ForegroundColor = 'Green'
Clear-Host
ssh -tt $SshUser@$($Node.Ip) "echo '$remote64' | base64 -d | bash"
"@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($window))

    Start-Process conhost.exe -ArgumentList @(
        'powershell.exe',
        '-NoLogo',
        '-NoExit',
        '-EncodedCommand',
        $encoded
    )

    $handle = [IntPtr]::Zero

    for ($i=0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 200
        $handle = [Exp03WindowTools]::Find($Node.Title)
        if ($handle -ne [IntPtr]::Zero) { break }
    }

    if ($handle -eq [IntPtr]::Zero) {
        Write-Warning "Nisam pronasao prozor $($Node.Title)"
        return
    }

    Start-Sleep -Milliseconds 400
    [Exp03WindowTools]::MoveWindow($handle,$Slot.X,$Slot.Y,$Slot.W,$Slot.H,$true) | Out-Null
}

foreach ($node in $Nodes) {
    Write-Host "[OPEN] $($node.Name)" -ForegroundColor DarkGray
    Start-LiveNodeWindow -Node $node -Slot $slots[$node.SlotIndex]
}

Write-Host ''
Write-Host '==================================================' -ForegroundColor Green
Write-Host ' EKSPERIMENT 03 JE POKRENUT' -ForegroundColor Green
Write-Host '==================================================' -ForegroundColor Green
Write-Host ''
Write-Host 'Layout:' -ForegroundColor Yellow
Write-Host '  SERVER   | NIDS     | [prazno]' -ForegroundColor White
Write-Host '  AGENT-01 | AGENT-02 | AGENT-03' -ForegroundColor White
Write-Host ''
Write-Host 'Svaki prozor prati stvarnu log datoteku.' -ForegroundColor Green
Write-Host 'CIJELI VM agent-01 ugasit ce se tek nakon tvoje potvrde u ovom prozoru.' -ForegroundColor Green
Write-Host ''

# Daj sustavu jedan puni ciklus za HEARTBEAT i PEER_STATE prije kvara.
Write-Host '[BASELINE] Cekam 70 s da se zabiljezi stabilan ciklus...' -ForegroundColor Yellow
for ($remaining = 70; $remaining -gt 0; $remaining -= 10) {
    Write-Host ("  jos {0} s" -f $remaining) -ForegroundColor DarkGray
    Start-Sleep -Seconds ([Math]::Min(10, $remaining))
}

Write-Host ''
Write-Host '[BASELINE] Zadnji relevantni zapisi za agent-01:' -ForegroundColor Yellow
$baselineCmd = "grep -E '\[HEARTBEAT\] HEARTBEAT agent-01|\[PEER_STATE\].*target=agent-01.*state=HEALTHY' '$ServerLog' | tail -n 6"
ssh "$SshUser@$ServerIp" $baselineCmd

Write-Host ''
Write-Host 'Provjeri da vidis svjezi HEARTBEAT agent-01 i HEALTHY peer opazanja.' -ForegroundColor Yellow
Write-Host 'Nakon ENTER-a skripta ce napraviti VirtualBox poweroff cijelog VM-a agent-01.' -ForegroundColor Red
Read-Host 'Pritisni ENTER za gasenje cijelog VM-a agent-01' | Out-Null

# Od ove linije nadalje trazimo samo zapise nastale nakon stvarnog node-failure triggera.
$beforeTriggerRaw = (ssh "$SshUser@$ServerIp" "wc -l < '$ServerLog'")
$beforeTriggerLines = [int](($beforeTriggerRaw | Select-Object -Last 1).Trim())
$searchStartLine = $beforeTriggerLines + 1

# Ground-truth vrijeme uzimamo sa SERVERA da sva vremena budu iz istog sata.
$triggerServerText = (ssh "$SshUser@$ServerIp" "date '+%Y-%m-%d %H:%M:%S.%3N'" | Select-Object -First 1).Trim()
$triggerLocal = Get-Date

Write-Host ''
Write-Host ("[TRIGGER] {0:yyyy-MM-dd HH:mm:ss.fff} - gasim CIJELI VM agent-01" -f $triggerLocal) -ForegroundColor Red
Write-Host "[TRIGGER-SERVER-TIME] $triggerServerText" -ForegroundColor DarkGray

& $VBoxManage controlvm $Agent01VmName poweroff | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw 'VirtualBox poweroff za agent-01 nije uspio.'
}

Start-Sleep -Seconds 2
$stateAfterPoweroff = Get-ExperimentVmState $Agent01VmName
Write-Host "[VM] agent-01 stanje nakon triggera: $stateAfterPoweroff" -ForegroundColor White
if ($stateAfterPoweroff -eq 'running') {
    throw 'agent-01 je i dalje running; prekidam mjerenje.'
}

Write-Host ''
Write-Host '[WAIT] Cekam novu korelaciju NODE_FAILURE za agent-01 (maks. 300 s)...' -ForegroundColor Yellow
Write-Host 'Normalno je da se prije NODE_FAILURE pojave AGENT_FAILURE i/ili NODE_STATE_UNCERTAIN.' -ForegroundColor DarkGray

$failureLine = $null
$waitStart = Get-Date
$deadline = $waitStart.AddSeconds(300)
$nextStatus = 0

while ((Get-Date) -lt $deadline) {
    $checkCmd = "tail -n +$searchStartLine '$ServerLog' | grep -E 'state=NODE_FAILURE.*host=agent-01|host=agent-01.*state=NODE_FAILURE' | head -n 1"
    $candidate = ssh "$SshUser@$ServerIp" $checkCmd 2>$null | Select-Object -First 1

    if ($candidate) {
        $failureLine = $candidate.Trim()
        break
    }

    $elapsedWait = [int]((Get-Date) - $waitStart).TotalSeconds
    if ($elapsedWait -ge $nextStatus) {
        Write-Host ("  cekanje: {0} s" -f $elapsedWait) -ForegroundColor DarkGray
        $nextStatus += 10
    }

    Start-Sleep -Seconds 5
}

if (-not $failureLine) {
    Write-Host ''
    Write-Host '[ERROR] NODE_FAILURE nije pronaden unutar 300 s.' -ForegroundColor Red
    Write-Host 'Provjeri SERVER prozor i zatim rucno pokreni:' -ForegroundColor Yellow
    Write-Host 'ssh user@192.168.56.101 "grep -E ''HEARTBEAT agent-01|PEER_STATE.*target=agent-01|AGENT_FAILURE|NODE_STATE_UNCERTAIN|NODE_FAILURE'' /home/user/diplomski/server/log/promet.log | tail -n 80"' -ForegroundColor White
    exit 1
}

$lastHeartbeatCmd = "grep -E '\[HEARTBEAT\] HEARTBEAT agent-01( |$)' '$ServerLog' | tail -n 1"
$lastHeartbeatLine = (ssh "$SshUser@$ServerIp" $lastHeartbeatCmd | Select-Object -First 1).Trim()

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

    try {
        return [DateTime]::ParseExact(
            $Text,
            'yyyy-MM-dd HH:mm:ss.fff',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        return $null
    }
}

$heartbeatTs = Get-LogTimestamp $lastHeartbeatLine
$failureTs   = Get-LogTimestamp $failureLine
$triggerServerTs = Get-PlainTimestamp $triggerServerText

$heartbeatToFailureSeconds = $null
$triggerToFailureSeconds = $null

if ($heartbeatTs -and $failureTs) {
    $heartbeatToFailureSeconds = ($failureTs - $heartbeatTs).TotalSeconds
}

if ($triggerServerTs -and $failureTs) {
    $triggerToFailureSeconds = ($failureTs - $triggerServerTs).TotalSeconds
}

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ' REZULTAT - NODE FAILURE' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '[LAST HEARTBEAT]' -ForegroundColor Yellow
Write-Host $lastHeartbeatLine -ForegroundColor White
Write-Host '[NODE_FAILURE]' -ForegroundColor Yellow
Write-Host $failureLine -ForegroundColor White

if ($null -ne $heartbeatToFailureSeconds) {
    Write-Host ("[MJERENJE A] zadnji HEARTBEAT -> NODE_FAILURE = {0:N3} s" -f $heartbeatToFailureSeconds) -ForegroundColor Green
}

if ($null -ne $triggerToFailureSeconds) {
    Write-Host ("[MJERENJE B] gasenje VM-a -> NODE_FAILURE = {0:N3} s" -f $triggerToFailureSeconds) -ForegroundColor Green
}

Write-Host ''
Write-Host '[DOKAZ] Tranzicije i peer opazanja nakon gasenja VM-a:' -ForegroundColor Yellow
$evidenceCmd = "tail -n +$searchStartLine '$ServerLog' | grep -E '\[PEER_STATE\].*target=agent-01.*state=(DEGRADED|UNREACHABLE)|\[CORRELATION\].*state=(AGENT_FAILURE|NODE_STATE_UNCERTAIN|NODE_FAILURE).*host=agent-01' | tail -n 50"
ssh "$SshUser@$ServerIp" $evidenceCmd

# Spremi sazetak. VM ostaje ugasen da se stanje moze pregledati.
if ($null -ne $heartbeatToFailureSeconds) {
    $resultsDir = Join-Path $PSScriptRoot 'rezultati'
    if (-not (Test-Path $resultsDir)) {
        New-Item -ItemType Directory -Path $resultsDir | Out-Null
    }

    $csvPath = Join-Path $resultsDir '03-node-failure.csv'
    [pscustomobject]@{
        run_time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        trigger_server_time = $triggerServerText
        last_heartbeat = if ($heartbeatTs) { $heartbeatTs.ToString('yyyy-MM-dd HH:mm:ss.fff') } else { '' }
        node_failure = if ($failureTs) { $failureTs.ToString('yyyy-MM-dd HH:mm:ss.fff') } else { '' }
        heartbeat_to_node_failure_seconds = if ($null -ne $heartbeatToFailureSeconds) { [Math]::Round($heartbeatToFailureSeconds, 3) } else { '' }
        poweroff_to_node_failure_seconds = if ($null -ne $triggerToFailureSeconds) { [Math]::Round($triggerToFailureSeconds, 3) } else { '' }
    } | Export-Csv -Path $csvPath -NoTypeInformation -Append -Encoding UTF8

    Write-Host ''
    Write-Host "[CSV] Rezultat je dodan u: $csvPath" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Eksperiment je zavrsen. VM agent-01 ostaje UGASEN radi pregleda stanja.' -ForegroundColor Green
Write-Host 'Pri sljedecem pokretanju ovog PS1 skripta ce ga automatski podignuti, pricekati SSH i pripremiti novi run.' -ForegroundColor DarkGray