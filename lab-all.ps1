Add-Type -AssemblyName System.Windows.Forms

# ==================================================
# POSTAVKE
# ==================================================

# Manji font za svih 6 prozora.
# Ako bude premalo, promijeni samo 11 -> 12.
$FontSize = 11

# Širi buffer znači da se dugačke log linije neće
# odmah prelamati. Po potrebi koristi horizontalni scroll.
$BufferWidth = 190


# ==================================================
# WINDOW API
# ==================================================

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class LabWindowTools
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


# ==================================================
# RASPORED 3 x 2
# ==================================================

$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

$cellWidth  = [int]($area.Width / 3)
$cellHeight = [int]($area.Height / 2)


# ==================================================
# OTVARANJE LAB TERMINALA
# ==================================================

function Start-LabWindow {
    param (
        [string]$Title,
        [string]$Ip,
        [string]$RemoteCommand,
        [string]$Color,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height
    )

    $remoteCommand = $RemoteCommand -replace "`r", ""

    $remoteBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($remoteCommand)
    )

    $windowCommand = @"
`$Host.UI.RawUI.WindowTitle = '$Title'
`$Host.UI.RawUI.BackgroundColor = 'Black'
`$Host.UI.RawUI.ForegroundColor = '$Color'
Clear-Host


# --------------------------------------------------
# Font
# --------------------------------------------------

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class LabConsoleFont
{
    [StructLayout(LayoutKind.Sequential)]
    public struct COORD
    {
        public short X;
        public short Y;
    }

    [StructLayout(
        LayoutKind.Sequential,
        CharSet = CharSet.Unicode
    )]
    public struct CONSOLE_FONT_INFOEX
    {
        public uint cbSize;
        public uint nFont;
        public COORD dwFontSize;
        public int FontFamily;
        public int FontWeight;

        [MarshalAs(
            UnmanagedType.ByValTStr,
            SizeConst = 32
        )]
        public string FaceName;
    }

    [DllImport(
        "kernel32.dll",
        SetLastError = true
    )]
    private static extern IntPtr GetStdHandle(
        int nStdHandle
    );

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

    public static void SetFont(
        short size,
        string face
    )
    {
        CONSOLE_FONT_INFOEX info =
            new CONSOLE_FONT_INFOEX();

        info.cbSize =
            (uint)Marshal.SizeOf(info);

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
    [LabConsoleFont]::SetFont(
        $FontSize,
        'Cascadia Mono'
    )
}
catch {
}


# --------------------------------------------------
# Siri console buffer
# --------------------------------------------------

try {
    `$buffer = `$Host.UI.RawUI.BufferSize

    `$buffer.Width = $BufferWidth

    if (`$buffer.Height -lt 3000) {
        `$buffer.Height = 3000
    }

    `$Host.UI.RawUI.BufferSize = `$buffer
}
catch {
}


# --------------------------------------------------
# Header
# --------------------------------------------------

Write-Host '=================================================='
Write-Host ' DIPLOMSKI DISTRIBUTED IDPS LAB'
Write-Host ' NODE: $Title'
Write-Host ' IP:   $Ip'
Write-Host '=================================================='
Write-Host ''


# --------------------------------------------------
# SSH
# --------------------------------------------------

