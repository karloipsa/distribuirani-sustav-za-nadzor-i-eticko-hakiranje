param(
    # Trajanje svakog kontroliranog ICMP bursta.
    [ValidateRange(1,10)]
    [int]$FloodDurationSeconds = 3,

    # ping interval se izvodi iz ove vrijednosti. Zadano 20 pps => -i 0.05.
    # To je potvrđeno da radi bez sudo na ATTACKER VM-u.
    [ValidateRange(5,50)]
    [int]$PacketsPerSecond = 20,

    # Pauza nakon prvog bursta. Uz burst od 3 s drugi alarm dolazi
    # dovoljno nakon NIDS cooldowna (10 s), ali unutar server repeat prozora (30 s).
    [ValidateRange(8,20)]
    [int]$SecondBurstDelaySeconds = 10
)

$ErrorActionPreference = 'Stop'

$Mode = 'correlated'
$TargetKind = 'agent'
$TargetDataIp = '192.168.100.2'
$TargetLabel = 'agent-01'
$NeedHealthyAgentBaseline = $true

$SshUser = 'user'

$ServerIp   = '192.168.56.101'
$Agent01Ip  = '192.168.56.102'
$Agent02Ip  = '192.168.56.103'
$Agent03Ip  = '192.168.56.104'
$AttackerIp = '192.168.56.105'
$NidsIp     = '192.168.56.106'

$AttackerDataIp = '192.168.200.5'

$ServerLog = '/home/user/diplomski/server/log/promet.log'
$NidsLog   = '/home/user/diplomski/nids/log/nids.log'
$AgentLog  = '/home/user/diplomski/agent/log/agent.log'
$FloodLog  = '/tmp/diplomski-exp06-flood.log'
$FloodMeta = '/tmp/diplomski-exp06-flood-meta.log'
$PingRawLog = '/tmp/diplomski-exp06-ping-raw.log'

$BaselineTimeoutSeconds = 150
$PollSeconds = 5

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
        # stderr namjerno spajamo u izlaz.
        # Ako remote naredba pukne, ispisujemo stvarnu gresku umjesto
        # beskorisnog "exit=2".
        $out = @(
            & ssh.exe `
                -o BatchMode=yes `
                -o ConnectTimeout=5 `
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
        $detail = ($out | Select-Object -Last 12) -join "`n"

        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = '(remote naredba nije vratila tekst greske)'
        }

        throw "SSH naredba nije uspjela za $Ip (exit=$code).`n$detail"
    }

    return $out
}

function Get-LineCount {
    param([string]$Ip,[string]$Path)

    $x = Invoke-SshText -Ip $Ip -Command "test -f '$Path' && wc -l < '$Path' || echo 0" -AllowFailure |
        Select-Object -Last 1

    if ($x -and $x.Trim() -match '^\d+$') {
        return [int]$x.Trim()
    }

    return 0
}

function Get-FirstMatch {
    param(
        [string]$Ip,
        [string]$Path,
        [int]$StartLine,
        [string]$Regex
    )

    $cmd = "tail -n +$StartLine '$Path' 2>/dev/null | grep -E '$Regex' | head -n 1 || true"
    $line = Invoke-SshText -Ip $Ip -Command $cmd -AllowFailure | Select-Object -First 1

    if ($line) { return $line.Trim() }
    return $null
}

function Get-LastMatch {
    param(
        [string]$Ip,
        [string]$Path,
        [int]$StartLine,
        [string]$Regex
    )

    $cmd = "tail -n +$StartLine '$Path' 2>/dev/null | grep -E '$Regex' | tail -n 1 || true"
    $line = Invoke-SshText -Ip $Ip -Command $cmd -AllowFailure | Select-Object -First 1

    if ($line) { return $line.Trim() }
    return $null
}

function Get-NthMatch {
    param(
        [string]$Ip,
        [string]$Path,
        [int]$StartLine,
        [string]$Regex,
        [ValidateRange(1,20)]
        [int]$N
    )

    $cmd = "tail -n +$StartLine '$Path' 2>/dev/null | grep -E '$Regex' | sed -n '${N}p' || true"
    $line = Invoke-SshText -Ip $Ip -Command $cmd -AllowFailure | Select-Object -First 1

    if ($line) { return $line.Trim() }
    return $null
}

