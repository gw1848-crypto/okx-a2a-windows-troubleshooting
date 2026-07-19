$ErrorActionPreference = "Stop"

$requiredPaths = @(
    (Join-Path $env:USERPROFILE ".local\bin"),
    (Join-Path $env:ProgramFiles "nodejs"),
    (Join-Path $env:APPDATA "npm")
)
$env:Path = (($requiredPaths + $env:Path) | Where-Object { $_ }) -join ";"

$codexCommand = [Environment]::GetEnvironmentVariable(
    "OKX_A2A_AI_CODEX_COMMAND",
    "User"
)
$realCodexCommand = [Environment]::GetEnvironmentVariable(
    "OKX_A2A_REAL_CODEX_COMMAND",
    "User"
)
if ($codexCommand) {
    $env:OKX_A2A_AI_CODEX_COMMAND = $codexCommand
}
if ($realCodexCommand) {
    $env:OKX_A2A_REAL_CODEX_COMMAND = $realCodexCommand
}

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

Write-Host "`n== Dedicated Codex command =="
if ($codexCommand -and (Test-Path -LiteralPath $codexCommand)) {
    Write-Host "OK: $codexCommand"
} else {
    Write-Warning "A dedicated A2A Codex command is not configured or is missing."
}

$codexHome = Join-Path $env:USERPROFILE ".okx-agent-task\codex-home"
if (Test-Path -LiteralPath (Join-Path $codexHome "config.toml")) {
    Write-Host "OK: isolated CODEX_HOME configuration exists."
} else {
    Write-Warning "Isolated CODEX_HOME configuration is missing."
}

$taskSkill = Join-Path $env:USERPROFILE ".agents\skills\okx-agent-task\SKILL.md"
if ((Test-Path -LiteralPath $taskSkill) -and
    (Select-String -LiteralPath $taskSkill -Pattern "Inbound daemon sub-session skip" -Quiet)) {
    Write-Host "OK: inbound task preflight skip is present."
} else {
    Write-Warning "Inbound task preflight skip is missing; an update may have overwritten the local safeguard."
}

$guardBin = Join-Path $env:USERPROFILE ".okx-agent-task\guard-bin"
if ((Test-Path -LiteralPath (Join-Path $guardBin "okx-a2a.cmd")) -and
    (Test-Path -LiteralPath (Join-Path $guardBin "npm.cmd"))) {
    Write-Host "OK: inbound maintenance command guards exist."
} else {
    Write-Warning "Inbound maintenance command guards are missing."
}

Write-Host "`n== Watchdog =="
$watchdog = Join-Path $env:USERPROFILE ".okx-agent-task\watchdog\watchdog.ps1"
$runCommand = Get-ItemPropertyValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OKXA2AWatchdog" -ErrorAction SilentlyContinue
if ((Test-Path -LiteralPath $watchdog) -and $runCommand -like "*$watchdog*") {
    Write-Host "OK: user-level startup watchdog is registered."
} else {
    Write-Warning "Startup watchdog is missing or not registered."
}

Write-Host "`n== Daemon =="
okx-a2a daemon status

Write-Host "`n== Runtime binding =="
okx-a2a switch-runtime --json

Write-Host "`n== Agent communication =="
okx-a2a agent refresh --json

Write-Host "`n== Final setup =="
okx-a2a setup --json
