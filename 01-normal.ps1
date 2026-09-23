# DIPLOMSKI - EKSPERIMENT 01: NORMALAN RAD
#
# FIKSNI LAYOUT ZA SVE EKSPERIMENTE:
#   SERVER | NIDS    | ATTACKER (samo kad je potreban)
#   AGENT1 | AGENT2  | AGENT3
#
# U normalnom scenariju ATTACKER se ne otvara pa je gornje desno polje prazno.
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

if (-not ("Exp01WindowTools" -as [type])) {
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class Exp01WindowTools {
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
        Title='EXP01-SERVER'
        Ip='192.168.56.101'
        Dir='/home/user/diplomski/server'
        SlotIndex=0
        Run=@'
STARTUP_LOG=/tmp/diplomski-exp01-server-startup.log
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
        Title='EXP01-NIDS'
        Ip='192.168.56.106'
        Dir='/home/user/diplomski/nids'
        SlotIndex=1
        Run=@'
STARTUP_LOG=/tmp/diplomski-exp01-nids-startup.log
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
        Title='EXP01-AGENT-01'
        Ip='192.168.56.102'
        Dir='/home/user/diplomski/agent'
        SlotIndex=3
        Run=@'
STARTUP_LOG=/tmp/diplomski-exp01-agent-startup.log
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
        Title='EXP01-AGENT-02'
        Ip='192.168.56.103'
        Dir='/home/user/diplomski/agent'
        SlotIndex=4
        Run=@'
STARTUP_LOG=/tmp/diplomski-exp01-agent-startup.log
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
        Title='EXP01-AGENT-03'
        Ip='192.168.56.104'
        Dir='/home/user/diplomski/agent'
        SlotIndex=5
        Run=@'
STARTUP_LOG=/tmp/diplomski-exp01-agent-startup.log
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
Write-Host ' EKSPERIMENT 01 - NORMALAN RAD' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

Write-Host '[CONFIG] response_mode -> correlated' -ForegroundColor DarkGray
ssh "$SshUser@192.168.56.101" "cd /home/user/diplomski/server && sed -i -E 's/^response_mode:.*/response_mode: correlated/' server.conf && grep '^response_mode:' server.conf"

if ($LASTEXITCODE -ne 0) {
    throw 'Ne mogu pripremiti server.conf.'
}

[Exp01WindowTools]::MinimizeContaining('DIPLOMSKI-')
[Exp01WindowTools]::MinimizeContaining('EXP01-')

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
echo " EKSPERIMENT 01 - NORMALAN RAD"
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
        $handle = [Exp01WindowTools]::Find($Node.Title)
        if ($handle -ne [IntPtr]::Zero) { break }
    }

    if ($handle -eq [IntPtr]::Zero) {
        Write-Warning "Nisam pronasao prozor $($Node.Title)"
        return
    }

    Start-Sleep -Milliseconds 400
    [Exp01WindowTools]::MoveWindow($handle,$Slot.X,$Slot.Y,$Slot.W,$Slot.H,$true) | Out-Null
}

foreach ($node in $Nodes) {
    Write-Host "[OPEN] $($node.Name)" -ForegroundColor DarkGray
    Start-LiveNodeWindow -Node $node -Slot $slots[$node.SlotIndex]
}

Write-Host ''
Write-Host '==================================================' -ForegroundColor Green
Write-Host ' EKSPERIMENT 01 JE POKRENUT' -ForegroundColor Green
Write-Host '==================================================' -ForegroundColor Green
Write-Host ''
Write-Host 'Layout:' -ForegroundColor Yellow
Write-Host '  SERVER   | NIDS     | [prazno]' -ForegroundColor White
Write-Host '  AGENT-01 | AGENT-02 | AGENT-03' -ForegroundColor White
Write-Host ''
Write-Host 'Svaki prozor prati stvarnu log datoteku.' -ForegroundColor Green
Write-Host 'Ako startup padne, prikazuje se startup stdout/stderr.' -ForegroundColor Green
Write-Host ''
Write-Host 'Za sazetak normalnog rada na serveru:' -ForegroundColor Yellow
Write-Host 'ssh user@192.168.56.101 "grep -E ''\[(HEARTBEAT|SERVICE_STATUS|PEER_STATE|CORRELATION)\]'' /home/user/diplomski/server/log/promet.log | tail -n 80"' -ForegroundColor White
