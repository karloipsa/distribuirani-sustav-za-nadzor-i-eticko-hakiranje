$ErrorActionPreference = "Stop"

$localScript = ".\setup-hosts.sh"
$remoteScript = "/home/user/diplomski/setup-hosts.sh"

$targets = @(
    @{ Name = "server";   IP = "192.168.56.101" },
    @{ Name = "agent-01"; IP = "192.168.56.102" },
    @{ Name = "agent-02"; IP = "192.168.56.103" },
    @{ Name = "agent-03"; IP = "192.168.56.104" },
    @{ Name = "nids";     IP = "192.168.56.106" }
)

if (-not (Test-Path $localScript)) {
    Write-Host "FAIL: Ne postoji $localScript" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " DIPLOMSKI - SETUP /etc/hosts"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

foreach ($target in $targets) {

    $name = $target.Name
    $ip = $target.IP

    Write-Host "===== $name ($ip) =====" -ForegroundColor Cyan

    # Provjera SSH dostupnosti
    $sshTest = Test-NetConnection $ip -Port 22 -WarningAction SilentlyContinue

    if (-not $sshTest.TcpTestSucceeded) {
        Write-Host "FAIL: SSH nije dostupan na $ip`:22" -ForegroundColor Red
        exit 1
    }

    Write-Host "PASS: SSH dostupan" -ForegroundColor Green

    # Kopiranje setup-hosts.sh
    scp $localScript "user@$ip`:$remoteScript"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: scp nije uspio za $name ($ip)" -ForegroundColor Red
        exit 1
    }

    Write-Host "PASS: setup-hosts.sh kopiran" -ForegroundColor Green

    # Sintaksna provjera
    ssh "user@$ip" "bash -n $remoteScript"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: bash -n nije prosao na $name" -ForegroundColor Red
        exit 1
    }

    Write-Host "PASS: bash sintaksa OK" -ForegroundColor Green

    # Izvršavanje kao root.
    # -t osigurava terminal ako sudo zatraži lozinku.
    ssh -t "user@$ip" "sudo bash $remoteScript"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAIL: setup-hosts.sh nije prosao na $name" -ForegroundColor Red
        exit 1
    }

    Write-Host "PASS: $name konfiguriran" -ForegroundColor Green
    Write-Host ""
}

Write-Host "========================================" -ForegroundColor Green
Write-Host " PASS: /etc/hosts konfiguriran na svim VM-ovima"
Write-Host "========================================" -ForegroundColor Green