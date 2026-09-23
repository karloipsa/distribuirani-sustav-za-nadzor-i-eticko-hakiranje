param(
    # Kontrolirani ICMP burst. Zadano 20 pps tijekom 3 s => 60 paketa.
    [ValidateRange(5,50)]
    [int]$PacketsPerSecond = 20,

    [ValidateRange(1,10)]
    [int]$FloodDurationSeconds = 3,

    # Ove vrijednosti moraju odgovarati nids.conf.
    [ValidateRange(10,300)]
    [int]$EmergencyBlockTtl = 60,

    [ValidateRange(1,5)]
    [int]$ServerCheckRetries = 2,

    [ValidateRange(0,5)]
    [int]$ServerCheckWaitSeconds = 1,

    # Koliko dugo nakon napada cekamo fail-safe EMERGENCY_BLOCK_ACTION.
    [ValidateRange(5,60)]
    [int]$FailSafeEventTimeoutSeconds = 20,

    # Dodatno vrijeme uz TTL za EMERGENCY_BLOCK_EXPIRED i provjeru uklanjanja pravila.
    [ValidateRange(10,60)]
    [int]$ExpiryGraceSeconds = 25
)

$ErrorActionPreference = 'Stop'

$Mode = 'correlated'
$Scenario = 'icmp_failsafe_server_unavailable'
$TargetKind = 'server'
$TargetDataIp = '192.168.100.1'
$TargetLabel = 'server'
$ServerServicePort = 5000
$NidsControlPort = 5001

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

$FloodLog   = '/tmp/diplomski-exp08-failsafe-flood.log'
$FloodMeta  = '/tmp/diplomski-exp08-failsafe-flood-meta.log'
$PingRawLog = '/tmp/diplomski-exp08-failsafe-ping-raw.log'

$BaselineTimeoutSeconds = 150
$PollSeconds = 5
$EventPollMilliseconds = 250

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

$Exp08FontSize = 11
$Exp08BufferWidth = 190

