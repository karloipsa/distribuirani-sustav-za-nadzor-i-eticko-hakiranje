$serverIp = "192.168.56.101"
$remotePath = "/home/user/diplomski/server"

$files = Get-ChildItem ".\server" -File |
    Where-Object {
        $_.Extension -eq ".sh" -or
        $_.Name -eq "server.conf" -or
        $_.Name -eq "dozvoljeni_agenti.txt"
    }

scp $files.FullName "user@$serverIp`:$remotePath/"
scp -r ".\server\handlers" "user@$serverIp`:$remotePath/"