function Wait-ForNthMatch {
    param(
        [string]$Ip,
        [string]$Path,
        [int]$StartLine,
        [string]$Regex,
        [ValidateRange(1,20)]
        [int]$N,
        [int]$TimeoutSeconds = 15,
        [int]$PollMilliseconds = 250
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        $line = Get-NthMatch -Ip $Ip -Path $Path -StartLine $StartLine -Regex $Regex -N $N
        if ($line) { return $line }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    while ((Get-Date) -lt $deadline)

    return $null
}

function Get-LogTime {
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

function Get-PlainTime {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

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

function Delta {
    param($A,$B)

    if ($null -eq $A -or $null -eq $B) { return $null }
    return [Math]::Round(($B-$A).TotalSeconds,3)
}


# --------------------------------------------------
# Live SSH prozori
#
# Koristi ISTI pristup kao lab-all.ps1:
# - remote Bash naredba se UTF-8/base64 kodira
# - novi terminal pokrece: ssh -tt ... "echo BASE64 | base64 -d | bash"
# - conhost prozori se rasporeduju 3 x 2
#
# SERVER | NIDS | NAPADAC
# AGENT-01 | AGENT-02 | AGENT-03
# --------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms

$Exp06FontSize = 11
$Exp06BufferWidth = 190

if (-not ('Exp06LabWindowTools' -as [type])) {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class Exp06LabWindowTools
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(
        EnumWindowsProc enumProc,
        IntPtr lParam
    );

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(
        IntPtr hWnd,
        StringBuilder text,
        int count
    );

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool MoveWindow(
        IntPtr hWnd,
        int x,
        int y,
        int width,
        int height,
        bool repaint
    );

    public static IntPtr FindWindowContaining(string titlePart)
    {
        IntPtr result = IntPtr.Zero;

        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
        {
            if (!IsWindowVisible(hWnd))
                return true;

            StringBuilder title = new StringBuilder(512);
            GetWindowText(hWnd, title, title.Capacity);

            if (title.ToString().Contains(titlePart))
            {
                result = hWnd;
                return false;
            }

            return true;
        }, IntPtr.Zero);

        return result;
    }
}
"@
}

function Start-Exp06Window {
    param(
        [string]$Title,
        [string]$Ip,
        [string]$RemoteCommand,
        [string]$Color,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height
    )

    $remoteCommandClean = $RemoteCommand -replace "`r", ""

    # Bitno: Linux naredbu NE dajemo PowerShell parseru.
    # Kodiramo ju, a remote bash je dekodira.
    $remoteBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($remoteCommandClean)
    )

    $windowCommand = @"
`$Host.UI.RawUI.WindowTitle = '$Title'
`$Host.UI.RawUI.BackgroundColor = 'Black'
`$Host.UI.RawUI.ForegroundColor = '$Color'
Clear-Host

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class Exp06ConsoleFont
{
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD
    {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CONSOLE_FONT_INFOEX
    {
        public uint cbSize;
        public uint nFont;
        public COORD dwFontSize;
        public int FontFamily;
        public int FontWeight;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FaceName;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport(
        "kernel32.dll",
        SetLastError = true,
        CharSet = CharSet.Unicode
    )]
    private static extern bool SetCurrentConsoleFontEx(
        IntPtr hConsoleOutput,
        bool bMaximumWindow,
        ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx
    );

    public static void SetFont(short size, string face)
    {
        CONSOLE_FONT_INFOEX info = new CONSOLE_FONT_INFOEX();
        info.cbSize = (uint)Marshal.SizeOf(info);
        info.dwFontSize.X = 0;
        info.dwFontSize.Y = size;
        info.FontFamily = 54;
        info.FontWeight = 400;
        info.FaceName = face;

        SetCurrentConsoleFontEx(
            GetStdHandle(-11),
            false,
            ref info
        );
    }
}
'@

try {
    [Exp06ConsoleFont]::SetFont(
        $Exp06FontSize,
        'Cascadia Mono'
    )
}
catch {}

try {
    `$buffer = `$Host.UI.RawUI.BufferSize
    `$buffer.Width = $Exp06BufferWidth

    if (`$buffer.Height -lt 3000) {
        `$buffer.Height = 3000
    }

    `$Host.UI.RawUI.BufferSize = `$buffer
}
catch {}

Write-Host '=================================================='
Write-Host ' EXPERIMENT 06 - LIVE'
Write-Host ' NODE: $Title'
Write-Host ' IP:   $Ip'
Write-Host '=================================================='
Write-Host ''

ssh -tt user@$Ip "echo '$remoteBase64' | base64 -d | bash"
"@

    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($windowCommand)
    )

    Start-Process conhost.exe -ArgumentList @(
        'powershell.exe',
        '-NoLogo',
        '-NoExit',
        '-EncodedCommand',
        $encodedCommand
    ) | Out-Null

    $handle = [IntPtr]::Zero

    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 200

        $handle = [Exp06LabWindowTools]::FindWindowContaining(
            $Title
        )

        if ($handle -ne [IntPtr]::Zero) {
            break
        }
    }

    if ($handle -eq [IntPtr]::Zero) {
        Write-Warning "Nisam pronasao prozor: $Title"
        return
    }

    Start-Sleep -Milliseconds 1200

    [Exp06LabWindowTools]::MoveWindow(
        $handle,
        $X,
        $Y,
        $Width,
        $Height,
        $true
    ) | Out-Null

    Start-Sleep -Milliseconds 300

    [Exp06LabWindowTools]::MoveWindow(
        $handle,
        $X,
        $Y,
        $Width,
        $Height,
        $true
    ) | Out-Null
}