if (-not ('Exp08LabWindowTools' -as [type])) {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class Exp08LabWindowTools
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

function Start-Exp08Window {
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

    $existingHandle = [Exp08LabWindowTools]::FindWindowContaining($Title)

    if ($existingHandle -ne [IntPtr]::Zero) {
        Write-Host ("[PROZOR] Vec otvoren: {0}" -f $Title) -ForegroundColor DarkGray
        return
    }

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

public static class Exp08ConsoleFont
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
    [Exp08ConsoleFont]::SetFont(
        $Exp08FontSize,
        'Cascadia Mono'
    )
}
catch {}

try {
    `$buffer = `$Host.UI.RawUI.BufferSize
    `$buffer.Width = $Exp08BufferWidth

    if (`$buffer.Height -lt 3000) {
        `$buffer.Height = 3000
    }

    `$Host.UI.RawUI.BufferSize = `$buffer
}
catch {}

Write-Host '=================================================='
Write-Host ' EXPERIMENT 08 - SERVER FAIL-SAFE - LIVE'
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

        $handle = [Exp08LabWindowTools]::FindWindowContaining(
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

    [Exp08LabWindowTools]::MoveWindow(
        $handle,
        $X,
        $Y,
        $Width,
        $Height,
        $true
    ) | Out-Null

    Start-Sleep -Milliseconds 300

    [Exp08LabWindowTools]::MoveWindow(
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

    Start-Exp08Window `
        -Title 'EXP08-SERVER' `
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

    Start-Exp08Window `
        -Title 'EXP08-NIDS' `
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

    Start-Exp08Window `
        -Title 'EXP08-NAPADAC' `
        -Ip $AttackerIp `
        -Color 'Red' `
        -X ($area.Left + (2 * $cellWidth)) `
        -Y $area.Top `
        -Width $cellWidth `
        -Height $cellHeight `
        -RemoteCommand @'
touch /tmp/diplomski-exp08-failsafe-flood.log

echo
echo "[LOG] /tmp/diplomski-exp08-failsafe-flood.log"
echo "--------------------------------------------------"

tail -n 0 -F /tmp/diplomski-exp08-failsafe-flood.log

echo
echo "[SHELL] Ostajes spojen na NAPADAC."
export TERM=xterm-256color
export PS1='\[\e[91m\][\u@\h \W]\$ '
printf '\033[91m'
exec bash --noprofile --norc -i </dev/tty >/dev/tty 2>/dev/tty
'@

    Start-Exp08Window `
        -Title 'EXP08-AGENT-01' `
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

    Start-Exp08Window `
        -Title 'EXP08-AGENT-02' `
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

    Start-Exp08Window `
        -Title 'EXP08-AGENT-03' `
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

function Wait-RemoteLogLine {
    param(
        [string]$Ip,
        [string]$Path,
        [int]$StartLine,
        [string]$Regex,
        [int]$TimeoutSeconds = 20,
        [int]$PollMilliseconds = 250
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        $line = Get-FirstMatch -Ip $Ip -Path $Path -StartLine $StartLine -Regex $Regex
        if ($line) { return $line }

        Start-Sleep -Milliseconds $PollMilliseconds
    }
    while ((Get-Date) -lt $deadline)

    return $null
}

function Get-RemoteMatchCount {
    param(
        [string]$Ip,
        [string]$Path,
        [int]$StartLine,
        [string]$Regex
    )

    $raw = Invoke-SshText `
        -Ip $Ip `
        -Command "tail -n +$StartLine '$Path' 2>/dev/null | grep -E '$Regex' | wc -l" `
        -AllowFailure |
        Select-Object -Last 1

    if ($raw -and $raw.Trim() -match '^\d+$') {
        return [int]$raw.Trim()
    }

    return 0
}

function Get-FirewallRuleState {
    param([string]$SourceIp)

    # Jednolinijska remote provjera namjerno izbjegava multiline Bash
    # preko Windows ssh.exe. Uvijek mora vratiti tocno jedno stanje.
    $cmd = "if sudo -n iptables -C FORWARD -s '$SourceIp' -m comment --comment diplomski-nids-emergency -j DROP 2>/dev/null; then echo PRESENT_EMERGENCY; elif sudo -n iptables -C FORWARD -s '$SourceIp' -m comment --comment diplomski-nids -j DROP 2>/dev/null; then echo PRESENT_NORMAL; elif sudo -n iptables -S FORWARD 2>/dev/null | grep -F -- '-s $SourceIp/32' | grep -q -- '-j DROP'; then echo PRESENT_OTHER; else echo MISSING; fi"

    $state = Invoke-SshText -Ip $NidsIp -Command $cmd -AllowFailure |
        Where-Object { $_ -match '^(PRESENT_EMERGENCY|PRESENT_NORMAL|PRESENT_OTHER|MISSING)$' } |
        Select-Object -Last 1

    if ([string]::IsNullOrWhiteSpace($state)) {
        Write-Host '[FIREWALL PROBE ERROR] Nije dobiveno valjano stanje iptables pravila.' -ForegroundColor Red
        return 'UNKNOWN'
    }

    return $state.Trim()
}

function Invoke-UniversalClean {
    param(
        [string]$Name,
        [string]$Ip,
        [string]$Dir
    )

    Write-Host ("[CLEAN:{0}] ./clean.sh" -f $Name) -ForegroundColor DarkYellow

    $cmd = "cd '$Dir' && sudo -n bash ./clean.sh"

    $out = Invoke-SshText `
        -Ip $Ip `
        -Command $cmd `
        -AllowFailure

    if ($out) {
        $important = @(
            $out | Where-Object {
                $_ -match 'Gasim:|Nema vise|UPOZORENJE:|nema nasih pravila|Gotovo'
            }
        )

        if ($important.Count -eq 0) {
            $important = @($out | Select-Object -Last 8)
        }

        $important | ForEach-Object {
            if ($_ -and $_.Trim()) {
                Write-Host ("  {0}" -f $_) -ForegroundColor DarkGray
            }
        }
    }

    return $true
}

function Invoke-FullLabClean {
    param(
        [string]$Phase = 'CLEAN'
    )

    Write-Host ("[{0}] Univerzalni clean.sh na SERVER/NIDS/agentima..." -f $Phase) -ForegroundColor Yellow

    Invoke-UniversalClean -Name 'SERVER'   -Ip $ServerIp  -Dir '/home/user/diplomski/server' | Out-Null
    Invoke-UniversalClean -Name 'NIDS'     -Ip $NidsIp    -Dir '/home/user/diplomski/nids'   | Out-Null
    Invoke-UniversalClean -Name 'AGENT-01' -Ip $Agent01Ip -Dir '/home/user/diplomski/agent'  | Out-Null
    Invoke-UniversalClean -Name 'AGENT-02' -Ip $Agent02Ip -Dir '/home/user/diplomski/agent'  | Out-Null
    Invoke-UniversalClean -Name 'AGENT-03' -Ip $Agent03Ip -Dir '/home/user/diplomski/agent'  | Out-Null

    # Attacker nema clean.sh. Cistimo samo generatore i privremene datoteke
    # koje koristi ovaj eksperiment.
    Write-Host ("[{0}] ATTACKER: gasim samo ping/nping i brisem exp08 tmp datoteke..." -f $Phase) -ForegroundColor DarkYellow

    Invoke-SshText `
        -Ip $AttackerIp `
        -Command "pkill -x ping 2>/dev/null || true; pkill -x nping 2>/dev/null || true; : > '$FloodLog'; rm -f '$FloodMeta' '$PingRawLog'; echo ATTACKER_CLEAN" `
        -AllowFailure |
        ForEach-Object {
            if ($_ -and $_.Trim()) {
                Write-Host ("  {0}" -f $_) -ForegroundColor DarkGray
            }
        }

    return $true
}

function Test-NidsControlHealthy {
    $probe = Invoke-SshText `
        -Ip $NidsIp `
        -Command "if pgrep -f '[n]ids.sh' >/dev/null 2>&1 && pgrep -f '[c]ontrol.sh' >/dev/null 2>&1 && ss -lnt 2>/dev/null | awk '{print `$4}' | grep -qE '(:|\])5001`$'; then echo NIDS_CONTROL_OK; else echo NIDS_CONTROL_FAIL; fi" `
        -AllowFailure |
        Select-Object -Last 1

    return ($probe -eq 'NIDS_CONTROL_OK')
}

function Remove-ExperimentFirewallRules {
    $cmd = @'
for comment in diplomski-nids diplomski-nids-emergency; do
    while sudo -n iptables -C FORWARD -s '__SOURCE_IP__' -m comment --comment "$comment" -j DROP 2>/dev/null; do
        sudo -n iptables -D FORWARD -s '__SOURCE_IP__' -m comment --comment "$comment" -j DROP 2>/dev/null || break
    done
done
echo FIREWALL_CLEAN
'@

    $cmd = $cmd.Replace('__SOURCE_IP__', $AttackerDataIp)
    Invoke-SshText -Ip $NidsIp -Command $cmd -AllowFailure
}

function Test-ServerProtectedPort {
    $x = Invoke-SshText `
        -Ip $NidsIp `
        -Command "if ncat -z -w 2 '$TargetDataIp' '$ServerServicePort' >/dev/null 2>&1; then echo REACHABLE; else echo UNREACHABLE; fi" `
        -AllowFailure |
        Select-Object -Last 1

    return ($x -eq 'REACHABLE')
}

function Ensure-ServerRunning {
    $probe = Invoke-SshText `
        -Ip $ServerIp `
        -Command "if pgrep -f '[s]erver.sh' >/dev/null; then echo SERVER_RUNNING; else echo SERVER_STOPPED; fi" `
        -AllowFailure |
        Select-Object -Last 1

    if ($probe -eq 'SERVER_RUNNING') {
        return $true
    }

    Write-Host '[RECOVERY] Ponovno pokrecem server.sh...' -ForegroundColor Yellow

    $cmd = "cd /home/user/diplomski/server; nohup bash ./server.sh >/tmp/exp08-server-recovery.log 2>&1 </dev/null & sleep 3; if pgrep -f '[s]erver.sh' >/dev/null; then echo COMPONENT_OK; else echo COMPONENT_FAIL; tail -n 30 /tmp/exp08-server-recovery.log; fi"

    $out = Invoke-SshText -Ip $ServerIp -Command $cmd -AllowFailure
    $out | ForEach-Object {
        if ($_ -and $_.Trim()) {
            Write-Host ("[RECOVERY] {0}" -f $_) -ForegroundColor DarkGray
        }
    }

    if (($out -join "`n") -notmatch 'COMPONENT_OK') {
        Write-Host '[RECOVERY] server.sh nije ponovno pokrenut.' -ForegroundColor Red
        return $false
    }

    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (Test-ServerProtectedPort) {
            Write-Host '[RECOVERY] server.sh radi i port 5000 je ponovno dostupan.' -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds 1
    }

    Write-Host '[RECOVERY] server.sh radi, ali port 5000 nije postao dostupan unutar 20 s.' -ForegroundColor Yellow
    return $false
}

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ' EKSPERIMENT 08 - ICMP FLOOD / SERVER FAIL-SAFE' -ForegroundColor Cyan
Write-Host (" MODE: {0}" -f $Mode) -ForegroundColor Cyan
Write-Host (" CILJ: {0} ({1}:{2})" -f $TargetLabel,$TargetDataIp,$ServerServicePort) -ForegroundColor Cyan
Write-Host (" NAPAD: {0} pps | {1} s | oko {2} paketa" -f $PacketsPerSecond,$FloodDurationSeconds,($PacketsPerSecond*$FloodDurationSeconds)) -ForegroundColor Cyan
Write-Host (" FAIL-SAFE: ENABLE=1 TTL={0}s RETRIES={1} WAIT={2}s" -f $EmergencyBlockTtl,$ServerCheckRetries,$ServerCheckWaitSeconds) -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

# --------------------------------------------------
# Stanje rezultata. Inicijalizirano unaprijed kako bi se i neuspjeli
# run mogao korektno zapisati u CSV i ocistiti laboratorij.
# --------------------------------------------------

$fatalError = $null
$serverStoppedByExperiment = $false
$serverProcessStopped = $false
$serverPortInitiallyReachable = $false
$serverPortAfterStopReachable = $null
$serverRecoveredAfterRun = $false
$preRunCleanCompleted = $false
$postRunCleanCompleted = $false
$nidsControlAliveAfterServerStop = $false

