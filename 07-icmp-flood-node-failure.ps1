param(
    # Kontrolirani ICMP promet nakon sto je NODE_FAILURE vec potvrden.
    [ValidateRange(5,50)]
    [int]$PacketsPerSecond = 20,

    # Trajanje napada. Zadano 3 s => oko 60 paketa pri 20 pps.
    [ValidateRange(1,10)]
    [int]$FloodDurationSeconds = 3,

    # Maksimalno cekanje da server nakon gasenja VM-a evidentira NODE_FAILURE.
    [ValidateRange(130,300)]
    [int]$NodeFailureTimeoutSeconds = 210,

    # Tocan VirtualBox naziv VM-a.
    [string]$AgentVmName = 'Parrot OS 7.3 KDE Security Edition Agent 01',

    # Ako je zadano, VM ostaje ugasen nakon eksperimenta.
    # Inace ga skripta na kraju ponovno pokrene radi sljedeceg runa.
    [switch]$LeaveAgentPoweredOff
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

$FloodLog    = '/tmp/diplomski-exp07-nodefailure-flood.log'
$FloodMeta   = '/tmp/diplomski-exp07-nodefailure-flood-meta.log'
$NpingRawLog = '/tmp/diplomski-exp07-nodefailure-nping-raw.log'
$NpingPidFile = '/tmp/diplomski-exp07-nodefailure-nping.pid'
$NpingRunner  = '/tmp/diplomski-exp07-nodefailure-runner.sh'

$BaselineTimeoutSeconds = 150
$PollSeconds = 5

# Helper za postojeci background-nping okvir.
# nping zavrsava nakon zadanog broja paketa; timeout je samo sigurnosna granica.
$MaxFloodSeconds = $FloodDurationSeconds + 5
$RequestedPacketCount = [int64]$PacketsPerSecond * [int64]$FloodDurationSeconds

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

$Exp07FontSize = 11
$Exp07BufferWidth = 190

if (-not ('Exp07LabWindowTools' -as [type])) {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class Exp07LabWindowTools
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

function Start-Exp07Window {
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

public static class Exp07ConsoleFont
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
    [Exp07ConsoleFont]::SetFont(
        $Exp07FontSize,
        'Cascadia Mono'
    )
}
catch {}

try {
    `$buffer = `$Host.UI.RawUI.BufferSize
    `$buffer.Width = $Exp07BufferWidth

    if (`$buffer.Height -lt 3000) {
        `$buffer.Height = 3000
    }

    `$Host.UI.RawUI.BufferSize = `$buffer
}
catch {}

Write-Host '=================================================='
Write-Host ' EXPERIMENT 07 - LIVE'
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

        $handle = [Exp07LabWindowTools]::FindWindowContaining(
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

    [Exp07LabWindowTools]::MoveWindow(
        $handle,
        $X,
        $Y,
        $Width,
        $Height,
        $true
    ) | Out-Null

    Start-Sleep -Milliseconds 300

    [Exp07LabWindowTools]::MoveWindow(
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

    Start-Exp07Window `
        -Title 'EXP07-NODEFAIL-SERVER' `
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

    Start-Exp07Window `
        -Title 'EXP07-NODEFAIL-NIDS' `
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

    Start-Exp07Window `
        -Title 'EXP07-NODEFAIL-NAPADAC' `
        -Ip $AttackerIp `
        -Color 'Red' `
        -X ($area.Left + (2 * $cellWidth)) `
        -Y $area.Top `
        -Width $cellWidth `
        -Height $cellHeight `
        -RemoteCommand @'
touch /tmp/diplomski-exp07-nodefailure-flood.log

echo
echo "[LOG] /tmp/diplomski-exp07-nodefailure-flood.log"
echo "--------------------------------------------------"

tail -n 35 -F /tmp/diplomski-exp07-nodefailure-flood.log

echo
echo "[SHELL] Ostajes spojen na NAPADAC."
export TERM=xterm-256color
export PS1='\[\e[91m\][\u@\h \W]\$ '
printf '\033[91m'
exec bash --noprofile --norc -i </dev/tty >/dev/tty 2>/dev/tty
'@

    Start-Exp07Window `
        -Title 'EXP07-NODEFAIL-AGENT-01' `
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

    Start-Exp07Window `
        -Title 'EXP07-NODEFAIL-AGENT-02' `
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

    Start-Exp07Window `
        -Title 'EXP07-NODEFAIL-AGENT-03' `
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
function Start-IntensiveIcmpFlood {
    $runner = @'
#!/usr/bin/env bash
set +e

target="__TARGET__"
rate="__RATE__"
count="__COUNT__"
max_s="__MAX_S__"
raw="__RAW__"
meta="__META__"
flood_log="__FLOOD_LOG__"

: > "$raw"
: > "$meta"

start="$(date '+%Y-%m-%d %H:%M:%S.%3N')"
echo "ATTACK_START=$start" >> "$meta"
echo "REQUESTED_PPS=$rate" >> "$meta"
echo "REQUESTED_MAX_SECONDS=$max_s" >> "$meta"
echo "REQUESTED_PACKETS=$count" >> "$meta"

{
  echo "=================================================="
  echo "[NPING] START target=$target rate=${rate}pps max=${max_s}s count=$count"
  echo "=================================================="
} >> "$flood_log"

sudo -n timeout "${max_s}s" nping --icmp --rate "$rate" -c "$count" "$target" > "$raw" 2>&1
rc=$?

end="$(date '+%Y-%m-%d %H:%M:%S.%3N')"
echo "ATTACK_END=$end" >> "$meta"
echo "NPING_RC=$rc" >> "$meta"

{
  echo "--------------------------------------------------"
  tail -n 20 "$raw" 2>/dev/null || true
  echo "[NPING] END rc=$rc"
  echo "=================================================="
} >> "$flood_log"

exit 0
'@

    $runner = $runner.Replace('__TARGET__',$TargetDataIp)
    $runner = $runner.Replace('__RATE__',[string]$PacketsPerSecond)
    $runner = $runner.Replace('__COUNT__',[string]$RequestedPacketCount)
    $runner = $runner.Replace('__MAX_S__',[string]$MaxFloodSeconds)
    $runner = $runner.Replace('__RAW__',$NpingRawLog)
    $runner = $runner.Replace('__META__',$FloodMeta)
    $runner = $runner.Replace('__FLOOD_LOG__',$FloodLog)
    $runner = $runner.Replace("`r","")

    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($runner))

    $remote = "printf '%s' '$b64' | base64 -d > '$NpingRunner'; chmod +x '$NpingRunner'; nohup setsid '$NpingRunner' >/tmp/exp07-runner-nohup.log 2>&1 </dev/null & echo `$! > '$NpingPidFile'; echo FLOOD_STARTED"

    $startOut = Invoke-SshText -Ip $AttackerIp -Command $remote
    if (($startOut -join "`n") -notmatch 'FLOOD_STARTED') {
        throw 'Nije moguce pokrenuti pozadinski nping.'
    }

    $deadline = (Get-Date).AddSeconds(5)
    $startText = $null

    do {
        $meta = Invoke-SshText -Ip $AttackerIp -Command "grep '^ATTACK_START=' '$FloodMeta' 2>/dev/null | tail -n 1 || true" -AllowFailure |
            Select-Object -First 1

        if ($meta -and $meta -match '^ATTACK_START=(.+)$') {
            $startText = $Matches[1]
            break
        }

        Start-Sleep -Milliseconds 200
    }
    while ((Get-Date) -lt $deadline)

    if (-not $startText) {
        throw 'nping je pokrenut, ali nije zapisan ATTACK_START.'
    }

    return (Get-PlainTime $startText)
}

function Stop-IntensiveIcmpFlood {
    param([string]$Reason)

    Write-Host ("[STOP FLOOD] {0}" -f $Reason) -ForegroundColor Yellow

    # nping je pokrenut preko sudo, pa ga gasimo preko sudo pkill.
    Invoke-SshText -Ip $AttackerIp -Command "sudo -n pkill -TERM -f '[n]ping.*$([regex]::Escape($TargetDataIp))' 2>/dev/null || true; sleep 1; sudo -n pkill -KILL -f '[n]ping.*$([regex]::Escape($TargetDataIp))' 2>/dev/null || true; echo STOP_SENT" -AllowFailure | Out-Null

    # Runner bi nakon prekida trebao sam zapisati ATTACK_END. Ako nije, dodaj ga.
    Start-Sleep -Milliseconds 500
    $hasEnd = Invoke-SshText -Ip $AttackerIp -Command "grep -q '^ATTACK_END=' '$FloodMeta' 2>/dev/null && echo YES || echo NO" -AllowFailure |
        Select-Object -Last 1

    if ($hasEnd -ne 'YES') {
        $escapedReason = $Reason.Replace("'","")
        Invoke-SshText -Ip $AttackerIp -Command "echo \"ATTACK_END=`$(date '+%Y-%m-%d %H:%M:%S.%3N')\" >> '$FloodMeta'; echo 'STOP_REASON=$escapedReason' >> '$FloodMeta'" -AllowFailure | Out-Null
    }
}

function Get-FloodStats {
    $metaLines = Invoke-SshText -Ip $AttackerIp -Command "cat '$FloodMeta' 2>/dev/null || true" -AllowFailure
    $start = $null
    $end = $null

    foreach ($line in $metaLines) {
        if ($line -match '^ATTACK_START=(.+)$') { $start = Get-PlainTime $Matches[1] }
        if ($line -match '^ATTACK_END=(.+)$')   { $end = Get-PlainTime $Matches[1] }
    }

    $summary = Invoke-SshText -Ip $AttackerIp -Command "grep -E 'Raw packets sent:' '$NpingRawLog' | tail -n 1 || true" -AllowFailure |
        Select-Object -First 1

    $sent = $null
    $received = $null
    $lost = $null
    $loss = $null

    if ($summary -and $summary -match 'Raw packets sent:\s*(\d+).*Rcvd:\s*(\d+).*Lost:\s*(\d+)\s*\(([0-9.]+)%\)') {
        $sent = [int64]$Matches[1]
        $received = [int64]$Matches[2]
        $lost = [int64]$Matches[3]
        $loss = [double]::Parse($Matches[4],[System.Globalization.CultureInfo]::InvariantCulture)
    }

    return [pscustomobject]@{
        Start = $start
        End = $end
        Duration = (Delta $start $end)
        Sent = $sent
        Received = $received
        Lost = $lost
        LossPercent = $loss
        Summary = $summary
    }
}

# --------------------------------------------------
# Pokretanje napada i pracenje dogadaja
# --------------------------------------------------

# --------------------------------------------------
# VirtualBox helperi
# --------------------------------------------------

function Get-VBoxManagePath {
    $cmd = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $default = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
    if (Test-Path $default) { return $default }

    throw 'VBoxManage.exe nije pronaden. VirtualBox mora biti instaliran i VBoxManage dostupan.'
}

function Invoke-VBoxManageSafe {
    param(
        [string]$VBoxManage,
        [string[]]$Arguments
    )

    # Windows PowerShell 5.1 zna tekst koji VBoxManage pise na stderr
    # pretvoriti u NativeCommandError. Zato privremeno gasimo terminating
    # obradu i stvarni uspjeh/neuspjeh odredujemo iskljucivo po exit codeu.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'

    $output = @()
    $exitCode = 1

    try {
        $output = @(& $VBoxManage @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldEap
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Get-VmState {
    param(
        [string]$VBoxManage,
        [string]$VmName
    )

    $result = Invoke-VBoxManageSafe `
        -VBoxManage $VBoxManage `
        -Arguments @('showvminfo', $VmName, '--machinereadable')

    if ($result.ExitCode -ne 0) {
        throw "VirtualBox VM '$VmName' nije pronaden.`n$($result.Output -join "`n")"
    }

    $stateLine = $result.Output |
        Where-Object { $_ -match '^VMState=' } |
        Select-Object -First 1

    if ($stateLine -match '^VMState="([^"]+)"') {
        return $Matches[1]
    }

    return 'unknown'
}

function Wait-ForSsh {
    param(
        [string]$Ip,
        [int]$TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $probe = Invoke-SshText -Ip $Ip -Command 'echo SSH_OK' -AllowFailure | Select-Object -First 1
        if ($probe -eq 'SSH_OK') { return $true }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    return $false
}

$VBoxManage = Get-VBoxManagePath
$agentPoweredOffByScript = $false
$attackStarted = $false

try {
    Write-Host ''
    Write-Host '==================================================' -ForegroundColor Cyan
    Write-Host ' EKSPERIMENT 07 - NIDS + PRETHODNO POTVRDEN NODE_FAILURE' -ForegroundColor Cyan
    Write-Host (" MODE: {0}" -f $Mode) -ForegroundColor Cyan
    Write-Host (" CILJ: {0} ({1})" -f $TargetLabel,$TargetDataIp) -ForegroundColor Cyan
    Write-Host (" NAPAD: {0} pps | {1} s | oko {2} paketa" -f $PacketsPerSecond,$FloodDurationSeconds,$RequestedPacketCount) -ForegroundColor Cyan
    Write-Host (" VM: {0}" -f $AgentVmName) -ForegroundColor Cyan
    Write-Host '==================================================' -ForegroundColor Cyan

    # --------------------------------------------------
    # Preflight
    # --------------------------------------------------

    $vmState = Get-VmState -VBoxManage $VBoxManage -VmName $AgentVmName

    if ($vmState -eq 'poweroff' -or $vmState -eq 'saved') {
        Write-Host ("[VBOX] {0} state={1}; automatski pokrecem VM..." -f $AgentVmName,$vmState) -ForegroundColor Yellow
        $startResult = Invoke-VBoxManageSafe `
            -VBoxManage $VBoxManage `
            -Arguments @('startvm', $AgentVmName, '--type', 'headless')

        if ($startResult.ExitCode -ne 0) {
            throw "VBoxManage nije uspio pokrenuti VM '$AgentVmName' (exit=$($startResult.ExitCode)).`n$($startResult.Output -join "`n")"
        }

        if (-not (Wait-ForSsh -Ip $Agent01Ip -TimeoutSeconds 300)) {
            throw "VM '$AgentVmName' je pokrenut, ali SSH nije postao dostupan unutar 300 s."
        }

        $vmState = Get-VmState -VBoxManage $VBoxManage -VmName $AgentVmName
    }
    elseif ($vmState -ne 'running') {
        throw "VM '$AgentVmName' nije u podrzanom pocetnom stanju. Trenutno stanje: $vmState"
    }

    # I kad je VirtualBox stanje vec 'running', pricekaj da je agent-01 stvarno spreman.
    if (-not (Wait-ForSsh -Ip $Agent01Ip -TimeoutSeconds 300)) {
        throw "agent-01 VM je running, ali SSH nije dostupan unutar 300 s."
    }

    Write-Host ("[VBOX] {0} state=running | SSH=OK" -f $AgentVmName) -ForegroundColor DarkGray

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

    $npingProbe = Invoke-SshText -Ip $AttackerIp -Command "command -v nping >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1 && echo NPING_READY || echo NPING_NOT_READY" -AllowFailure |
        Select-Object -Last 1
    if ($npingProbe -ne 'NPING_READY') {
        throw 'ATTACKER nije spreman: potreban je nping i sudo -n.'
    }

    # --------------------------------------------------
    # response_mode + clean + start
    # --------------------------------------------------

    Write-Host ''
    Write-Host ("[CONFIG] response_mode -> {0}" -f $Mode) -ForegroundColor Yellow
    $config = Invoke-SshText -Ip $ServerIp -Command "cd /home/user/diplomski/server && sed -i -E 's/^response_mode:.*/response_mode: $Mode/' server.conf && grep '^response_mode:' server.conf"
    $config | ForEach-Object { Write-Host ("  {0}" -f $_) -ForegroundColor White }

    $serverLinesBeforeRestart = Get-LineCount -Ip $ServerIp -Path $ServerLog
    $baselineStart = 1

    Write-Host ''
    Write-Host '[CLEAN] Cistim stare procese, napad i DROP pravilo...' -ForegroundColor Yellow

    Invoke-SshText -Ip $ServerIp -Command "pkill -f '[s]erver.sh' 2>/dev/null || true; echo OK" | Out-Null
    Invoke-SshText -Ip $NidsIp -Command "sudo -n pkill -f '[n]ids.sh' 2>/dev/null || true; sudo -n pkill -f '[c]ontrol.sh' 2>/dev/null || true; echo OK" | Out-Null

    foreach ($ip in @($Agent01Ip,$Agent02Ip,$Agent03Ip)) {
        Invoke-SshText -Ip $ip -Command "sudo -n pkill -f '[a]gent.sh' 2>/dev/null || true; echo OK" | Out-Null
    }

    Invoke-SshText -Ip $AttackerIp -Command "sudo -n pkill -x nping 2>/dev/null || true; rm -f '$NpingPidFile' '$NpingRunner'; : > '$FloodLog'; : > '$FloodMeta'; : > '$NpingRawLog'; echo OK" | Out-Null

    Invoke-SshText -Ip $NidsIp -Command "while sudo -n iptables -C FORWARD -s $AttackerDataIp -m comment --comment diplomski-nids -j DROP 2>/dev/null; do sudo -n iptables -D FORWARD -s $AttackerDataIp -m comment --comment diplomski-nids -j DROP; done; echo FIREWALL_CLEAN" |
        ForEach-Object { Write-Host ("  {0}" -f $_) -ForegroundColor DarkGray }

    Start-Sleep -Seconds 1

    $serverCmd = "cd /home/user/diplomski/server; nohup bash ./server.sh >/tmp/exp07-server.log 2>&1 </dev/null & sleep 2; if pgrep -f '[s]erver.sh' >/dev/null; then echo COMPONENT_OK; else echo COMPONENT_FAIL; tail -n 20 /tmp/exp07-server.log; fi"
    $nidsCmd   = "cd /home/user/diplomski/nids; nohup sudo -n bash ./nids.sh >/tmp/exp07-nids.log 2>&1 </dev/null & sleep 3; if sudo -n pgrep -f '[n]ids.sh' >/dev/null; then echo COMPONENT_OK; else echo COMPONENT_FAIL; tail -n 20 /tmp/exp07-nids.log; fi"
    $agentCmd  = "cd /home/user/diplomski/agent; nohup sudo -n ./agent.sh >/tmp/exp07-agent.log 2>&1 </dev/null & sleep 3; if sudo -n pgrep -f '[a]gent.sh' >/dev/null; then echo COMPONENT_OK; else echo COMPONENT_FAIL; tail -n 20 /tmp/exp07-agent.log; fi"

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

    Write-Host ''
    Open-AllLiveLogWindows

    # --------------------------------------------------
    # Zdravi baseline
    # --------------------------------------------------

    Write-Host ''
    Write-Host '[BASELINE] Cekam HEARTBEAT + 2x HEALTHY za agent-01...' -ForegroundColor Yellow

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
        if (-not $p2) { $missing += 'agent-02 HEALTHY' }
        if (-not $p3) { $missing += 'agent-03 HEALTHY' }
        Write-Host ("  cekam: {0}" -f ($missing -join ', ')) -ForegroundColor DarkGray

        Start-Sleep -Seconds $PollSeconds
    }

    if (-not $hb -or -not $p2 -or -not $p3) {
        throw 'Nije dobiven potpuni HEALTHY baseline.'
    }

    Write-Host '[BASELINE OK]' -ForegroundColor Green
    Write-Host $hb -ForegroundColor White
    Write-Host $p2 -ForegroundColor White
    Write-Host $p3 -ForegroundColor White

    # --------------------------------------------------
    # Kontrolirani fault injection: poweroff cijelog VM-a
    # --------------------------------------------------

    $failureServerStart = (Get-LineCount -Ip $ServerIp -Path $ServerLog) + 1

    # Posljednji heartbeat neposredno prije gasenja.
    $lastHeartbeatBeforePoweroff = Get-LastMatch -Ip $ServerIp -Path $ServerLog -StartLine $baselineStart -Regex "\[HEARTBEAT\] HEARTBEAT agent-01( |$)"
    $lastHeartbeatTime = Get-LogTime $lastHeartbeatBeforePoweroff

    # Linux timestamp marker, jer Windows lokalni sat i Linux logovi mogu biti u razlicitim TZ.
    $poweroffMarkerText = Invoke-SshText -Ip $ServerIp -Command "date '+%Y-%m-%d %H:%M:%S.%3N'" |
        Select-Object -Last 1
    $poweroffMarkerTime = Get-PlainTime $poweroffMarkerText

    Write-Host ''
    Write-Host ("[FAULT] Gasim VirtualBox VM '{0}'..." -f $AgentVmName) -ForegroundColor Red

    $poweroffResult = Invoke-VBoxManageSafe `
        -VBoxManage $VBoxManage `
        -Arguments @('controlvm', $AgentVmName, 'poweroff')

    if ($poweroffResult.ExitCode -ne 0) {
        throw "VBoxManage nije uspio ugasiti VM '$AgentVmName' (exit=$($poweroffResult.ExitCode)).`n$($poweroffResult.Output -join "`n")"
    }

    $agentPoweredOffByScript = $true

    Start-Sleep -Seconds 2
    $stateAfter = Get-VmState -VBoxManage $VBoxManage -VmName $AgentVmName
    if ($stateAfter -ne 'poweroff') {
        throw "VM nije potvrdeno ugasen. Trenutno stanje: $stateAfter"
    }
    Write-Host '[FAULT] VM state=poweroff' -ForegroundColor Red

    # --------------------------------------------------
    # Cekanje NODE_FAILURE PRIJE napada
    # --------------------------------------------------

    $nodeFailureRegex = "\[(CORRELATION|RECOVERY)\].*NODE_FAILURE.*agent-01"
    $peerDegradedRegex = "\[PEER_STATE\].*target=agent-01.*state=DEGRADED"
    $peerUnreachableRegex = "\[PEER_STATE\].*target=agent-01.*state=UNREACHABLE"

    Write-Host ("[WAIT] Cekam potvrden NODE_FAILURE, max {0}s..." -f $NodeFailureTimeoutSeconds) -ForegroundColor Yellow

    $nodeDeadline = (Get-Date).AddSeconds($NodeFailureTimeoutSeconds)
    $nodeFailure = $null
    $peerDegraded = $null
    $peerUnreachable = $null

    while ((Get-Date) -lt $nodeDeadline) {
        if (-not $peerDegraded) {
            $peerDegraded = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $failureServerStart -Regex $peerDegradedRegex
            if ($peerDegraded) { Write-Host ("[EVENT] {0}" -f $peerDegraded) -ForegroundColor DarkYellow }
        }

        if (-not $peerUnreachable) {
            $peerUnreachable = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $failureServerStart -Regex $peerUnreachableRegex
            if ($peerUnreachable) { Write-Host ("[EVENT] {0}" -f $peerUnreachable) -ForegroundColor Red }
        }

        $nodeFailure = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $failureServerStart -Regex $nodeFailureRegex
        if ($nodeFailure) { break }

        Start-Sleep -Seconds 2
    }

    if (-not $nodeFailure) {
        throw "NODE_FAILURE nije potvrden unutar ${NodeFailureTimeoutSeconds}s. Napad NIJE pokrenut."
    }

    $nodeFailureTime = Get-LogTime $nodeFailure
    $poweroffToNodeFailure = Delta $poweroffMarkerTime $nodeFailureTime
    $lastHeartbeatToNodeFailure = Delta $lastHeartbeatTime $nodeFailureTime

    Write-Host '[NODE_FAILURE POTVRDEN PRIJE NAPADA]' -ForegroundColor Green
    Write-Host $nodeFailure -ForegroundColor White
    if ($null -ne $poweroffToNodeFailure) {
        Write-Host ("  poweroff marker -> NODE_FAILURE = {0:N3} s" -f $poweroffToNodeFailure) -ForegroundColor DarkGray
    }
    if ($null -ne $lastHeartbeatToNodeFailure) {
        Write-Host ("  last HEARTBEAT -> NODE_FAILURE = {0:N3} s" -f $lastHeartbeatToNodeFailure) -ForegroundColor DarkGray
    }

    # Osiguraj da je cilj i dalje ugasen neposredno prije napada.
    $stateBeforeAttack = Get-VmState -VBoxManage $VBoxManage -VmName $AgentVmName
    if ($stateBeforeAttack -ne 'poweroff') {
        throw "agent-01 vise nije u poweroff stanju prije napada: $stateBeforeAttack"
    }

    # Novi markeri: od ovog trenutka mjerimo samo reakciju na NIDS incident.
    $attackServerStart = (Get-LineCount -Ip $ServerIp -Path $ServerLog) + 1
    $attackNidsStart   = (Get-LineCount -Ip $NidsIp -Path $NidsLog) + 1

    Write-Host ''
    Write-Host '[OCEKIVANJE]' -ForegroundColor Cyan
    Write-Host '  NODE_FAILURE vec postoji prije napada.' -ForegroundColor White
    Write-Host '  Prvi NIDS_ALERT treba odmah dati BLOCK reason=ATTACK_WITH_NODE_FAILURE.' -ForegroundColor White
    Write-Host '  Ne ocekuje se ALERT_ONLY ni distribuirana HEALTHY potvrda.' -ForegroundColor White

    # --------------------------------------------------
    # Jedan kontrolirani ICMP burst
    # --------------------------------------------------

    Invoke-SshText -Ip $AttackerIp -Command "sudo -n pkill -x nping 2>/dev/null || true; rm -f '$NpingPidFile' '$NpingRunner'; : > '$FloodLog'; : > '$FloodMeta'; : > '$NpingRawLog'; echo READY" | Out-Null

    Write-Host ''
    Write-Host ("[ATTACK] nping target={0} rate={1}pps duration~{2}s packets={3}" -f $TargetDataIp,$PacketsPerSecond,$FloodDurationSeconds,$RequestedPacketCount) -ForegroundColor Red

    $attackStart = Start-IntensiveIcmpFlood
    $attackStarted = $true
    Write-Host ("[ATTACK_START] {0}" -f $attackStart.ToString('yyyy-MM-dd HH:mm:ss.fff')) -ForegroundColor Red

    # Pricekaj da runner zavrsi prirodno po broju paketa.
    $attackEndDeadline = (Get-Date).AddSeconds($MaxFloodSeconds + 5)
    do {
        $endMarker = Invoke-SshText -Ip $AttackerIp -Command "grep '^ATTACK_END=' '$FloodMeta' 2>/dev/null | tail -n 1 || true" -AllowFailure |
            Select-Object -First 1
        if ($endMarker) { break }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $attackEndDeadline)

    if (-not $endMarker) {
        Stop-IntensiveIcmpFlood -Reason 'runner timeout'
    }
    $attackStarted = $false

    # Daj serveru/control putu vremena da dovrsi BLOCK_RESULT.
    Start-Sleep -Seconds 3

    # --------------------------------------------------
    # Dohvat dogadaja
    # --------------------------------------------------

    $alertRegex = "\[NIDS_ALERT\].*type=ICMP_FLOOD.*src=$([regex]::Escape($AttackerDataIp)).*dst=$([regex]::Escape($TargetDataIp))"
    $firstDecisionRegex = "\[DECISION\].*host=agent-01.*src=$([regex]::Escape($AttackerDataIp)).*dst=$([regex]::Escape($TargetDataIp))"
    $expectedBlockRegex = "\[DECISION\].*action=BLOCK.*host=agent-01.*src=$([regex]::Escape($AttackerDataIp)).*dst=$([regex]::Escape($TargetDataIp)).*reason=ATTACK_WITH_NODE_FAILURE"
    $blockActionRegex = "\[BLOCK_ACTION\].*status=SUCCESS.*src_ip=$([regex]::Escape($AttackerDataIp))"
    $blockResultRegex = "\[BLOCK_RESULT\].*src=$([regex]::Escape($AttackerDataIp)).*status=SUCCESS"

    $nidsAlert = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $attackNidsStart -Regex $alertRegex
    $serverAlert = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $attackServerStart -Regex $alertRegex
    $firstDecision = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $attackServerStart -Regex $firstDecisionRegex
    $blockDecision = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $attackServerStart -Regex $expectedBlockRegex
    $blockAction = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $attackNidsStart -Regex $blockActionRegex
    $blockResult = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $attackServerStart -Regex $blockResultRegex

    # Ako async put jos nije dovrsen, pricekaj do 12 s.
    $eventDeadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $eventDeadline -and (-not $nidsAlert -or -not $serverAlert -or -not $blockDecision -or -not $blockAction -or -not $blockResult)) {
        if (-not $nidsAlert) {
            $nidsAlert = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $attackNidsStart -Regex $alertRegex
        }
        if (-not $serverAlert) {
            $serverAlert = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $attackServerStart -Regex $alertRegex
        }
        if (-not $firstDecision) {
            $firstDecision = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $attackServerStart -Regex $firstDecisionRegex
        }
        if (-not $blockDecision) {
            $blockDecision = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $attackServerStart -Regex $expectedBlockRegex
        }
        if (-not $blockAction) {
            $blockAction = Get-FirstMatch -Ip $NidsIp -Path $NidsLog -StartLine $attackNidsStart -Regex $blockActionRegex
        }
        if (-not $blockResult) {
            $blockResult = Get-FirstMatch -Ip $ServerIp -Path $ServerLog -StartLine $attackServerStart -Regex $blockResultRegex
        }
        Start-Sleep -Milliseconds 300
    }

    $flood = Get-FloodStats

    # --------------------------------------------------
    # Mjerenja
    # --------------------------------------------------

    $attackToNids = Delta $attackStart (Get-LogTime $nidsAlert)
    $nidsToServer = Delta (Get-LogTime $nidsAlert) (Get-LogTime $serverAlert)
    $serverAlertToBlockDecision = Delta (Get-LogTime $serverAlert) (Get-LogTime $blockDecision)
    $attackToBlockDecision = Delta $attackStart (Get-LogTime $blockDecision)
    $blockDecisionToBlockAction = Delta (Get-LogTime $blockDecision) (Get-LogTime $blockAction)
    $blockDecisionToBlockResult = Delta (Get-LogTime $blockDecision) (Get-LogTime $blockResult)

    $alertCountRaw = Invoke-SshText -Ip $ServerIp -Command "tail -n +$attackServerStart '$ServerLog' | grep -E '$alertRegex' | wc -l" -AllowFailure |
        Select-Object -Last 1
    $alertCount = 0
    if ($alertCountRaw -and $alertCountRaw.Trim() -match '^\d+$') {
        $alertCount = [int]$alertCountRaw.Trim()
    }

    $firewallRule = Invoke-SshText -Ip $NidsIp -Command "if sudo -n iptables -C FORWARD -s $AttackerDataIp -m comment --comment diplomski-nids -j DROP 2>/dev/null; then echo PRESENT; else echo MISSING; fi" -AllowFailure |
        Select-Object -Last 1
    $firewallRuleVerified = ($firewallRule -eq 'PRESENT')

    # --------------------------------------------------
    # Validacija
    # --------------------------------------------------

    $validationIssues = @()

    if (-not $nodeFailure) {
        $validationIssues += 'NODE_FAILURE nije bio potvrden prije napada.'
    }
    if (-not $nidsAlert) {
        $validationIssues += 'Nedostaje NIDS_ALERT.'
    }
    if (-not $serverAlert) {
        $validationIssues += 'Server nije evidentirao NIDS_ALERT.'
    }
    if (-not $firstDecision) {
        $validationIssues += 'Nedostaje DECISION zapis.'
    }
    elseif ($firstDecision -notmatch 'action=BLOCK' -or $firstDecision -notmatch 'reason=ATTACK_WITH_NODE_FAILURE') {
        $validationIssues += 'Prva odluka nije BLOCK reason=ATTACK_WITH_NODE_FAILURE.'
    }
    if (-not $blockDecision) {
        $validationIssues += 'Nedostaje ocekivana BLOCK odluka ATTACK_WITH_NODE_FAILURE.'
    }
    if (-not $blockAction) {
        $validationIssues += 'Nedostaje uspjesan BLOCK_ACTION.'
    }
    if (-not $blockResult) {
        $validationIssues += 'Nedostaje uspjesan BLOCK_RESULT.'
    }
    if (-not $firewallRuleVerified) {
        $validationIssues += 'DROP pravilo nije potvrdeno.'
    }

    $validRun = ($validationIssues.Count -eq 0)
    $outcome = if ($validRun) { 'NODE_FAILURE_FIRST_ALERT_BLOCK' } else { 'NODE_FAILURE_ATTACK_UNEXPECTED_OUTCOME' }
    $validationNote = if ($validRun) { 'OK' } else { $validationIssues -join ' | ' }

    # --------------------------------------------------
    # Rezultat
    # --------------------------------------------------

    Write-Host ''
    Write-Host '==================================================' -ForegroundColor Cyan
    Write-Host ' REZULTAT - NIDS + PRETHODNO POTVRDEN NODE_FAILURE' -ForegroundColor Cyan
    Write-Host '==================================================' -ForegroundColor Cyan
    Write-Host ("[OUTCOME] {0}" -f $outcome) -ForegroundColor $(if ($validRun) { 'Green' } else { 'Yellow' })
    Write-Host ("[NODE_FAILURE BEFORE ATTACK] {0}" -f ($null -ne $nodeFailure)) -ForegroundColor White
    Write-Host ("[SERVER ALERTS] {0}" -f $alertCount) -ForegroundColor White
    Write-Host ("[FIREWALL] DROP={0}" -f $(if ($firewallRuleVerified) { 'PRESENT' } else { 'MISSING' })) -ForegroundColor $(if ($firewallRuleVerified) { 'Green' } else { 'Red' })

    if ($null -ne $attackToNids) { Write-Host ("[M1] attack -> NIDS_ALERT = {0:N3} s" -f $attackToNids) -ForegroundColor Green }
    if ($null -ne $nidsToServer) { Write-Host ("[M2] NIDS_ALERT -> server alert = {0:N3} s" -f $nidsToServer) -ForegroundColor Green }
    if ($null -ne $serverAlertToBlockDecision) { Write-Host ("[M3] server alert -> BLOCK decision = {0:N3} s" -f $serverAlertToBlockDecision) -ForegroundColor Green }
    if ($null -ne $attackToBlockDecision) { Write-Host ("[M4] attack -> BLOCK decision = {0:N3} s" -f $attackToBlockDecision) -ForegroundColor Green }
    if ($null -ne $blockDecisionToBlockAction) { Write-Host ("[M5] BLOCK decision -> BLOCK_ACTION = {0:N3} s" -f $blockDecisionToBlockAction) -ForegroundColor Green }
    if ($null -ne $blockDecisionToBlockResult) { Write-Host ("[M6] BLOCK decision -> BLOCK_RESULT = {0:N3} s" -f $blockDecisionToBlockResult) -ForegroundColor Green }

    if ($validRun) {
        Write-Host '[VALIDACIJA] RUN OK: NODE_FAILURE je postojao prije napada, a prvi NIDS incident je odmah blokiran kao ATTACK_WITH_NODE_FAILURE.' -ForegroundColor Green
    }
    else {
        Write-Host ("[VALIDACIJA] RUN NIJE VALJAN: {0}" -f $validationNote) -ForegroundColor Yellow
    }

    # --------------------------------------------------
    # Dokazni logovi
    # --------------------------------------------------

    Write-Host ''
    Write-Host '[DOKAZ - FAILURE FAZA / SERVER]' -ForegroundColor Yellow
    Invoke-SshText -Ip $ServerIp -Command "tail -n +$failureServerStart '$ServerLog' | grep -E '\[(HEARTBEAT|PEER_STATE|CORRELATION|RECOVERY)\]' | head -n 180" -AllowFailure |
        ForEach-Object { Write-Host $_ -ForegroundColor White }

    Write-Host ''
    Write-Host '[DOKAZ - ATTACK FAZA / SERVER]' -ForegroundColor Yellow
    Invoke-SshText -Ip $ServerIp -Command "tail -n +$attackServerStart '$ServerLog' | grep -E '\[(NIDS_ALERT|CORRELATION|DECISION|ACTION|BLOCK_RESULT|BLOCK_STATE)\]' | tail -n 120" -AllowFailure |
        ForEach-Object { Write-Host $_ -ForegroundColor White }

    Write-Host ''
    Write-Host '[DOKAZ - NIDS]' -ForegroundColor Yellow
    Invoke-SshText -Ip $NidsIp -Command "tail -n +$attackNidsStart '$NidsLog' | grep -E '\[(NIDS_ALERT|BLOCK_REQUEST|BLOCK_ACTION|CONTROL_RESULT|WARNING|ERROR)\]' | tail -n 100" -AllowFailure |
        ForEach-Object { Write-Host $_ -ForegroundColor White }

    Write-Host ''
    Write-Host '[DOKAZ - ATTACKER]' -ForegroundColor Yellow
    Invoke-SshText -Ip $AttackerIp -Command "tail -n 35 '$FloodLog' 2>/dev/null; echo '--- META ---'; cat '$FloodMeta' 2>/dev/null || true" -AllowFailure |
        ForEach-Object { Write-Host $_ -ForegroundColor White }

    # --------------------------------------------------
    # CSV
    # --------------------------------------------------

    $resultsDir = Join-Path $PSScriptRoot 'rezultati'
    if (-not (Test-Path $resultsDir)) {
        New-Item -ItemType Directory -Path $resultsDir | Out-Null
    }

    $csv = Join-Path $resultsDir '07-nids-preconfirmed-node-failure.csv'

    [pscustomobject]@{
        run_time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        mode = $Mode
        scenario = 'nids_preconfirmed_node_failure'
        attack_tool = 'nping'
        target = $TargetLabel
        target_ip = $TargetDataIp
        agent_vm = $AgentVmName
        node_failure_confirmed_before_attack = ($null -ne $nodeFailure)
        poweroff_marker_time = if ($poweroffMarkerTime) { $poweroffMarkerTime.ToString('yyyy-MM-dd HH:mm:ss.fff') } else { $null }
        poweroff_to_node_failure_s = $poweroffToNodeFailure
        last_heartbeat_to_node_failure_s = $lastHeartbeatToNodeFailure
        packets_per_second_requested = $PacketsPerSecond
        flood_duration_requested_s = $FloodDurationSeconds
        packets_requested = $RequestedPacketCount
        flood_duration_actual_s = $flood.Duration
        packets_sent = $flood.Sent
        packets_received = $flood.Received
        packets_lost = $flood.Lost
        packet_loss_percent = $flood.LossPercent
        server_alerts = $alertCount
        attack_start_to_nids_alert_s = $attackToNids
        nids_alert_to_server_alert_s = $nidsToServer
        server_alert_to_block_decision_s = $serverAlertToBlockDecision
        attack_start_to_block_decision_s = $attackToBlockDecision
        block_decision_to_block_action_s = $blockDecisionToBlockAction
        block_decision_to_block_result_s = $blockDecisionToBlockResult
        last_heartbeat_line = $lastHeartbeatBeforePoweroff
        peer_degraded_line = $peerDegraded
        peer_unreachable_line = $peerUnreachable
        node_failure_line = $nodeFailure
        first_decision_line = $firstDecision
        block_decision_line = $blockDecision
        block_action_line = $blockAction
        block_result_line = $blockResult
        firewall_rule_verified = $firewallRuleVerified
        outcome = $outcome
        valid_run = $validRun
        validation_note = $validationNote
    } | Export-Csv -Path $csv -NoTypeInformation -Append -Encoding UTF8

    Write-Host ''
    Write-Host ("[CSV] {0}" -f $csv) -ForegroundColor Green
}
finally {
    Write-Host ''
    Write-Host '[CLEANUP] Zavrsni cleanup...' -ForegroundColor DarkGray

    try {
        Invoke-SshText -Ip $AttackerIp -Command "sudo -n pkill -x nping 2>/dev/null || true; rm -f '$NpingPidFile' '$NpingRunner'; echo ATTACK_CLEAN" -AllowFailure |
            ForEach-Object { Write-Host ("[CLEANUP] {0}" -f $_) -ForegroundColor DarkGray }
    } catch {}

    try {
        Invoke-SshText -Ip $NidsIp -Command "while sudo -n iptables -C FORWARD -s $AttackerDataIp -m comment --comment diplomski-nids -j DROP 2>/dev/null; do sudo -n iptables -D FORWARD -s $AttackerDataIp -m comment --comment diplomski-nids -j DROP; done; echo FIREWALL_CLEAN" -AllowFailure |
            ForEach-Object { Write-Host ("[CLEANUP] {0}" -f $_) -ForegroundColor DarkGray }
    } catch {}

    if ($agentPoweredOffByScript -and -not $LeaveAgentPoweredOff) {
        try {
            $state = Get-VmState -VBoxManage $VBoxManage -VmName $AgentVmName
            if ($state -eq 'poweroff') {
                Write-Host ("[RECOVERY] Ponovno pokrecem VM '{0}'..." -f $AgentVmName) -ForegroundColor Yellow
                $recoveryStartResult = Invoke-VBoxManageSafe `
                    -VBoxManage $VBoxManage `
                    -Arguments @('startvm', $AgentVmName, '--type', 'headless')

                if ($recoveryStartResult.ExitCode -eq 0) {
                    if (Wait-ForSsh -Ip $Agent01Ip -TimeoutSeconds 300) {
                        Write-Host '[RECOVERY] agent-01 SSH je ponovno dostupan.' -ForegroundColor Green
                    }
                    else {
                        Write-Host '[RECOVERY] VM je pokrenut, ali SSH nije postao dostupan unutar 300 s.' -ForegroundColor Yellow
                    }
                }
                else {
                    Write-Host ("[RECOVERY] VBoxManage startvm nije uspio (exit={0})." -f $recoveryStartResult.ExitCode) -ForegroundColor Yellow
                    $recoveryStartResult.Output |
                        ForEach-Object { Write-Host ("  {0}" -f $_) -ForegroundColor DarkGray }
                }
            }
        }
        catch {
            Write-Host ("[RECOVERY] Nije moguce automatski vratiti agent-01: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    elseif ($agentPoweredOffByScript -and $LeaveAgentPoweredOff) {
        Write-Host '[RECOVERY] -LeaveAgentPoweredOff je zadan; agent-01 ostaje ugasen.' -ForegroundColor Yellow
    }
}

Write-Host 'Eksperiment 07 zavrsen.' -ForegroundColor Green