function Open-AllLiveLogWindows {
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

    $cellWidth  = [int]($area.Width / 3)
    $cellHeight = [int]($area.Height / 2)

    Write-Host ''
    Write-Host '[PROZORI] Otvaram live raspored:' -ForegroundColor Cyan
    Write-Host '  SERVER   | NIDS     | NAPADAC' -ForegroundColor White
    Write-Host '  AGENT-01 | AGENT-02 | AGENT-03' -ForegroundColor White

    Start-Exp06Window `
        -Title 'EXP06-SERVER' `
        -Ip $ServerIp `
        -Color 'Magenta' `
        -X $area.Left `
        -Y $area.Top `
        -Width $cellWidth `
        -Height $cellHeight `
        -RemoteCommand @'
cd /home/user/diplomski/server || exit 1

echo
echo "[LOG] /home/user/diplomski/server/log/promet.log"
echo "--------------------------------------------------"

tail -n 35 -F /home/user/diplomski/server/log/promet.log

echo
echo "[SHELL] Ostajes spojen na SERVER."
export TERM=xterm-256color
export PS1='\[\e[95m\][\u@\h \W]\$ '
printf '\033[95m'
exec bash --noprofile --norc -i </dev/tty >/dev/tty 2>/dev/tty
'@

    Start-Exp06Window `
        -Title 'EXP06-NIDS' `
        -Ip $NidsIp `
        -Color 'Yellow' `
        -X ($area.Left + $cellWidth) `
        -Y $area.Top `
        -Width $cellWidth `
        -Height $cellHeight `
        -RemoteCommand @'
cd /home/user/diplomski/nids || exit 1

echo
echo "[LOG] /home/user/diplomski/nids/log/nids.log"
echo "--------------------------------------------------"

tail -n 35 -F /home/user/diplomski/nids/log/nids.log

echo
echo "[SHELL] Ostajes spojen na NIDS."
export TERM=xterm-256color
export PS1='\[\e[93m\][\u@\h \W]\$ '
printf '\033[93m'
exec bash --noprofile --norc -i </dev/tty >/dev/tty 2>/dev/tty
'@

    Start-Exp06Window `
        -Title 'EXP06-NAPADAC' `
        -Ip $AttackerIp `
        -Color 'Red' `
        -X ($area.Left + (2 * $cellWidth)) `
        -Y $area.Top `
        -Width $cellWidth `
        -Height $cellHeight `
        -RemoteCommand @'
touch /tmp/diplomski-exp06-flood.log

echo
echo "[LOG] /tmp/diplomski-exp06-flood.log"
echo "--------------------------------------------------"

tail -n 35 -F /tmp/diplomski-exp06-flood.log

echo
echo "[SHELL] Ostajes spojen na NAPADAC."
export TERM=xterm-256color
export PS1='\[\e[91m\][\u@\h \W]\$ '
printf '\033[91m'
exec bash --noprofile --norc -i </dev/tty >/dev/tty 2>/dev/tty
'@

    Start-Exp06Window `
        -Title 'EXP06-AGENT-01' `
        -Ip $Agent01Ip `
        -Color 'Green' `
        -X $area.Left `
        -Y ($area.Top + $cellHeight) `
        -Width $cellWidth `
        -Height $cellHeight `
        -RemoteCommand @'
cd /home/user/diplomski/agent || exit 1

echo
echo "[LOG] /home/user/diplomski/agent/log/agent.log"
echo "--------------------------------------------------"

tail -n 35 -F /home/user/diplomski/agent/log/agent.log

echo
echo "[SHELL] Ostajes spojen na AGENT-01."
export TERM=xterm-256color
export PS1='\[\e[92m\][\u@\h \W]\$ '
printf '\033[92m'
exec bash --noprofile --norc -i </dev/tty >/dev/tty 2>/dev/tty
'@

    Start-Exp06Window `
        -Title 'EXP06-AGENT-02' `
        -Ip $Agent02Ip `
        -Color 'Green' `
        -X ($area.Left + $cellWidth) `
        -Y ($area.Top + $cellHeight) `
        -Width $cellWidth `
        -Height $cellHeight `
        -RemoteCommand @'
cd /home/user/diplomski/agent || exit 1

echo
echo "[LOG] /home/user/diplomski/agent/log/agent.log"
echo "--------------------------------------------------"

tail -n 35 -F /home/user/diplomski/agent/log/agent.log

echo
echo "[SHELL] Ostajes spojen na AGENT-02."
export TERM=xterm-256color
export PS1='\[\e[92m\][\u@\h \W]\$ '
printf '\033[92m'
exec bash --noprofile --norc -i </dev/tty >/dev/tty 2>/dev/tty
'@

    Start-Exp06Window `
        -Title 'EXP06-AGENT-03' `
        -Ip $Agent03Ip `
        -Color 'Green' `
        -X ($area.Left + (2 * $cellWidth)) `
        -Y ($area.Top + $cellHeight) `
        -Width $cellWidth `
        -Height $cellHeight `
        -RemoteCommand @'
cd /home/user/diplomski/agent || exit 1

echo
echo "[LOG] /home/user/diplomski/agent/log/agent.log"
echo "--------------------------------------------------"

tail -n 35 -F /home/user/diplomski/agent/log/agent.log

echo
echo "[SHELL] Ostajes spojen na AGENT-03."
export TERM=xterm-256color
export PS1='\[\e[92m\][\u@\h \W]\$ '
printf '\033[92m'
exec bash --noprofile --norc -i </dev/tty >/dev/tty 2>/dev/tty
'@

    Start-Sleep -Seconds 2
}

function Start-RealComponent {
    param(
        [string]$Name,
        [string]$Ip,
        [string]$Command
    )

    Write-Host ("[START] {0}" -f $Name) -ForegroundColor Yellow

    $out = Invoke-SshText -Ip $Ip -Command $Command
    $out | ForEach-Object {
        if ($_ -and $_.Trim()) {
            Write-Host ("  {0}" -f $_) -ForegroundColor DarkGray
        }
    }

    if (($out -join "`n") -notmatch 'COMPONENT_OK') {
        throw "$Name se nije pokrenuo."
    }
}

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ' EKSPERIMENT 06 - ICMP FLOOD' -ForegroundColor Cyan
Write-Host (" MODE: {0}" -f $Mode) -ForegroundColor Cyan
Write-Host (" CILJ: {0} ({1})" -f $TargetLabel,$TargetDataIp) -ForegroundColor Cyan
Write-Host (" TRAJANJE BURSTA: {0} s | PAUZA: {1} s" -f $FloodDurationSeconds,$SecondBurstDelaySeconds) -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

# --------------------------------------------------
# SSH
# --------------------------------------------------

$nodes = @(
    @('SERVER',$ServerIp),
    @('NIDS',$NidsIp),
    @('NAPADAC',$AttackerIp),
    @('AGENT-01',$Agent01Ip),
    @('AGENT-02',$Agent02Ip),
    @('AGENT-03',$Agent03Ip)
)

foreach ($n in $nodes) {
    $probe = Invoke-SshText -Ip $n[1] -Command 'echo SSH_OK' -AllowFailure | Select-Object -First 1

    if ($probe -ne 'SSH_OK') {
        throw "SSH nije spreman: $($n[0])"
    }

    Write-Host ("[SSH] {0} OK" -f $n[0]) -ForegroundColor DarkGray
}

# --------------------------------------------------
# response_mode
# --------------------------------------------------

Write-Host ''
Write-Host ("[CONFIG] response_mode -> {0}" -f $Mode) -ForegroundColor Yellow