$controlSupportsEmergency = $false
$controlSupportsExpiry = $false

$baselineHeartbeatLine = $null
$baselinePeer02Line = $null
$baselinePeer03Line = $null

$attackStartText = $null
$attackEndText = $null
$attackStartTs = $null
$attackEndTs = $null
$attackDurationActual = $null
$packetsSent = $null
$packetsReceived = $null
$packetsLost = $null
$packetLossPercent = $null

$nidsAlertLine = $null
$failsafeDeliveryFailedLine = $null
$failsafeEmergencyBlockLine = $null
$emergencyBlockRequestLine = $null
$blockActionLine = $null
$blockExpiredLine = $null
$blockExpireFailLine = $null
$unknownEmergencyRequestLine = $null

$failsafeCheckCount = 0
$firewallRuleAfterBlock = 'NOT_CHECKED'
$firewallRuleAfterExpiry = 'NOT_CHECKED'

$attackStartToNidsAlert = $null
$nidsAlertToFailsafeBlock = $null
$failsafeBlockToBlockAction = $null
$attackStartToBlockAction = $null
$blockActionToExpiry = $null

$failsafeBlockVerified = $false
$blockExpiredVerified = $false
$firewallAfterExpiryCleared = $false
$validRun = $false
$validationNote = $null

$PacketCount = $PacketsPerSecond * $FloodDurationSeconds
$PingIntervalSeconds = 1.0 / [double]$PacketsPerSecond
$PingIntervalText = $PingIntervalSeconds.ToString(
    '0.###',
    [System.Globalization.CultureInfo]::InvariantCulture
)

# Stvarni markeri ovog runa.
$serverStart = 1
$nidsStart = 1
$agent01Start = 1
$agent02Start = 1
$agent03Start = 1

