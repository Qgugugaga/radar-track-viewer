$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$port = 5180
$pidFile = Join-Path $root '.server.pid'
$logFile = Join-Path $root '.server.log'
$errFile = Join-Path $root '.server.err'

$busy = netstat -ano | Select-String ":$port\s"
if ($busy) {
    Write-Host "端口 $port 已有服务在监听（页面可能已在运行）：" -ForegroundColor Yellow
    $busy | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "正在后台启动开发服务器（端口 $port）..." -ForegroundColor Green
    $proc = Start-Process -FilePath 'npm.cmd' -ArgumentList @('run', 'dev') `
        -WorkingDirectory $root -WindowStyle Hidden `
        -RedirectStandardOutput $logFile -RedirectStandardError $errFile `
        -PassThru
    $proc.Id | Set-Content -Path $pidFile -Encoding ASCII
    Start-Sleep -Seconds 4
}

Write-Host ""
Write-Host "访问地址：" -ForegroundColor Cyan
Write-Host "  本机    http://127.0.0.1:$port/"
Write-Host "  本机    http://localhost:$port/"
$ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Select-Object -First 1 -ExpandProperty IPAddress
if ($ip) { Write-Host "  局域网  http://${ip}:$port/" }

if (Test-Path $errFile) {
    $err = Get-Content $errFile -Raw
    if ($err) {
        Write-Host ""
        Write-Host "启动日志 .server.err 有内容，请检查：" -ForegroundColor Yellow
        Write-Host $err
    }
}
