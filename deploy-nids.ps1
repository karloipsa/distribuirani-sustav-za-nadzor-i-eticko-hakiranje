$nids = "192.168.56.106"

$remotePath = "/home/user/diplomski/nids"

$files = Get-ChildItem ".\nids" -File |
Where-Object {
    $_.Extension -in ".sh", ".conf"
}

Write-Host ""
Write-Host "===== Deploy na NIDS ($nids) =====" -ForegroundColor Cyan

ssh "user@$nids" "mkdir -p $remotePath"

if ($LASTEXITCODE -ne 0) {
    Write-Host "Nije moguce pripremiti NIDS direktorij." -ForegroundColor Red
    exit 1
}

scp $files.FullName "user@$nids`:$remotePath/"

if ($LASTEXITCODE -ne 0) {
    Write-Host "Deploy nije uspio za NIDS." -ForegroundColor Red
    exit 1
}

ssh "user@$nids" "sed -i 's/\r$//' $remotePath/*.sh $remotePath/*.conf 2>/dev/null; chmod +x $remotePath/*.sh"

if ($LASTEXITCODE -ne 0) {
    Write-Host "chmod nije uspio na NIDS-u." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Deploy NIDS-a uspjesno zavrsen." -ForegroundColor Green