try {
    # --------------------------------------------------
    # SSH preflight
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
        $probe = Invoke-SshText -Ip $n[1] -Command 'echo SSH_OK' -AllowFailure |
            Select-Object -First 1

        if ($probe -ne 'SSH_OK') {
            throw "SSH nije spreman: $($n[0])"
        }

        Write-Host ("[SSH] {0} OK" -f $n[0]) -ForegroundColor DarkGray
    }

    # Otvaramo 3x2 live raspored odmah nakon SSH provjere.
    # Tako vidis startup, eventualnu gresku, stop servera, NIDS/fail-safe
    # dogadaje i napad dok se eksperiment stvarno izvodi.
    Open-AllLiveLogWindows

    # --------------------------------------------------
    # Provjera stvarne NIDS/fail-safe konfiguracije.
    # nids.sh sourcea nids.conf prije failsafe.sh, zato ovdje ne glumimo
    # da environment override moze nadjacati vrijednosti iz konfiguracije.
    # --------------------------------------------------

    Write-Host ''
    Write-Host '[PREFLIGHT] Citam stvarni nids.conf s NIDS VM-a...' -ForegroundColor Yellow

    # Prethodna verzija je sourceala nids.conf kroz jedan multiline SSH argument.
    # Na Windows/ssh kombinaciji to je vratilo "|||||" i lazno prekinulo run.
    # Sad samo citamo stvarne retke i lokalno ih parsiramo.
    $configLines = @(
        Invoke-SshText `
            -Ip $NidsIp `
            -Command "grep -E '^(SERVER_IP|SERVER_PORT|EMERGENCY_BLOCK_ENABLE|EMERGENCY_BLOCK_TTL|SERVER_CHECK_RETRIES|SERVER_CHECK_WAIT)=' /home/user/diplomski/nids/nids.conf 2>/dev/null || true" `
            -AllowFailure
    )

    $configLines | ForEach-Object {
        if ($_ -and $_.Trim()) {
            Write-Host ("  {0}" -f $_) -ForegroundColor White
        }
    }

    $configMap = @{}

    foreach ($line in $configLines) {
        if ($line -match '^([A-Z_]+)=(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim().Trim('"').Trim("'")
            $configMap[$key] = $value
        }
    }

    $configProblems = @()

    if ($configMap['SERVER_IP'] -ne $TargetDataIp) {
        $configProblems += "SERVER_IP=$($configMap['SERVER_IP'])"
    }

    if ($configMap['SERVER_PORT'] -ne [string]$ServerServicePort) {
        $configProblems += "SERVER_PORT=$($configMap['SERVER_PORT'])"
    }

    if ($configMap['EMERGENCY_BLOCK_ENABLE'] -ne '1') {
        $configProblems += "EMERGENCY_BLOCK_ENABLE=$($configMap['EMERGENCY_BLOCK_ENABLE'])"
    }

    if ($configMap['EMERGENCY_BLOCK_TTL'] -ne [string]$EmergencyBlockTtl) {
        $configProblems += "EMERGENCY_BLOCK_TTL=$($configMap['EMERGENCY_BLOCK_TTL'])"
    }

    if ($configMap['SERVER_CHECK_RETRIES'] -ne [string]$ServerCheckRetries) {
        $configProblems += "SERVER_CHECK_RETRIES=$($configMap['SERVER_CHECK_RETRIES'])"
    }

    if ($configMap['SERVER_CHECK_WAIT'] -ne [string]$ServerCheckWaitSeconds) {
        $configProblems += "SERVER_CHECK_WAIT=$($configMap['SERVER_CHECK_WAIT'])"
    }

    if ($configProblems.Count -gt 0) {
        throw "Stvarni nids.conf ne odgovara eksperimentu: $($configProblems -join ', ')"
    }

    Write-Host '[CONFIG OK] FAIL-SAFE postavke odgovaraju eksperimentu.' -ForegroundColor Green

    $controlEmergencyProbe = Invoke-SshText `
        -Ip $NidsIp `
        -Command "if grep -q 'EMERGENCY_BLOCK_REQUEST)' /home/user/diplomski/nids/control.sh 2>/dev/null && grep -q 'EMERGENCY_BLOCK_ACTION' /home/user/diplomski/nids/control.sh 2>/dev/null; then echo SUPPORTED; else echo MISSING; fi" `
        -AllowFailure |
        Select-Object -Last 1

    $controlExpiryProbe = Invoke-SshText `
        -Ip $NidsIp `
        -Command "if grep -q 'EMERGENCY_BLOCK_EXPIRED' /home/user/diplomski/nids/control.sh 2>/dev/null; then echo SUPPORTED; else echo MISSING; fi" `
        -AllowFailure |
        Select-Object -Last 1

    $controlSupportsEmergency = ($controlEmergencyProbe -eq 'SUPPORTED')
    $controlSupportsExpiry = ($controlExpiryProbe -eq 'SUPPORTED')

    if ($controlSupportsEmergency) {
        Write-Host '[CONTROL] EMERGENCY_BLOCK_REQUEST grana pronadena.' -ForegroundColor Green
    }
    else {
        Write-Host '[CONTROL WARNING] control.sh ne sadrzi EMERGENCY_BLOCK_REQUEST. Fail-safe moze poslati zahtjev, ali control ga vjerojatno nece obraditi.' -ForegroundColor Yellow
    }

    if ($controlSupportsExpiry) {
        Write-Host '[CONTROL] EMERGENCY_BLOCK_REQUEST/ACTION/EXPIRED grane pronadene.' -ForegroundColor Green
    }
    else {
        Write-Host '[CONTROL WARNING] EMERGENCY_BLOCK_EXPIRED nije pronaden u control.sh.' -ForegroundColor Yellow
    }

    # --------------------------------------------------
    # response_mode
    # --------------------------------------------------

    Write-Host ''
    Write-Host ("[CONFIG] response_mode -> {0}" -f $Mode) -ForegroundColor Yellow

    $serverConfig = Invoke-SshText `
        -Ip $ServerIp `
        -Command "cd /home/user/diplomski/server && sed -i -E 's/^response_mode:.*/response_mode: $Mode/' server.conf && grep '^response_mode:' server.conf"

    $serverConfig | ForEach-Object {
        Write-Host ("  {0}" -f $_) -ForegroundColor White
    }

    # --------------------------------------------------
    # Clean + start
    # --------------------------------------------------

    Write-Host ''
    Write-Host '[FAZA 1/7] CLEAN + pokretanje komponenti' -ForegroundColor Cyan

    $preRunCleanCompleted = Invoke-FullLabClean -Phase 'PRE-RUN'
    Start-Sleep -Seconds 1

    $serverLinesBeforeRestart = Get-LineCount -Ip $ServerIp -Path $ServerLog

    $serverCmd = "cd /home/user/diplomski/server; nohup bash ./server.sh >/tmp/exp08-server.log 2>&1 </dev/null & sleep 2; if pgrep -f '[s]erver.sh' >/dev/null; then echo COMPONENT_OK; else echo COMPONENT_FAIL; tail -n 25 /tmp/exp08-server.log; fi"
    $nidsCmd   = "cd /home/user/diplomski/nids; nohup sudo -n bash ./nids.sh >/tmp/exp08-nids.log 2>&1 </dev/null & sleep 3; if sudo -n pgrep -f '[n]ids.sh' >/dev/null && ss -lnt 2>/dev/null | awk '{print `$4}' | grep -qE '(:|\])5001`$'; then echo COMPONENT_OK; else echo COMPONENT_FAIL; tail -n 30 /tmp/exp08-nids.log; fi"
    $agentCmd  = "cd /home/user/diplomski/agent; nohup sudo -n ./agent.sh >/tmp/exp08-agent.log 2>&1 </dev/null & sleep 3; if sudo -n pgrep -f '[a]gent.sh' >/dev/null; then echo COMPONENT_OK; else echo COMPONENT_FAIL; tail -n 25 /tmp/exp08-agent.log; fi"

    Start-RealComponent -Name 'SERVER' -Ip $ServerIp -Command $serverCmd
    Start-RealComponent -Name 'NIDS' -Ip $NidsIp -Command $nidsCmd

    $serverLinesAfterRestart = Get-LineCount -Ip $ServerIp -Path $ServerLog

    if ($serverLinesAfterRestart -lt $serverLinesBeforeRestart) {
        Write-Host ("[BASELINE MARKER] promet.log resetiran: prije={0}, sada={1}" -f $serverLinesBeforeRestart,$serverLinesAfterRestart) -ForegroundColor DarkGray
    }

    $baselineStart = $serverLinesAfterRestart + 1

    Start-RealComponent -Name 'AGENT-01' -Ip $Agent01Ip -Command $agentCmd
    Start-RealComponent -Name 'AGENT-02' -Ip $Agent02Ip -Command $agentCmd
    Start-RealComponent -Name 'AGENT-03' -Ip $Agent03Ip -Command $agentCmd

    Write-Host '[OK] Komponente pokrenute.' -ForegroundColor Green

    # --------------------------------------------------
    # Zdravi baseline
    # --------------------------------------------------

    Write-Host ''
    Write-Host '[FAZA 2/7] Zdravi baseline sustava' -ForegroundColor Cyan
    Write-Host '[BASELINE] Cekam HEARTBEAT + 2x HEALTHY za agent-01...' -ForegroundColor Yellow

    $baselineDeadline = (Get-Date).AddSeconds($BaselineTimeoutSeconds)

    while ((Get-Date) -lt $baselineDeadline) {
        $baselineHeartbeatLine = Get-LastMatch `
            -Ip $ServerIp `
            -Path $ServerLog `
            -StartLine $baselineStart `
            -Regex "\[HEARTBEAT\] HEARTBEAT agent-01( |$)"

        $baselinePeer02Line = Get-LastMatch `
            -Ip $ServerIp `
            -Path $ServerLog `
            -StartLine $baselineStart `
            -Regex "\[PEER_STATE\].*observer=agent-02.*target=agent-01.*state=HEALTHY"

        $baselinePeer03Line = Get-LastMatch `
            -Ip $ServerIp `
            -Path $ServerLog `
            -StartLine $baselineStart `
            -Regex "\[PEER_STATE\].*observer=agent-03.*target=agent-01.*state=HEALTHY"

        if ($baselineHeartbeatLine -and $baselinePeer02Line -and $baselinePeer03Line) {
            break
        }

        $missing = @()
        if (-not $baselineHeartbeatLine) { $missing += 'HEARTBEAT' }
        if (-not $baselinePeer02Line) { $missing += 'agent-02 HEALTHY' }
        if (-not $baselinePeer03Line) { $missing += 'agent-03 HEALTHY' }

        Write-Host ("  cekam: {0}" -f ($missing -join ', ')) -ForegroundColor DarkGray
        Start-Sleep -Seconds $PollSeconds
    }

    if (-not $baselineHeartbeatLine -or -not $baselinePeer02Line -or -not $baselinePeer03Line) {
        throw 'Nije dobiven potpuni zdravi baseline unutar zadanog vremena.'
    }

    Write-Host '[BASELINE OK]' -ForegroundColor Green
    Write-Host $baselineHeartbeatLine -ForegroundColor White
    Write-Host $baselinePeer02Line -ForegroundColor White
    Write-Host $baselinePeer03Line -ForegroundColor White

    $serverPortInitiallyReachable = Test-ServerProtectedPort

    if (-not $serverPortInitiallyReachable) {
        throw "Server port $TargetDataIp`:$ServerServicePort nije dostupan prije zaustavljanja server.sh."
    }

    Write-Host ("[PORT BASELINE OK] {0}:{1} REACHABLE iz NIDS-a." -f $TargetDataIp,$ServerServicePort) -ForegroundColor Green

    # Markeri se uzimaju NAKON zdravog baselinea. Time nijedan stari fail-safe
    # ili BLOCK_EXPIRED zapis ne moze pripasti ovom runu.
    $serverStart  = (Get-LineCount -Ip $ServerIp -Path $ServerLog) + 1
    $nidsStart    = (Get-LineCount -Ip $NidsIp -Path $NidsLog) + 1
    $agent01Start = (Get-LineCount -Ip $Agent01Ip -Path $AgentLog) + 1
    $agent02Start = (Get-LineCount -Ip $Agent02Ip -Path $AgentLog) + 1
    $agent03Start = (Get-LineCount -Ip $Agent03Ip -Path $AgentLog) + 1

    Write-Host ("[MARKER] NIDS od retka {0}" -f $nidsStart) -ForegroundColor DarkGray

    # --------------------------------------------------
    # Kontrolirano gasenje samo server.sh
    # --------------------------------------------------

    Write-Host ''
    Write-Host '[FAZA 3/7] Gasenje SERVERA pomocu server/clean.sh' -ForegroundColor Cyan
    Write-Host '[FAULT] Pokrecem univerzalni clean.sh SAMO na SERVER VM-u.' -ForegroundColor Yellow
    Write-Host '[FAULT] NIDS/control i agenti ostaju aktivni.' -ForegroundColor DarkGray

    $stopServerOut = Invoke-SshText `
        -Ip $ServerIp `
        -Command "cd /home/user/diplomski/server && sudo -n bash ./clean.sh" `
        -AllowFailure

    $stopServerOut | ForEach-Object {
        if ($_ -and $_.Trim()) {
            Write-Host ("  {0}" -f $_) -ForegroundColor DarkGray
        }
    }

    # Nakon clean.sh eksplicitno provjeri da server.sh vise ne postoji.
    $serverProcessProbe = Invoke-SshText `
        -Ip $ServerIp `
        -Command "if pgrep -f '[s]erver.sh' >/dev/null 2>&1; then echo SERVER_PROCESS_STILL_PRESENT; else echo SERVER_PROCESS_STOPPED; fi" `
        -AllowFailure |
        Select-Object -Last 1

    $serverProcessStopped = ($serverProcessProbe -eq 'SERVER_PROCESS_STOPPED')
    $serverStoppedByExperiment = $serverProcessStopped

    # SERVER VM mora ostati dostupna preko management SSH-a.
    $serverVmProbe = Invoke-SshText `
        -Ip $ServerIp `
        -Command 'echo SERVER_VM_UP' `
        -AllowFailure |
        Select-Object -Last 1

    if ($serverVmProbe -ne 'SERVER_VM_UP') {
        throw 'SERVER VM nije dostupna nakon server/clean.sh.'
    }

    # Glavni funkcionalni dokaz: NIDS vise ne moze otvoriti TCP/5000.
    $serverPortAfterStopReachable = Test-ServerProtectedPort

    # NIDS/control moraju ostati zivi jer upravo oni izvode fail-safe.
    $nidsControlAliveAfterServerStop = Test-NidsControlHealthy

    if (-not $serverProcessStopped) {
        throw 'server.sh nije zaustavljen ni nakon server/clean.sh.'
    }

    if ($serverPortAfterStopReachable) {
        throw "Port $TargetDataIp`:$ServerServicePort je i dalje dostupan nakon server/clean.sh."
    }

    if (-not $nidsControlAliveAfterServerStop) {
        throw 'NIDS/control nije ostao aktivan nakon gasenja servera.'
    }

    Write-Host ("[FAULT OK] server/clean.sh -> server.sh=STOPPED | VM=UP | {0}:{1}=UNREACHABLE | NIDS/control=UP" -f $TargetDataIp,$ServerServicePort) -ForegroundColor Green

    # --------------------------------------------------
    # Kontrolirani ICMP burst
    # --------------------------------------------------

    Write-Host ''
    Write-Host '[FAZA 4/7] Kontrolirani ICMP flood prema SERVERU' -ForegroundColor Cyan
    Write-Host ("[ATTACK] ping target={0} rate~{1}pps duration~{2}s packets={3}" -f $TargetDataIp,$PacketsPerSecond,$FloodDurationSeconds,$PacketCount) -ForegroundColor Red

    $floodCmd = @'
