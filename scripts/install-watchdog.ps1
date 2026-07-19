$ErrorActionPreference = "Stop"
$source = Join-Path $PSScriptRoot "watchdog.ps1"
$targetDir = Join-Path $env:USERPROFILE ".okx-agent-task\watchdog"
$target = Join-Path $targetDir "watchdog.ps1"
$backupDir = Join-Path $env:USERPROFILE ".okx-agent-task\safeguards"
$skill = Join-Path $env:USERPROFILE ".agents\skills\okx-agent-task\SKILL.md"
$backup = Join-Path $backupDir "okx-agent-task-SKILL.md"
New-Item -ItemType Directory -Force -Path $targetDir, $backupDir | Out-Null
Copy-Item -LiteralPath $source -Destination $target -Force
Copy-Item -LiteralPath $skill -Destination $backup -Force
$command = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $target
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
New-Item -Path $runKey -Force | Out-Null
Set-ItemProperty -Path $runKey -Name "OKXA2AWatchdog" -Value $command
$escapedTarget = [regex]::Escape($target)
$existing = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -match ("(?i)-File\s+`"?{0}`"?(\s|$)" -f $escapedTarget) }
if (-not $existing) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"{0}"' -f $target))
}
Write-Host "Installed user-level startup watchdog: $target"
