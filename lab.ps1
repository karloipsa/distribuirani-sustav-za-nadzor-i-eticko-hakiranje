Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class WindowTools
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

$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

$halfWidth  = [int]($area.Width / 2)
$halfHeight = [int]($area.Height / 2)

$nodes = @(
    @{
        Title = "DIPLOMSKI-SERVER"
        Ip    = "192.168.56.101"
        X     = $area.Left
        Y     = $area.Top

        RemoteCommand = @'
cd /home/user/diplomski/server || exit 1

if ! pgrep -f "[s]erver.sh" >/dev/null; then
    echo "[START] Pokrecem server..."
    nohup bash /home/user/diplomski/server/server.sh \
        </dev/null >/dev/null 2>&1 &
    sleep 2
else
    echo "[INFO] Server vec radi."
fi

echo "[LOG] /home/user/diplomski/server/log/promet.log"
echo "--------------------------------------------------"

exec tail -n 25 -F /home/user/diplomski/server/log/promet.log
'@
    },

    @{
        Title = "DIPLOMSKI-AGENT-01"
        Ip    = "192.168.56.102"
        X     = $area.Left + $halfWidth
        Y     = $area.Top

        RemoteCommand = @'
cd /home/user/diplomski/agent || exit 1

if ! pgrep -f "[a]gent.sh" >/dev/null; then
    echo "[START] Pokrecem agent-01..."
    nohup sudo -n /home/user/diplomski/agent/agent.sh \
        </dev/null >/dev/null 2>&1 &
    sleep 3
else
    echo "[INFO] Agent-01 vec radi."
fi

echo "[LOG] /home/user/diplomski/agent/log/agent.log"
echo "--------------------------------------------------"

exec tail -n 25 -F /home/user/diplomski/agent/log/agent.log
'@
    },

    @{
        Title = "DIPLOMSKI-AGENT-02"
        Ip    = "192.168.56.103"
        X     = $area.Left
        Y     = $area.Top + $halfHeight

        RemoteCommand = @'
cd /home/user/diplomski/agent || exit 1

if ! pgrep -f "[a]gent.sh" >/dev/null; then
    echo "[START] Pokrecem agent-02..."
    nohup sudo -n /home/user/diplomski/agent/agent.sh \
        </dev/null >/dev/null 2>&1 &
    sleep 3
else
    echo "[INFO] Agent-02 vec radi."
fi

echo "[LOG] /home/user/diplomski/agent/log/agent.log"
echo "--------------------------------------------------"

exec tail -n 25 -F /home/user/diplomski/agent/log/agent.log
'@
    },

    @{
        Title = "DIPLOMSKI-AGENT-03"
        Ip    = "192.168.56.104"
        X     = $area.Left + $halfWidth
        Y     = $area.Top + $halfHeight

        RemoteCommand = @'
cd /home/user/diplomski/agent || exit 1

if ! pgrep -f "[a]gent.sh" >/dev/null; then
    echo "[START] Pokrecem agent-03..."
    nohup sudo -n /home/user/diplomski/agent/agent.sh \
        </dev/null >/dev/null 2>&1 &
    sleep 3
else
    echo "[INFO] Agent-03 vec radi."
fi

echo "[LOG] /home/user/diplomski/agent/log/agent.log"
echo "--------------------------------------------------"

exec tail -n 25 -F /home/user/diplomski/agent/log/agent.log
'@
    }
)

foreach ($node in $nodes) {

    # Uklanja Windows CR znakove prije slanja Bashu.
    $remoteCommand = $node.RemoteCommand -replace "`r", ""

    # Bash skriptu šaljemo kao Base64 da navodnici i novi redci ne eksplodiraju.
    $remoteBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($remoteCommand)
    )

    $windowCommand = @"
`$Host.UI.RawUI.WindowTitle = '$($node.Title)'
`$Host.UI.RawUI.BackgroundColor = 'Black'
`$Host.UI.RawUI.ForegroundColor = 'Green'
Clear-Host

Write-Host '==================================================' -ForegroundColor DarkGreen
Write-Host ' DIPLOMSKI NETWORK MONITORING LAB' -ForegroundColor Green
Write-Host ' NODE: $($node.Title)' -ForegroundColor Green
Write-Host ' IP:   $($node.Ip)' -ForegroundColor DarkGreen
Write-Host '==================================================' -ForegroundColor DarkGreen
Write-Host ''

ssh -tt user@$($node.Ip) "echo '$remoteBase64' | base64 -d | bash"
"@

    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($windowCommand)
    )

    # conhost.exe prisiljava četiri stvarna, odvojena prozora.
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

        $handle = [WindowTools]::FindWindowContaining($node.Title)

        if ($handle -ne [IntPtr]::Zero) {
            break
        }
    }

    if ($handle -eq [IntPtr]::Zero) {
        Write-Warning "Nisam pronasao prozor: $($node.Title)"
        continue
    }

    [WindowTools]::MoveWindow(
        $handle,
        $node.X,
        $node.Y,
        $halfWidth,
        $halfHeight,
        $true
    ) | Out-Null
}