set +e
duration=__DURATION__
pps=__PPS__
interval="__INTERVAL__"
count=__COUNT__
target="__TARGET__"
flood_log="__FLOOD_LOG__"
meta="__FLOOD_META__"
raw_log="__PING_RAW_LOG__"

: > "$flood_log"
: > "$meta"
: > "$raw_log"

start="$(date -u '+%Y-%m-%d %H:%M:%S.%3N')"
echo "ATTACK_START=$start" > "$meta"

echo "==================================================" >> "$flood_log"
echo "[PING] FAIL-SAFE ICMP BURST START" >> "$flood_log"
echo "[PING] target=$target" >> "$flood_log"
echo "[PING] rate_approx=${pps} packets/s interval=${interval}s count=$count" >> "$flood_log"
echo "==================================================" >> "$flood_log"

# Ispis se istodobno zapisuje u raw log i u live flood log,
# pa EXP08-NAPADAC prozor prikazuje ping dok napad stvarno traje.
ping -n -i "$interval" -W 1 -c "$count" "$target" 2>&1 |
    tee "$raw_log" >> "$flood_log"
ping_rc=${PIPESTATUS[0]}

end="$(date -u '+%Y-%m-%d %H:%M:%S.%3N')"
echo "ATTACK_END=$end" >> "$meta"
echo "PING_RC=$ping_rc" >> "$meta"

echo "[PING] END rc=$ping_rc" >> "$flood_log"
echo "==================================================" >> "$flood_log"