$config = Invoke-SshText -Ip $ServerIp -Command "cd /home/user/diplomski/server && sed -i -E 's/^response_mode:.*/response_mode: $Mode/' server.conf && grep '^response_mode:' server.conf"
$config | ForEach-Object { Write-Host ("  {0}" -f $_) -ForegroundColor White }

# Broj redaka prije restarta koristimo samo da prepoznamo je li server pri
# pokretanju truncirao promet.log. Stvarni baseline marker postavlja se TEK
# nakon sto je novi SERVER/NIDS pokrenut, a prije pokretanja agenata.
$serverLinesBeforeRestart = Get-LineCount -Ip $ServerIp -Path $ServerLog
$baselineStart = 1

# --------------------------------------------------
# Clean + start
# --------------------------------------------------

Write-Host ''
Write-Host '[CLEAN] Cistim stare procese i DROP pravilo...' -ForegroundColor Yellow

Invoke-SshText -Ip $ServerIp -Command "pkill -f '[s]erver.sh' 2>/dev/null || true; echo OK" | Out-Null
Invoke-SshText -Ip $NidsIp -Command "sudo -n pkill -f '[n]ids.sh' 2>/dev/null || true; sudo -n pkill -f '[c]ontrol.sh' 2>/dev/null || true; echo OK" | Out-Null

foreach ($ip in @($Agent01Ip,$Agent02Ip,$Agent03Ip)) {
    Invoke-SshText -Ip $ip -Command "sudo -n pkill -f '[a]gent.sh' 2>/dev/null || true; echo OK" | Out-Null
}

Invoke-SshText -Ip $AttackerIp -Command "pkill -x ping 2>/dev/null || true; : > '$FloodLog'; : > '$FloodMeta'; : > '$PingRawLog'; echo OK" | Out-Null

Invoke-SshText -Ip $NidsIp -Command "while sudo -n iptables -C FORWARD -s $AttackerDataIp -m comment --comment diplomski-nids -j DROP 2>/dev/null; do sudo -n iptables -D FORWARD -s $AttackerDataIp -m comment --comment diplomski-nids -j DROP; done; echo FIREWALL_CLEAN" |
    ForEach-Object { Write-Host ("  {0}" -f $_) -ForegroundColor DarkGray }

Start-Sleep -Seconds 1

$serverCmd = "cd /home/user/diplomski/server; nohup bash ./server.sh >/tmp/exp06-server.log 2>&1 </dev/null & sleep 2; if pgrep -f '[s]erver.sh' >/dev/null; then echo COMPONENT_OK; else echo COMPONENT_FAIL; tail -n 20 /tmp/exp06-server.log; fi"
$nidsCmd   = "cd /home/user/diplomski/nids; nohup sudo -n bash ./nids.sh >/tmp/exp06-nids.log 2>&1 </dev/null & sleep 3; if sudo -n pgrep -f '[n]ids.sh' >/dev/null; then echo COMPONENT_OK; else echo COMPONENT_FAIL; tail -n 20 /tmp/exp06-nids.log; fi"
$agentCmd  = "cd /home/user/diplomski/agent; nohup sudo -n ./agent.sh >/tmp/exp06-agent.log 2>&1 </dev/null & sleep 3; if sudo -n pgrep -f '[a]gent.sh' >/dev/null; then echo COMPONENT_OK; else echo COMPONENT_FAIL; tail -n 20 /tmp/exp06-agent.log; fi"

Start-RealComponent -Name 'SERVER' -Ip $ServerIp -Command $serverCmd
Start-RealComponent -Name 'NIDS' -Ip $NidsIp -Command $nidsCmd

# VAŽNO: server.sh pri pokretanju moze isprazniti promet.log. Ako bismo
# baselineStart zapamtili prije restarta, mogao bi pokazivati na npr. redak
# 5000 iako novi log ima tek nekoliko redaka. Tada tail -n +5000 nikad ne
# vidi svjezi HEARTBEAT/PEER_STATE i baseline lazno istekne.
# Marker zato uzimamo iz NOVOG server procesa, neposredno prije agenata.
$serverLinesAfterRestart = Get-LineCount -Ip $ServerIp -Path $ServerLog
if ($serverLinesAfterRestart -lt $serverLinesBeforeRestart) {
    Write-Host ("[BASELINE MARKER] promet.log je resetiran: prije={0}, sada={1}" -f $serverLinesBeforeRestart,$serverLinesAfterRestart) -ForegroundColor DarkGray
}
$baselineStart = $serverLinesAfterRestart + 1
Write-Host ("[BASELINE MARKER] pratim svjeze SERVER zapise od retka {0}" -f $baselineStart) -ForegroundColor DarkGray

Start-RealComponent -Name 'AGENT-01' -Ip $Agent01Ip -Command $agentCmd
Start-RealComponent -Name 'AGENT-02' -Ip $Agent02Ip -Command $agentCmd
Start-RealComponent -Name 'AGENT-03' -Ip $Agent03Ip -Command $agentCmd

Write-Host '[OK] Stvarne komponente su pokrenute.' -ForegroundColor Green

Write-Host ''
Open-AllLiveLogWindows

# --------------------------------------------------
# Baseline
# Kod agent cilja ne cekamo slijepo 70 s, nego doista cekamo
# dok se u SERVER logu pojave HB + oba HEALTHY peer zapisa.
# --------------------------------------------------