ssh -tt user@$Ip "echo '$remoteBase64' | base64 -d | bash"
"@

    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($windowCommand)
    )

    Start-Process conhost.exe -ArgumentList @(
        "powershell.exe",
        "-NoLogo",
        "-NoExit",
        "-EncodedCommand",
        $encodedCommand
    )

    $handle = [IntPtr]::Zero

    for ($attempt = 0; $attempt -lt 40; $attempt++) {

        Start-Sleep -Milliseconds 200

        $handle =
            [LabWindowTools]::FindWindowContaining(
                $Title
            )

        if ($handle -ne [IntPtr]::Zero) {
            break
        }
    }

    if ($handle -eq [IntPtr]::Zero) {

        Write-Warning `
            "Nisam pronasao prozor: $Title"

        return
    }

    # Daj terminalu vremena da postavi font, buffer i SSH sadržaj.
    Start-Sleep -Milliseconds 1200

    # Finalni resize nakon što conhost završi svoje interno preslagivanje.
    [LabWindowTools]::MoveWindow(
        $handle,
        $X,
        $Y,
        $Width,
        $Height,
        $true
    ) | Out-Null

    # Conhost ponekad još jednom promijeni geometriju nakon fonta.
    # Drugi resize osigurava konačan raspored.
    Start-Sleep -Milliseconds 300

    [LabWindowTools]::MoveWindow(
        $handle,
        $X,
        $Y,
        $Width,
        $Height,
    $true
) | Out-Null
}


# ==================================================
# SERVER
# ==================================================

Start-LabWindow `
    -Title "DIPLOMSKI-SERVER" `
    -Ip "192.168.56.101" `
    -Color "Green" `
    -X $area.Left `
    -Y $area.Top `
    -Width $cellWidth `
    -Height $cellHeight `
    -RemoteCommand @'
cd /home/user/diplomski/server || exit 1

if ! pgrep -f "[s]erver.sh" >/dev/null; then

    echo "[START] Pokrecem server..."

    nohup bash /home/user/diplomski/server/server.sh \
        </dev/null \
        >/dev/null \
        2>&1 &

else

    echo "[INFO] Server vec radi."

fi

SERVER_READY=0

for _ in {1..20}; do
    if ss -lnt 2>/dev/null |
       awk '{print $4}' |
       grep -qE '(:|\])5000$'; then

        SERVER_READY=1
        break
    fi

    sleep 0.25
done

if [[ "$SERVER_READY" == "1" ]]; then
    echo "[READY] Server listener spreman na portu 5000"
else
    echo "[ERROR] Server listener nije spreman na portu 5000"
    exit 1
fi

echo
echo "[LOG] /home/user/diplomski/server/log/promet.log"
echo "[INFO] CTRL+C = prekini log i ostani na SERVER shellu"
echo "--------------------------------------------------"

tail -n 30 -F \
    /home/user/diplomski/server/log/promet.log

echo
echo "[SHELL] Log pracenje zaustavljeno."
echo "[SHELL] Ostajes spojen na SERVER."
echo

export TERM=xterm-256color
export PS1='\[\e[92m\][\u@\h \W]\$ '

printf '\033[92m'

exec bash \
    --noprofile \
    --norc \
    -i \
    </dev/tty \
    >/dev/tty \
    2>/dev/tty
'@


# ==================================================
# NIDS
# ==================================================

Start-LabWindow `
    -Title "DIPLOMSKI-NIDS" `
    -Ip "192.168.56.106" `
    -Color "Green" `
    -X ($area.Left + $cellWidth) `
    -Y $area.Top `
    -Width $cellWidth `
    -Height $cellHeight `
    -RemoteCommand @'
cd /home/user/diplomski/nids || exit 1

if ! pgrep -f "[n]ids.sh" >/dev/null; then

    echo "[START] Pokrecem NIDS..."

    nohup sudo -n \
        bash /home/user/diplomski/nids/nids.sh \
        </dev/null \
        >/dev/null \
        2>&1 &

    sleep 2

else

    echo "[INFO] NIDS vec radi."

fi

echo
echo "[LOG] /home/user/diplomski/nids/log/nids.log"
echo "[INFO] CTRL+C = prekini log i ostani na NIDS shellu"
echo "--------------------------------------------------"

tail -n 30 -F \
    /home/user/diplomski/nids/log/nids.log

echo
echo "[SHELL] Log pracenje zaustavljeno."
echo "[SHELL] Ostajes spojen na NIDS."
echo

export TERM=xterm-256color
export PS1='\[\e[92m\][\u@\h \W]\$ '

printf '\033[92m'

exec bash \
    --noprofile \
    --norc \
    -i \
    </dev/tty \
    >/dev/tty \
    2>/dev/tty
'@


# ==================================================
# ATTACKER
# ==================================================

Start-LabWindow `
    -Title "DIPLOMSKI-ATTACKER" `
    -Ip "192.168.56.105" `
    -Color "Red" `
    -X ($area.Left + (2 * $cellWidth)) `
    -Y $area.Top `
    -Width $cellWidth `
    -Height $cellHeight `
    -RemoteCommand @'
echo
echo "=================================================="
echo " DIPLOMSKI ATTACKER"
echo " Management:     192.168.56.105"
echo " Attack network: 192.168.200.0/24"
echo "=================================================="
echo
echo "[READY] Attacker shell spreman."
echo

export TERM=xterm-256color
export PS1='\[\e[91m\][\u@\h \W]\$ '

printf '\033[91m'

exec bash \
    --noprofile \
    --norc \
    -i \
    </dev/tty \
    >/dev/tty \
    2>/dev/tty
'@


# ==================================================
# AGENTI
# ==================================================

$agents = @(

    @{
        Title = "DIPLOMSKI-AGENT-01"
        Ip    = "192.168.56.102"
        X     = $area.Left
    },

    @{
        Title = "DIPLOMSKI-AGENT-02"
        Ip    = "192.168.56.103"
        X     = $area.Left + $cellWidth
    },

    @{
        Title = "DIPLOMSKI-AGENT-03"
        Ip    = "192.168.56.104"
        X     = $area.Left + (2 * $cellWidth)
    }

)

foreach ($agent in $agents) {

    $agentName =
        $agent.Title.Replace(
            "DIPLOMSKI-",
            ""
        ).ToLower()

    Start-LabWindow `
        -Title $agent.Title `
        -Ip $agent.Ip `
        -Color "Green" `
        -X $agent.X `
        -Y ($area.Top + $cellHeight) `
        -Width $cellWidth `
        -Height $cellHeight `
        -RemoteCommand @"
cd /home/user/diplomski/agent || exit 1

if ! pgrep -f "[a]gent.sh" >/dev/null; then

    echo "[START] Pokrecem $agentName..."

    nohup sudo -n \
        /home/user/diplomski/agent/agent.sh \
        </dev/null \
        >/dev/null \
        2>&1 &

    sleep 3

else

    echo "[INFO] $agentName vec radi."

fi

echo
echo "[LOG] /home/user/diplomski/agent/log/agent.log"
echo "[INFO] CTRL+C = prekini log i ostani na $agentName shellu"
echo "--------------------------------------------------"

tail -n 30 -F \
    /home/user/diplomski/agent/log/agent.log

echo
echo "[SHELL] Log pracenje zaustavljeno."
echo "[SHELL] Ostajes spojen na $agentName."
echo

export TERM=xterm-256color
export PS1='\[\e[92m\][\u@\h \W]\$ '

printf '\033[92m'

exec bash \
    --noprofile \
    --norc \
    -i \
    </dev/tty \
    >/dev/tty \
    2>/dev/tty
"@
}


# ==================================================
# GOTOVO
# ==================================================

Write-Host ""
Write-Host "==================================================" `
    -ForegroundColor Green

Write-Host `
    " Lab pokrenut: server + NIDS + 3 agenta + attacker" `
    -ForegroundColor Green

Write-Host `
    " CTRL+C na log prozoru -> ostajes SSH spojen na VM" `
    -ForegroundColor Green

Write-Host "==================================================" `
    -ForegroundColor Green