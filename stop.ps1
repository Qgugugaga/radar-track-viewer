$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $root '.server.pid'
if (Test-Path $pidFile) {
    $serverPid = (Get-Content $pidFile -Raw).Trim()
    if ($serverPid) {
        Write-Host "正在停止开发服务器 (PID $serverPid)..." -ForegroundColor Yellow
        taskkill /PID $serverPid /T /F 2>$null
        Remove-Item $pidFile -Force
        Write-Host "已停止。"
    }
} else {
    Write-Host "未找到 .server.pid（服务器可能未运行，或已手动停止）。"
}
