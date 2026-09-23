$nodes = @(

    @{
        Name = "SERVER"
        Ip   = "192.168.56.101"
        Path = "/home/user/diplomski/server"
    },

    @{
        Name = "NIDS"
        Ip   = "192.168.56.106"
        Path = "/home/user/diplomski/nids"
    },

    @{
        Name = "AGENT-01"
        Ip   = "192.168.56.102"
        Path = "/home/user/diplomski/agent"
    },

    @{
        Name = "AGENT-02"
        Ip   = "192.168.56.103"
        Path = "/home/user/diplomski/agent"
    },

    @{
        Name = "AGENT-03"
        Ip   = "192.168.56.104"
        Path = "/home/user/diplomski/agent"
    }

)

foreach ($node in $nodes) {

    Write-Host ""

    Write-Host "===== Gasim $($node.Name) =====" -ForegroundColor Cyan

    ssh -tt "user@$($node.Ip)" `
        "cd $($node.Path) && sudo bash ./clean.sh"

    if ($LASTEXITCODE -eq 0) {

        Write-Host "$($node.Name) ugasen." -ForegroundColor Green

    }
    else {

        Write-Host "Greska prilikom gasenja $($node.Name)." -ForegroundColor Red

    }
}

Write-Host ""

Write-Host "==========================================" -ForegroundColor Green
Write-Host " Laboratorij uspjesno ugasen i ociscen." -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green