exit 0
'@

    $floodCmd = $floodCmd.Replace('__DURATION__', [string]$FloodDurationSeconds)
    $floodCmd = $floodCmd.Replace('__PPS__', [string]$PacketsPerSecond)
    $floodCmd = $floodCmd.Replace('__INTERVAL__', $PingIntervalText)
    $floodCmd = $floodCmd.Replace('__COUNT__', [string]$PacketCount)
    $floodCmd = $floodCmd.Replace('__TARGET__', $TargetDataIp)
    $floodCmd = $floodCmd.Replace('__FLOOD_LOG__', $FloodLog)
    $floodCmd = $floodCmd.Replace('__FLOOD_META__', $FloodMeta)
    $floodCmd = $floodCmd.Replace('__PING_RAW_LOG__', $PingRawLog)
    $floodCmd = $floodCmd.Replace("`r", "")

    $floodBytes = [System.Text.Encoding]::UTF8.GetBytes($floodCmd)
    $floodBase64 = [Convert]::ToBase64String($floodBytes)
    $remoteFloodCmd = "printf '%s' '$floodBase64' | base64 -d | /bin/bash"

    Invoke-SshText -Ip $AttackerIp -Command $remoteFloodCmd | Out-Null

    $meta = Invoke-SshText -Ip $AttackerIp -Command "cat '$FloodMeta' 2>/dev/null || true" -AllowFailure

    foreach ($line in $meta) {
        if ($line -match '^ATTACK_START=(.+)$') { $attackStartText = $Matches[1] }
        if ($line -match '^ATTACK_END=(.+)$')   { $attackEndText = $Matches[1] }
    }

    $attackStartTs = Get-PlainTime $attackStartText
    $attackEndTs = Get-PlainTime $attackEndText
    $attackDurationActual = Delta $attackStartTs $attackEndTs

    $pingSummary = Invoke-SshText `
        -Ip $AttackerIp `
        -Command "grep -E 'packets transmitted' '$PingRawLog' | tail -n 1 || true" `
        -AllowFailure |
        Select-Object -First 1

    if ($pingSummary -and $pingSummary -match '(\d+) packets transmitted,\s*(\d+) received,.*?([0-9.]+)% packet loss') {
        $packetsSent = [int]$Matches[1]
        $packetsReceived = [int]$Matches[2]
        $packetsLost = $packetsSent - $packetsReceived
        $packetLossPercent = [double]::Parse(
            $Matches[3],
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }

    Write-Host ("[ATTACK_START] {0}" -f $attackStartText) -ForegroundColor Red

    # --------------------------------------------------
    # Cekanje stvarnih fail-safe dogadaja
    # --------------------------------------------------

    Write-Host ''
    Write-Host '[FAZA 5/7] Cekam stvarni FAIL-SAFE slijed u NIDS logu' -ForegroundColor Cyan
    Write-Host '  NIDS_ALERT -> delivery failed -> 2x UNREACHABLE -> EMERGENCY_BLOCK' -ForegroundColor DarkGray
    Write-Host '  -> EMERGENCY_BLOCK_REQUEST -> EMERGENCY_BLOCK_ACTION SUCCESS' -ForegroundColor DarkGray

    $srcEsc = [regex]::Escape($AttackerDataIp)
    $dstEsc = [regex]::Escape($TargetDataIp)
    $serverEndpointEsc = [regex]::Escape("$TargetDataIp`:$ServerServicePort")

    $alertRegex = "\[NIDS_ALERT\].*type=ICMP_FLOOD.*src=$srcEsc.*dst=$dstEsc"
    $deliveryFailedRegex = "\[FAILSAFE\].*state=SERVER_ATTACK_ALERT_DELIVERY_FAILED.*src=$srcEsc.*dst=$dstEsc"
    $unreachableRegex = "\[FAILSAFE_CHECK\].*server=$serverEndpointEsc.*status=UNREACHABLE"
    $reachableRegex = "\[FAILSAFE_CHECK\].*server=$serverEndpointEsc.*status=REACHABLE"
    $emergencyBlockRegex = "\[FAILSAFE\].*action=EMERGENCY_BLOCK.*src=$srcEsc.*dst=$dstEsc.*reason=SERVER_UNAVAILABLE_UNDER_ATTACK"
    $emergencyRequestRegex = "\[FAILSAFE\].*EMERGENCY_BLOCK_REQUEST poslan.*src=$srcEsc.*ttl=$EmergencyBlockTtl"
    $blockActionRegex = "\[EMERGENCY_BLOCK_ACTION\].*status=SUCCESS.*src_ip=$srcEsc.*ttl=$EmergencyBlockTtl"
    $blockExpiredRegex = "\[EMERGENCY_BLOCK_EXPIRED\].*src_ip=$srcEsc.*ttl=$EmergencyBlockTtl"
    $blockExpireFailRegex = "\[WARNING\].*EMERGENCY_BLOCK_EXPIRE_FAIL.*src_ip=$srcEsc"
    $unknownEmergencyRegex = "\[WARNING\].*Nepoznata control naredba: EMERGENCY_BLOCK_REQUEST"

    $eventDeadline = (Get-Date).AddSeconds($FailSafeEventTimeoutSeconds)

    while ((Get-Date) -lt $eventDeadline) {
        if (-not $nidsAlertLine) {
            $nidsAlertLine = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $alertRegex
            if ($nidsAlertLine) {
                Write-Host ("[EVENT] {0}" -f $nidsAlertLine) -ForegroundColor Yellow
            }
        }

        if (-not $failsafeDeliveryFailedLine) {
            $failsafeDeliveryFailedLine = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $deliveryFailedRegex
            if ($failsafeDeliveryFailedLine) {
                Write-Host ("[EVENT] {0}" -f $failsafeDeliveryFailedLine) -ForegroundColor Red
            }
        }

        $failsafeCheckCount = Get-RemoteMatchCount `
            -Ip $NidsIp `
            -Path $NidsLog `
            -StartLine $nidsStart `
            -Regex $unreachableRegex

        if (-not $failsafeEmergencyBlockLine) {
            $failsafeEmergencyBlockLine = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $emergencyBlockRegex
            if ($failsafeEmergencyBlockLine) {
                Write-Host ("[EVENT] {0}" -f $failsafeEmergencyBlockLine) -ForegroundColor Magenta
            }
        }

        if (-not $emergencyBlockRequestLine) {
            $emergencyBlockRequestLine = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $emergencyRequestRegex
            if ($emergencyBlockRequestLine) {
                Write-Host ("[EVENT] {0}" -f $emergencyBlockRequestLine) -ForegroundColor Magenta
            }
        }

        if (-not $blockActionLine) {
            $blockActionLine = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $blockActionRegex
            if ($blockActionLine) {
                Write-Host ("[EVENT] {0}" -f $blockActionLine) -ForegroundColor Green
            }
        }

        if (-not $unknownEmergencyRequestLine) {
            $unknownEmergencyRequestLine = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $unknownEmergencyRegex
        }

        if ($blockActionLine) {
            break
        }

        if ($unknownEmergencyRequestLine) {
            Write-Host ("[CONTROL ERROR] {0}" -f $unknownEmergencyRequestLine) -ForegroundColor Red
            break
        }

        Start-Sleep -Milliseconds $EventPollMilliseconds
    }

    # Konacno osvjezenje svih dokaza nakon event petlje.
    if (-not $nidsAlertLine) {
        $nidsAlertLine = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $alertRegex
    }

    if (-not $failsafeDeliveryFailedLine) {
        $failsafeDeliveryFailedLine = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $deliveryFailedRegex
    }

    $failsafeCheckCount = Get-RemoteMatchCount `
        -Ip $NidsIp `
        -Path $NidsLog `
        -StartLine $nidsStart `
        -Regex $unreachableRegex

    $reachableCheckCount = Get-RemoteMatchCount `
        -Ip $NidsIp `
        -Path $NidsLog `
        -StartLine $nidsStart `
        -Regex $reachableRegex

    if (-not $failsafeEmergencyBlockLine) {
        $failsafeEmergencyBlockLine = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $emergencyBlockRegex
    }

    if (-not $emergencyBlockRequestLine) {
        $emergencyBlockRequestLine = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $emergencyRequestRegex
    }

    if (-not $blockActionLine) {
        $blockActionLine = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $blockActionRegex
    }

    if (-not $unknownEmergencyRequestLine) {
        $unknownEmergencyRequestLine = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $nidsStart -Regex $unknownEmergencyRegex
    }

    $firewallRuleAfterBlock = Get-FirewallRuleState -SourceIp $AttackerDataIp

    # --------------------------------------------------
    # TTL / automatski unblock. Ovaj dio se vrednuje zasebno.
    # --------------------------------------------------

    if ($blockActionLine) {
        Write-Host ''
        Write-Host '[FAZA 6/7] TTL i automatsko uklanjanje emergency DROP pravila' -ForegroundColor Cyan
        Write-Host ("[TTL] Cekam EMERGENCY_BLOCK_EXPIRED (~{0} s)..." -f $EmergencyBlockTtl) -ForegroundColor Yellow

        $blockExpiredLine = Wait-RemoteLogLine `
            -Ip $NidsIp `
            -Path $NidsLog `
            -StartLine $nidsStart `
            -Regex $blockExpiredRegex `
            -TimeoutSeconds ($EmergencyBlockTtl + $ExpiryGraceSeconds) `
            -PollMilliseconds 500

        if (-not $blockExpiredLine) {
            $blockExpireFailLine = Get-FirstMatch `
                -Ip $NidsIp `
                -Path $NidsLog `
                -StartLine $nidsStart `
                -Regex $blockExpireFailRegex
        }

        Start-Sleep -Seconds 1
        $firewallRuleAfterExpiry = Get-FirewallRuleState -SourceIp $AttackerDataIp

        $blockExpiredVerified = [bool]$blockExpiredLine
        $firewallAfterExpiryCleared = ($firewallRuleAfterExpiry -eq 'MISSING')
    }
    else {
        $firewallRuleAfterExpiry = Get-FirewallRuleState -SourceIp $AttackerDataIp
    }

    # --------------------------------------------------
    # Metrike
    # --------------------------------------------------

    $attackStartToNidsAlert = Delta $attackStartTs (Get-LogTime $nidsAlertLine)
    $nidsAlertToFailsafeBlock = Delta (Get-LogTime $nidsAlertLine) (Get-LogTime $failsafeEmergencyBlockLine)
    $failsafeBlockToBlockAction = Delta (Get-LogTime $failsafeEmergencyBlockLine) (Get-LogTime $blockActionLine)
    $attackStartToBlockAction = Delta $attackStartTs (Get-LogTime $blockActionLine)
    $blockActionToExpiry = Delta (Get-LogTime $blockActionLine) (Get-LogTime $blockExpiredLine)

    # --------------------------------------------------
    # Dokazni ispisi
    # --------------------------------------------------

    Write-Host ''
    Write-Host '[DOKAZ - NIDS / FAIL-SAFE / CONTROL]' -ForegroundColor Yellow

    Invoke-SshText `
        -Ip $NidsIp `
        -Command "tail -n +$nidsStart '$NidsLog' | grep -E '\[(NIDS_ALERT|FAILSAFE|FAILSAFE_CHECK|EMERGENCY_BLOCK_REQUEST|EMERGENCY_BLOCK_ACTION|EMERGENCY_BLOCK_EXPIRED|WARNING|ERROR)\]' | tail -n 220" `
        -AllowFailure |
        ForEach-Object { Write-Host $_ -ForegroundColor White }

    Write-Host ''
    Write-Host '[DOKAZ - ATTACKER]' -ForegroundColor Yellow

    Invoke-SshText `
        -Ip $AttackerIp `
        -Command "tail -n 30 '$FloodLog' 2>/dev/null; echo '--- META ---'; cat '$FloodMeta' 2>/dev/null || true" `
        -AllowFailure |
        ForEach-Object { Write-Host $_ -ForegroundColor White }
}
catch {
    $fatalError = $_.Exception.Message
    Write-Host ''
    Write-Host ("[EKSPERIMENT ERROR] {0}" -f $fatalError) -ForegroundColor Red
}
finally {
    Write-Host ''
    Write-Host '[FAZA 7/7] POST-RUN cleanup' -ForegroundColor Cyan
    Write-Host '[CLEANUP] Nakon mjerenja koristim isti univerzalni clean.sh.' -ForegroundColor Yellow

    try {
        $postRunCleanCompleted = Invoke-FullLabClean -Phase 'POST-RUN'
    }
    catch {
        $postRunCleanCompleted = $false
        Write-Host ("[CLEANUP ERROR] {0}" -f $_.Exception.Message) -ForegroundColor Red
    }

    # Namjerno ne restartamo samo server ovdje.
    # Kod batch izvodenja sljedeci run sam radi PRE-RUN clean + start svih
    # komponenti. Tako svaki run uvijek pocinje iz jednakog stanja.
    $serverRecoveredAfterRun = $false
}

