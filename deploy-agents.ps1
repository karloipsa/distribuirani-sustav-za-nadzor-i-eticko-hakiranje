$agents = @(
    "192.168.56.102",
    "192.168.56.103",
    "192.168.56.104"
)

$remotePath = "/home/user/diplomski/agent"

$files = Get-ChildItem ".\agent" -File |
    Where-Object {
        $_.Extension -eq ".sh"
    }

foreach ($agent in $agents) {

    Write-Host ""
    Write-Host "===== Deploy na $agent =====" -ForegroundColor Cyan

    scp $files.FullName "user@$agent`:$remotePath/"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Deploy nije uspio za $agent" -ForegroundColor Red
        exit 1
    }

    ssh "user@$agent" "chmod +x $remotePath/*.sh"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "chmod nije uspio za $agent" -ForegroundColor Red
        exit 1
    }

    Write-Host "Deploy i chmod uspjesni za $agent" -ForegroundColor Green
}

Write-Host ""
Write-Host "Deploy uspjesno zavrsen na sva tri agenta." -ForegroundColor Green