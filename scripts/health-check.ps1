$ErrorActionPreference = "Stop"

Write-Host "== Runtime =="
node --version
npm --version
okx-a2a --version

Write-Host "`n== Windows native launcher =="
$launcher = Join-Path $env:APPDATA "npm\okx-a2a.exe"
if (Test-Path -LiteralPath $launcher) {
    Write-Host "OK: $launcher"
} else {
    Write-Warning "Missing: $launcher"
    Write-Host "Run: okx-a2a doctor --fix"
}

Write-Host "`n== Daemon =="
okx-a2a daemon status

Write-Host "`n== Runtime binding =="
okx-a2a switch-runtime --json

Write-Host "`n== Agent communication =="
okx-a2a agent refresh --json

Write-Host "`n== Final setup =="
okx-a2a setup --json