if ($NeedHealthyAgentBaseline) {
    Write-Host ''
    Write-Host '[BASELINE] Cekam svjezi HEARTBEAT + 2x HEALTHY peer zapis...' -ForegroundColor Yellow

    $deadline = (Get-Date).AddSeconds($BaselineTimeoutSeconds)
    $hb = $null
    $p2 = $null
    $p3 = $null

    while ((Get-Date) -lt $deadline) {
        $hb = Get-LastMatch -Ip $ServerIp -Path $ServerLog -StartLine $baselineStart -Regex "\[HEARTBEAT\] HEARTBEAT agent-01( |$)"
        $p2 = Get-LastMatch -Ip $ServerIp -Path $ServerLog -StartLine $baselineStart -Regex "\[PEER_STATE\].*observer=agent-02.*target=agent-01.*state=HEALTHY"
        $p3 = Get-LastMatch -Ip $ServerIp -Path $ServerLog -StartLine $baselineStart -Regex "\[PEER_STATE\].*observer=agent-03.*target=agent-01.*state=HEALTHY"

        if ($hb -and $p2 -and $p3) { break }

        $missing = @()
        if (-not $hb) { $missing += 'HEARTBEAT' }
        if (-not $p2) { $missing += 'agent-02->agent-01 HEALTHY' }
        if (-not $p3) { $missing += 'agent-03->agent-01 HEALTHY' }

        Write-Host ("  cekam: {0}" -f ($missing -join ', ')) -ForegroundColor DarkGray
        Start-Sleep -Seconds $PollSeconds
    }

    if (-not $hb -or -not $p2 -or -not $p3) {
        Write-Host ''
        Write-Host '[DIJAGNOSTIKA - zadnjih 30 SERVER logova]' -ForegroundColor Yellow
        Invoke-SshText -Ip $ServerIp -Command "tail -n 30 '$ServerLog'" -AllowFailure |
            ForEach-Object { Write-Host $_ -ForegroundColor White }
        throw 'Nije dobiven potpuni zdravi baseline unutar 150 s.'
    }

    Write-Host '[BASELINE OK]' -ForegroundColor Green
    Write-Host $hb -ForegroundColor White
    Write-Host $p2 -ForegroundColor White
    Write-Host $p3 -ForegroundColor White
}
else {
    Write-Host ''
    Write-Host '[BASELINE] Cilj je SERVER; heartbeat/peer baseline nije potreban za server-target granu.' -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}

# Mjerenje pocinje tek nakon baselinea.
$serverStart = (Get-LineCount -Ip $ServerIp -Path $ServerLog) + 1
$nidsStart   = (Get-LineCount -Ip $NidsIp -Path $NidsLog) + 1
$agentStart  = (Get-LineCount -Ip $Agent01Ip -Path $AgentLog) + 1

Write-Host ''
Write-Host '[OCEKIVANJE]' -ForegroundColor Cyan
Write-Host '  prvi alert -> ALERT_ONLY + potvrda; ponovljeni alert -> BLOCK' -ForegroundColor White

# --------------------------------------------------
# Dva kontrolirana ICMP bursta
# --------------------------------------------------

$PacketCount = $PacketsPerSecond * $FloodDurationSeconds
$PingIntervalSeconds = 1.0 / [double]$PacketsPerSecond
$PingIntervalText = $PingIntervalSeconds.ToString('0.###',[System.Globalization.CultureInfo]::InvariantCulture)

$Burst1Meta = '/tmp/diplomski-exp06-burst1-meta.log'
$Burst2Meta = '/tmp/diplomski-exp06-burst2-meta.log'
$Burst1Raw  = '/tmp/diplomski-exp06-burst1-ping.log'
$Burst2Raw  = '/tmp/diplomski-exp06-burst2-ping.log'

Invoke-SshText -Ip $AttackerIp -Command "pkill -x ping 2>/dev/null || true; : > '$FloodLog'; : > '$Burst1Meta'; : > '$Burst2Meta'; : > '$Burst1Raw'; : > '$Burst2Raw'; echo READY" | Out-Null

function Invoke-IcmpBurst {
    param(
        [ValidateRange(1,2)]
        [int]$BurstNumber,
        [string]$MetaPath,
        [string]$RawPath
    )

    Write-Host ''
    Write-Host ("[ICMP] BURST {0} -> {1}" -f $BurstNumber,$TargetDataIp) -ForegroundColor Red
    Write-Host ("       rate≈{0} pps | interval={1}s | trajanje≈{2}s | paketa={3}" -f $PacketsPerSecond,$PingIntervalText,$FloodDurationSeconds,$PacketCount) -ForegroundColor Red

    $cmd = @'
set +e;
burst=__BURST__;
interval="__INTERVAL__";
count=__COUNT__;
target="__TARGET__";
flood_log="__FLOOD_LOG__";
meta="__META__";
raw="__RAW__";

: > "$meta";
: > "$raw";
start="$(date '+%Y-%m-%d %H:%M:%S.%3N')";
echo "ATTACK_START=$start" > "$meta";

echo "==================================================" >> "$flood_log";
echo "[PING] BURST $burst START target=$target interval=${interval}s count=$count" >> "$flood_log";
echo "==================================================" >> "$flood_log";

ping -n -i "$interval" -W 1 -c "$count" "$target" > "$raw" 2>&1;
rc=$?;
end="$(date '+%Y-%m-%d %H:%M:%S.%3N')";
echo "ATTACK_END=$end" >> "$meta";
echo "PING_RC=$rc" >> "$meta";

echo "--------------------------------------------------" >> "$flood_log";
tail -n 12 "$raw" >> "$flood_log" 2>/dev/null || true;
echo "[PING] BURST $burst END rc=$rc" >> "$flood_log";
echo "==================================================" >> "$flood_log";
exit 0;
'@

    $cmd = $cmd.Replace('__BURST__',[string]$BurstNumber)
    $cmd = $cmd.Replace('__INTERVAL__',$PingIntervalText)
    $cmd = $cmd.Replace('__COUNT__',[string]$PacketCount)
    $cmd = $cmd.Replace('__TARGET__',$TargetDataIp)
    $cmd = $cmd.Replace('__FLOOD_LOG__',$FloodLog)
    $cmd = $cmd.Replace('__META__',$MetaPath)
    $cmd = $cmd.Replace('__RAW__',$RawPath)
    $cmd = $cmd.Replace("`r","")

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($cmd)
    $b64 = [Convert]::ToBase64String($bytes)
    $remote = "printf '%s' '$b64' | base64 -d | /bin/bash"

    Invoke-SshText -Ip $AttackerIp -Command $remote | Out-Null

    Write-Host ("===== BURST {0} PING REZULTAT =====" -f $BurstNumber) -ForegroundColor Cyan
    Invoke-SshText -Ip $AttackerIp -Command "tail -n 12 '$RawPath' 2>/dev/null || true" -AllowFailure |
        ForEach-Object { Write-Host $_ -ForegroundColor White }
}