# --------------------------------------------------
# Zavrsna validacija
#
# valid_run predstavlja uspjeh FAIL-SAFE blokiranja.
# TTL cleanup je namjerno odvojen u zasebne boolean stupce.
# --------------------------------------------------

$coreIssues = @()

if (-not $serverPortInitiallyReachable) {
    $coreIssues += 'Server port nije bio dostupan u pocetnom baselineu.'
}

if (-not $serverProcessStopped) {
    $coreIssues += 'server.sh nije potvrden kao zaustavljen.'
}

if ($serverPortAfterStopReachable -ne $false) {
    $coreIssues += 'Port 5000 nije potvrden kao nedostupan nakon zaustavljanja server.sh.'
}

if (-not $nidsControlAliveAfterServerStop) {
    $coreIssues += 'NIDS/control nije potvrden kao aktivan nakon zaustavljanja servera.'
}

if (-not $nidsAlertLine) {
    $coreIssues += 'Nedostaje NIDS_ALERT za ICMP flood prema serveru.'
}

if (-not $failsafeDeliveryFailedLine) {
    $coreIssues += 'Nedostaje SERVER_ATTACK_ALERT_DELIVERY_FAILED.'
}

if ($failsafeCheckCount -lt $ServerCheckRetries) {
    $coreIssues += "Zabiljezeno je samo $failsafeCheckCount/$ServerCheckRetries FAILSAFE_CHECK UNREACHABLE provjera."
}

if (-not $failsafeEmergencyBlockLine) {
    $coreIssues += 'Nedostaje FAILSAFE action=EMERGENCY_BLOCK.'
}

if (-not $emergencyBlockRequestLine) {
    $coreIssues += 'Nedostaje potvrda slanja EMERGENCY_BLOCK_REQUEST.'
}

if (-not $blockActionLine) {
    $coreIssues += 'Nedostaje EMERGENCY_BLOCK_ACTION status=SUCCESS.'
}

if ($firewallRuleAfterBlock -notmatch '^PRESENT_') {
    $coreIssues += 'Emergency DROP pravilo nije potvrdeno nakon EMERGENCY_BLOCK_ACTION.'
}

if ($unknownEmergencyRequestLine) {
    $coreIssues += 'control.sh je EMERGENCY_BLOCK_REQUEST evidentirao kao nepoznatu naredbu.'
}

if ($fatalError) {
    $coreIssues += "Eksperiment je prekinut: $fatalError"
}

$failsafeBlockVerified = ($coreIssues.Count -eq 0)
$validRun = $failsafeBlockVerified

$ttlIssues = @()

if (-not $blockExpiredVerified) {
    $ttlIssues += 'EMERGENCY_BLOCK_EXPIRED nije potvrden.'
}

if (-not $firewallAfterExpiryCleared) {
    $ttlIssues += "DROP pravilo nakon TTL-a nije potvrdeno kao uklonjeno (state=$firewallRuleAfterExpiry)."
}

if ($blockExpireFailLine) {
    $ttlIssues += 'Control je zabiljezio EMERGENCY_BLOCK_EXPIRE_FAIL.'
}

if ($failsafeBlockVerified) {
    if ($ttlIssues.Count -eq 0) {
        $validationNote = 'FAILSAFE_OK | TTL_OK'
    }
    else {
        $validationNote = 'FAILSAFE_OK | TTL: ' + ($ttlIssues -join ' ')
    }
}
else {
    $validationNote = 'FAILSAFE_FAIL: ' + ($coreIssues -join ' | ')

    if ($ttlIssues.Count -eq 0) {
        $validationNote += ' | TTL_OK'
    }
    else {
        $validationNote += ' | TTL: ' + ($ttlIssues -join ' ')
    }
}

