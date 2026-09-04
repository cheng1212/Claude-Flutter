# 延时重启 zcode-server:当前会话进程挂在旧服务器树下,必须等本轮说完话再动手。
$log = "D:\cheng\zcode\server\server-restart.log"
"[$(Get-Date -Format 'HH:mm:ss')] restart scheduled, waiting 90s..." | Out-File $log -Encoding utf8
Start-Sleep -Seconds 90
$owner = Get-NetTCPConnection -LocalPort 5190 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty OwningProcess
if ($owner) {
  "[$(Get-Date -Format 'HH:mm:ss')] killing old server pid=$owner (tree)" | Out-File $log -Append -Encoding utf8
  taskkill /PID $owner /T /F 2>&1 | Out-File $log -Append -Encoding utf8
  Start-Sleep -Seconds 3
}
Start-Process -FilePath "C:\nvm4w\nodejs\npm.cmd" -ArgumentList "start" `
  -WorkingDirectory "D:\cheng\zcode\server" -WindowStyle Hidden `
  -RedirectStandardOutput "D:\cheng\zcode\server\server-run.log" `
  -RedirectStandardError "D:\cheng\zcode\server\server-run.err.log"
$ok = $false
foreach ($i in 1..40) {
  Start-Sleep -Seconds 1
  if (Get-NetTCPConnection -LocalPort 5190 -State Listen -ErrorAction SilentlyContinue) { $ok = $true; break }
}
"[$(Get-Date -Format 'HH:mm:ss')] new server up=$ok (waited ${i}s)" | Out-File $log -Append -Encoding utf8