function Get-BurstStats {
    param([string]$MetaPath,[string]$RawPath)

    $metaLines = Invoke-SshText -Ip $AttackerIp -Command "cat '$MetaPath' 2>/dev/null || true" -AllowFailure
    $s = $null
    $e = $null
    foreach ($line in $metaLines) {
        if ($line -match '^ATTACK_START=(.+)$') { $s = Get-PlainTime $Matches[1] }
        if ($line -match '^ATTACK_END=(.+)$')   { $e = Get-PlainTime $Matches[1] }
    }

    $summary = Invoke-SshText -Ip $AttackerIp -Command "grep -E 'packets transmitted' '$RawPath' | tail -n 1 || true" -AllowFailure | Select-Object -First 1
    $rtt = Invoke-SshText -Ip $AttackerIp -Command "grep -E '^(rtt|round-trip) ' '$RawPath' | tail -n 1 || true" -AllowFailure | Select-Object -First 1

    $sent = $null; $received = $null; $lost = $null; $loss = $null
    if ($summary -and $summary -match '(\d+) packets transmitted,\s*(\d+) received,.*?([0-9.]+)% packet loss') {
        $sent = [int]$Matches[1]
        $received = [int]$Matches[2]
        $lost = $sent - $received
        $loss = [double]::Parse($Matches[3],[System.Globalization.CultureInfo]::InvariantCulture)
    }

    return [pscustomobject]@{
        Start = $s
        End = $e
        Duration = (Delta $s $e)
        Sent = $sent
        Received = $received
        Lost = $lost
        LossPercent = $loss
        Summary = $summary
        Rtt = $rtt
    }
}

Write-Host ''
Write-Host '[FAZA 1] Prvi burst: ocekuje se prvi NIDS alert i ALERT_ONLY.' -ForegroundColor Cyan
Invoke-IcmpBurst -BurstNumber 1 -MetaPath $Burst1Meta -RawPath $Burst1Raw

$alertRegex = "\[NIDS_ALERT\].*type=ICMP_FLOOD.*src=$([regex]::Escape($AttackerDataIp)).*dst=$([regex]::Escape($TargetDataIp))"
$nidsAlert1 = Wait-ForNthMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $alertRegex -N 1 -TimeoutSeconds 10
$serverAlert1 = Wait-ForNthMatch -Ip $ServerIp -Path $ServerLog -StartLine $serverStart -Regex $alertRegex -N 1 -TimeoutSeconds 10

if (-not $nidsAlert1 -or -not $serverAlert1) {
    throw 'Prvi burst nije proizveo ocekivani NIDS/server alert. Run se prekida prije drugog bursta.'
}

$firstDecision = Wait-ForNthMatch -Ip $ServerIp -Path $ServerLog -StartLine $serverStart -Regex "\[DECISION\].*src=$([regex]::Escape($AttackerDataIp)).*dst=$([regex]::Escape($TargetDataIp))" -N 1 -TimeoutSeconds 10

Write-Host '[FAZA 1 OK] Prvi alert je evidentiran.' -ForegroundColor Green
Write-Host $nidsAlert1 -ForegroundColor DarkGray
if ($firstDecision) { Write-Host $firstDecision -ForegroundColor DarkGray }

Write-Host ''
Write-Host ("[PAUZA] {0} s prije drugog bursta. NIDS cooldown=10 s, server repeat window=30 s." -f $SecondBurstDelaySeconds) -ForegroundColor Yellow
Start-Sleep -Seconds $SecondBurstDelaySeconds

Write-Host '[FAZA 2] Drugi burst: ocekuje se drugi alert i BLOCK.' -ForegroundColor Cyan
Invoke-IcmpBurst -BurstNumber 2 -MetaPath $Burst2Meta -RawPath $Burst2Raw

$nidsAlert2 = Wait-ForNthMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $alertRegex -N 2 -TimeoutSeconds 10
$serverAlert2 = Wait-ForNthMatch -Ip $ServerIp -Path $ServerLog -StartLine $serverStart -Regex $alertRegex -N 2 -TimeoutSeconds 10
$blockDecision = Wait-ForNthMatch -Ip $ServerIp -Path $ServerLog -StartLine $serverStart -Regex "\[DECISION\].*action=BLOCK.*src=$([regex]::Escape($AttackerDataIp)).*dst=$([regex]::Escape($TargetDataIp))" -N 1 -TimeoutSeconds 10
$blockAction = Wait-ForNthMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex "\[BLOCK_ACTION\].*status=SUCCESS.*src_ip=$([regex]::Escape($AttackerDataIp))" -N 1 -TimeoutSeconds 10
$blockResult = Wait-ForNthMatch -Ip $ServerIp -Path $ServerLog -StartLine $serverStart -Regex "\[BLOCK_RESULT\].*src=$([regex]::Escape($AttackerDataIp)).*status=SUCCESS" -N 1 -TimeoutSeconds 10

$burst1 = Get-BurstStats -MetaPath $Burst1Meta -RawPath $Burst1Raw
$burst2 = Get-BurstStats -MetaPath $Burst2Meta -RawPath $Burst2Raw

# --------------------------------------------------
# Relevantni logovi i metrike
# --------------------------------------------------