# --------------------------------------------------
# Rezultat
# --------------------------------------------------

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host ' REZULTAT - SERVER FAIL-SAFE' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

Write-Host ("[SERVER] baseline port={0} | server.sh stopped={1} | port nakon stopa={2}" -f `
    $serverPortInitiallyReachable,$serverProcessStopped,$serverPortAfterStopReachable) -ForegroundColor White

Write-Host ("[NIDS/CONTROL AFTER SERVER STOP] {0}" -f $nidsControlAliveAfterServerStop) -ForegroundColor White
Write-Host ("[CLEAN] pre-run={0} | post-run={1}" -f $preRunCleanCompleted,$postRunCleanCompleted) -ForegroundColor White

Write-Host ("[FAILSAFE CHECKS] UNREACHABLE={0}/{1}" -f $failsafeCheckCount,$ServerCheckRetries) -ForegroundColor White
Write-Host ("[FIREWALL AFTER BLOCK] {0}" -f $firewallRuleAfterBlock) -ForegroundColor White
Write-Host ("[FIREWALL AFTER EXPIRY] {0}" -f $firewallRuleAfterExpiry) -ForegroundColor White

if ($null -ne $attackStartToNidsAlert) {
    Write-Host ("[M1] attack -> NIDS_ALERT = {0:N3} s" -f $attackStartToNidsAlert) -ForegroundColor Green
}

if ($null -ne $nidsAlertToFailsafeBlock) {
    Write-Host ("[M2] NIDS_ALERT -> EMERGENCY_BLOCK = {0:N3} s" -f $nidsAlertToFailsafeBlock) -ForegroundColor Green
}

if ($null -ne $failsafeBlockToBlockAction) {
    Write-Host ("[M3] EMERGENCY_BLOCK -> EMERGENCY_BLOCK_ACTION = {0:N3} s" -f $failsafeBlockToBlockAction) -ForegroundColor Green
}

if ($null -ne $attackStartToBlockAction) {
    Write-Host ("[M4] attack -> EMERGENCY_BLOCK_ACTION = {0:N3} s" -f $attackStartToBlockAction) -ForegroundColor Green
}

if ($null -ne $blockActionToExpiry) {
    Write-Host ("[TTL] EMERGENCY_BLOCK_ACTION -> EMERGENCY_BLOCK_EXPIRED = {0:N3} s" -f $blockActionToExpiry) -ForegroundColor Green
}

Write-Host ("[FAIL-SAFE VERIFIED] {0}" -f $failsafeBlockVerified) -ForegroundColor $(if ($failsafeBlockVerified) { 'Green' } else { 'Red' })
Write-Host ("[EMERGENCY_BLOCK_EXPIRED VERIFIED] {0}" -f $blockExpiredVerified) -ForegroundColor $(if ($blockExpiredVerified) { 'Green' } else { 'Yellow' })
Write-Host ("[FIREWALL CLEARED AFTER TTL] {0}" -f $firewallAfterExpiryCleared) -ForegroundColor $(if ($firewallAfterExpiryCleared) { 'Green' } else { 'Yellow' })

if ($validRun) {
    Write-Host ("[VALIDACIJA] RUN OK: {0}" -f $validationNote) -ForegroundColor Green
}
else {
    Write-Host ("[VALIDACIJA] RUN NIJE VALJAN: {0}" -f $validationNote) -ForegroundColor Red
}

# --------------------------------------------------
# CSV
# --------------------------------------------------

$resultsDir = Join-Path $PSScriptRoot 'rezultati'

if (-not (Test-Path $resultsDir)) {
    New-Item -ItemType Directory -Path $resultsDir | Out-Null
}

$csv = Join-Path $resultsDir '08-icmp-failsafe-server.csv'

[pscustomobject]@{
    run_time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    scenario = $Scenario

    target = $TargetLabel
    target_ip = $TargetDataIp
    attacker_ip = $AttackerDataIp

    emergency_block_enable = 1
    emergency_block_ttl_s = $EmergencyBlockTtl
    server_check_retries = $ServerCheckRetries
    server_check_wait_s = $ServerCheckWaitSeconds

    control_supports_emergency_block_request = $controlSupportsEmergency
    control_supports_block_expired = $controlSupportsExpiry

    server_port_initially_reachable = $serverPortInitiallyReachable
    server_process_stopped = $serverProcessStopped
    server_port_after_stop_reachable = $serverPortAfterStopReachable
    nids_control_alive_after_server_stop = $nidsControlAliveAfterServerStop
    pre_run_clean_completed = $preRunCleanCompleted
    post_run_clean_completed = $postRunCleanCompleted

    attack_start_time = $attackStartText
    attack_duration_actual_s = $attackDurationActual
    packets_per_second_requested = $PacketsPerSecond
    flood_duration_requested_s = $FloodDurationSeconds
    packets_requested = $PacketCount
    packets_sent = $packetsSent
    packets_received = $packetsReceived
    packets_lost = $packetsLost
    packet_loss_percent = $packetLossPercent

    nids_alert_line = $nidsAlertLine
    failsafe_delivery_failed_line = $failsafeDeliveryFailedLine
    failsafe_check_count = $failsafeCheckCount
    failsafe_emergency_block_line = $failsafeEmergencyBlockLine
    emergency_block_request_line = $emergencyBlockRequestLine
    block_action_event = 'EMERGENCY_BLOCK_ACTION'
    block_action_line = $blockActionLine
    block_expired_event = 'EMERGENCY_BLOCK_EXPIRED'
    block_expired_line = $blockExpiredLine
    block_expire_fail_line = $blockExpireFailLine
    unknown_emergency_request_line = $unknownEmergencyRequestLine

    attack_start_to_nids_alert_s = $attackStartToNidsAlert
    nids_alert_to_failsafe_block_s = $nidsAlertToFailsafeBlock
    failsafe_block_to_block_action_s = $failsafeBlockToBlockAction
    attack_start_to_block_action_s = $attackStartToBlockAction

    firewall_rule_after_block = $firewallRuleAfterBlock
    block_action_to_expiry_s = $blockActionToExpiry
    firewall_rule_after_expiry = $firewallRuleAfterExpiry

    failsafe_block_verified = $failsafeBlockVerified
    block_expired_verified = $blockExpiredVerified
    firewall_after_expiry_cleared = $firewallAfterExpiryCleared

    server_recovered_after_run = $serverRecoveredAfterRun

    valid_run = $validRun
    validation_note = $validationNote
} | Export-Csv -Path $csv -NoTypeInformation -Append -Encoding UTF8

Write-Host ''
Write-Host ("[CSV] {0}" -f $csv) -ForegroundColor Green
Write-Host 'Eksperiment 08 - SERVER FAIL-SAFE zavrsen.' -ForegroundColor Green
Write-Host '[INFO] Nakon runa komponente su ociscene; sljedeci run ih ponovno pokrece.' -ForegroundColor DarkGray

# Ako je run puknuo prije validacije, CSV je svejedno sacuvan, a laboratorij
# je vracen u stanje prikladno za sljedeci run.