$confirmationStart = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $serverStart -Regex "\[ACTION\].*incident_id=.*src=$([regex]::Escape($AttackerDataIp)).*dst=$([regex]::Escape($TargetDataIp)).*target=agent-01"
$confirmation = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $serverStart -Regex "\[CORRELATION\].*state=(HEALTHY_CONFIRMED|IMPACT_CONFIRMED|UNCERTAIN).*host=agent-01.*dst=$([regex]::Escape($TargetDataIp)).*src=$([regex]::Escape($AttackerDataIp))"

$peerImpact = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $serverStart -Regex "\[PEER_STATE\].*target=agent-01.*state=(DEGRADED|UNREACHABLE)"
$failure = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $serverStart -Regex "\[(CORRELATION|RECOVERY)\].*(AGENT_FAILURE|NODE_FAILURE|NODE_STATE_UNCERTAIN|RECOVERY).*agent-01"

$alertCountRaw = Invoke-SshText -Ip $ServerIp -Command "tail -n +$serverStart '$ServerLog' | grep -E '$alertRegex' | wc -l" -AllowFailure | Select-Object -Last 1
$alertCount = 0
if ($alertCountRaw -and $alertCountRaw.Trim() -match '^\d+$') { $alertCount = [int]$alertCountRaw.Trim() }

$burst1ToNids = Delta $burst1.Start (Get-LogTime $nidsAlert1)
$firstNidsToServer = Delta (Get-LogTime $nidsAlert1) (Get-LogTime $serverAlert1)
$firstServerToDecision = Delta (Get-LogTime $serverAlert1) (Get-LogTime $firstDecision)
$confirmationDuration = Delta (Get-LogTime $confirmationStart) (Get-LogTime $confirmation)
$alertSpacing = Delta (Get-LogTime $nidsAlert1) (Get-LogTime $nidsAlert2)
$secondNidsToServer = Delta (Get-LogTime $nidsAlert2) (Get-LogTime $serverAlert2)
$secondServerToBlockDecision = Delta (Get-LogTime $serverAlert2) (Get-LogTime $blockDecision)
$secondNidsToBlockAction = Delta (Get-LogTime $nidsAlert2) (Get-LogTime $blockAction)
$burst2ToBlockAction = Delta $burst2.Start (Get-LogTime $blockAction)
$blockDecisionToResult = Delta (Get-LogTime $blockDecision) (Get-LogTime $blockResult)

$firewallRule = Invoke-SshText -Ip $NidsIp -Command "if sudo -n iptables -C FORWARD -s $AttackerDataIp -m comment --comment diplomski-nids -j DROP 2>/dev/null; then echo PRESENT; else echo MISSING; fi" -AllowFailure | Select-Object -Last 1
$firewallRuleVerified = ($firewallRule -eq 'PRESENT')

$validationIssues = @()
if ($alertCount -lt 2) { $validationIssues += "Ocekivana su barem 2 server NIDS alerta, dobiveno: $alertCount." }
if (-not $firstDecision -or $firstDecision -notmatch 'action=ALERT_ONLY') { $validationIssues += 'Prva odluka nije ALERT_ONLY.' }
if (-not $confirmation -or $confirmation -notmatch 'state=HEALTHY_CONFIRMED') { $validationIssues += 'Nije dobiven HEALTHY_CONFIRMED nakon prvog alerta.' }
if (-not $nidsAlert2 -or -not $serverAlert2) { $validationIssues += 'Nedostaje drugi NIDS/server alert.' }
if (-not $blockDecision) { $validationIssues += 'Nedostaje BLOCK odluka nakon drugog alerta.' }
if (-not $blockAction) { $validationIssues += 'Nedostaje uspjesan BLOCK_ACTION.' }
if (-not $firewallRuleVerified) { $validationIssues += 'DROP pravilo nije pronadeno u FORWARD lancu.' }
if ($peerImpact) { $validationIssues += 'Zdravi baseline je tijekom testa pokazao DEGRADED/UNREACHABLE peer stanje.' }
if ($failure) { $validationIssues += 'Tijekom testa pojavio se failure/recovery dogadaj.' }
if ($null -ne $alertSpacing -and ($alertSpacing -lt 10 -or $alertSpacing -gt 30)) { $validationIssues += "Razmak alarma $alertSpacing s nije u ocekivanom intervalu 10-30 s." }
$validRun = ($validationIssues.Count -eq 0)
$validationNote = if ($validRun) { 'OK' } else { $validationIssues -join ' | ' }

# --------------------------------------------------
# Rezultat
# --------------------------------------------------

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ' REZULTAT - CORRELATED HEALTHY AGENT' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ("[BURST 1] {0}" -f $burst1.Summary) -ForegroundColor White
Write-Host ("[BURST 2] {0}" -f $burst2.Summary) -ForegroundColor White
if ($null -ne $burst1.LossPercent) { Write-Host ("[LOSS 1] {0:N2}%" -f $burst1.LossPercent) -ForegroundColor White }
if ($null -ne $burst2.LossPercent) { Write-Host ("[LOSS 2] {0:N2}%" -f $burst2.LossPercent) -ForegroundColor White }

if ($null -ne $burst1ToNids) { Write-Host ("[M1] burst1 start -> prvi NIDS_ALERT = {0:N3} s" -f $burst1ToNids) -ForegroundColor Green }
if ($null -ne $firstNidsToServer) { Write-Host ("[M2] prvi NIDS_ALERT -> server alert = {0:N3} s" -f $firstNidsToServer) -ForegroundColor Green }
if ($null -ne $firstServerToDecision) { Write-Host ("[M3] prvi server alert -> ALERT_ONLY = {0:N3} s" -f $firstServerToDecision) -ForegroundColor Green }
if ($null -ne $confirmationDuration) { Write-Host ("[M4] distribuirana potvrda = {0:N3} s" -f $confirmationDuration) -ForegroundColor Green }
if ($null -ne $alertSpacing) { Write-Host ("[M5] razmak prvi -> drugi NIDS alert = {0:N3} s" -f $alertSpacing) -ForegroundColor Green }
if ($null -ne $secondServerToBlockDecision) { Write-Host ("[M6] drugi server alert -> BLOCK odluka = {0:N3} s" -f $secondServerToBlockDecision) -ForegroundColor Green }
if ($null -ne $secondNidsToBlockAction) { Write-Host ("[M7] drugi NIDS alert -> BLOCK_ACTION = {0:N3} s" -f $secondNidsToBlockAction) -ForegroundColor Green }
if ($null -ne $burst2ToBlockAction) { Write-Host ("[M8] burst2 start -> BLOCK_ACTION = {0:N3} s" -f $burst2ToBlockAction) -ForegroundColor Green }
if ($null -ne $blockDecisionToResult) { Write-Host ("[M9] BLOCK odluka -> BLOCK_RESULT = {0:N3} s" -f $blockDecisionToResult) -ForegroundColor Green }

Write-Host ("[INFO] server alerts={0}" -f $alertCount) -ForegroundColor White
Write-Host ("[FIREWALL] DROP rule = {0}" -f $(if ($firewallRuleVerified) { 'PRESENT' } else { 'MISSING' })) -ForegroundColor $(if ($firewallRuleVerified) { 'Green' } else { 'Red' })
if ($validRun) {
    Write-Host '[VALIDACIJA] RUN OK: prvi alert ALERT_ONLY + HEALTHY_CONFIRMED, drugi alert BLOCK.' -ForegroundColor Green
}
else {
    Write-Host ("[VALIDACIJA] RUN NIJE VALJAN: {0}" -f $validationNote) -ForegroundColor Red
}

Write-Host ''
Write-Host '[DOKAZ - SERVER]' -ForegroundColor Yellow
Invoke-SshText -Ip $ServerIp -Command "tail -n +$serverStart '$ServerLog' | grep -E '\[(NIDS_ALERT|CORRELATION|DECISION|ACTION|BLOCK_RESULT|BLOCK_STATE|PEER_STATE|HEARTBEAT|RECOVERY)\]' | tail -n 180" -AllowFailure |
    ForEach-Object { Write-Host $_ -ForegroundColor White }

Write-Host ''
Write-Host '[DOKAZ - NIDS]' -ForegroundColor Yellow
Invoke-SshText -Ip $NidsIp -Command "tail -n +$nidsStart '$NidsLog' | grep -E '\[(NIDS_ALERT|FAILSAFE|FAILSAFE_CHECK|BLOCK_REQUEST|BLOCK_ACTION|BLOCK_EXPIRED|CONTROL_RESULT|WARNING|ERROR)\]' | tail -n 100" -AllowFailure |
    ForEach-Object { Write-Host $_ -ForegroundColor White }

if ($TargetKind -eq 'agent') {
    Write-Host ''
    Write-Host '[DOKAZ - AGENT-01]' -ForegroundColor Yellow
    Invoke-SshText -Ip $Agent01Ip -Command "tail -n +$agentStart '$AgentLog' | tail -n 60" -AllowFailure |
        ForEach-Object { Write-Host $_ -ForegroundColor White }
}

# --------------------------------------------------
# CSV
# --------------------------------------------------

$resultsDir = Join-Path $PSScriptRoot 'rezultati'
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }
$csv = Join-Path $resultsDir '06-icmp-agent-correlated.csv'

[pscustomobject]@{
    run_time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    mode = $Mode
    attack_tool = 'ping'
    target = $TargetLabel
    target_ip = $TargetDataIp
    burst_duration_requested_s = $FloodDurationSeconds
    packets_per_second_requested = $PacketsPerSecond
    ping_interval_s = $PingIntervalSeconds
    packets_per_burst_requested = $PacketCount
    second_burst_delay_s = $SecondBurstDelaySeconds
    burst1_duration_actual_s = $burst1.Duration
    burst1_packets_sent = $burst1.Sent
    burst1_packets_received = $burst1.Received
    burst1_packet_loss_percent = $burst1.LossPercent
    burst2_duration_actual_s = $burst2.Duration
    burst2_packets_sent = $burst2.Sent
    burst2_packets_received = $burst2.Received
    burst2_packet_loss_percent = $burst2.LossPercent
    server_alerts = $alertCount
    burst1_start_to_nids_alert_s = $burst1ToNids
    first_nids_to_server_alert_s = $firstNidsToServer
    first_server_alert_to_decision_s = $firstServerToDecision
    distributed_confirmation_s = $confirmationDuration
    nids_alert1_to_alert2_s = $alertSpacing
    second_nids_to_server_alert_s = $secondNidsToServer
    second_server_alert_to_block_decision_s = $secondServerToBlockDecision
    second_nids_alert_to_block_action_s = $secondNidsToBlockAction
    burst2_start_to_block_action_s = $burst2ToBlockAction
    block_decision_to_block_result_s = $blockDecisionToResult
    first_decision_line = $firstDecision
    confirmation_line = $confirmation
    block_decision_line = $blockDecision
    firewall_rule_verified = $firewallRuleVerified
    valid_run = $validRun
    validation_note = $validationNote
} | Export-Csv -Path $csv -NoTypeInformation -Append -Encoding UTF8

Write-Host ''
Write-Host ("[CSV] {0}" -f $csv) -ForegroundColor Green

# Ocisti blokadu odmah nakon prikupljanja rezultata da sljedeci run ne ceka TTL.
Invoke-SshText -Ip $NidsIp -Command "while sudo -n iptables -C FORWARD -s $AttackerDataIp -m comment --comment diplomski-nids -j DROP 2>/dev/null; do sudo -n iptables -D FORWARD -s $AttackerDataIp -m comment --comment diplomski-nids -j DROP; done; echo FIREWALL_CLEAN" -AllowFailure |
    ForEach-Object { Write-Host ("[CLEANUP] {0}" -f $_) -ForegroundColor DarkGray }

Write-Host 'Eksperiment zavrsen.' -ForegroundColor Green