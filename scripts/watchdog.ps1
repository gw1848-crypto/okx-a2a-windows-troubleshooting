param(
    [switch]$Once,
    [int]$IntervalSeconds = 60
)

$ErrorActionPreference = "Stop"
$root = Join-Path $env:USERPROFILE ".okx-agent-task"
$logDir = Join-Path $root "logs"
$logPath = Join-Path $logDir "watchdog.log"
$backupPath = Join-Path $root "safeguards\okx-agent-task-SKILL.md"
$taskSkill = Join-Path $env:USERPROFILE ".agents\skills\okx-agent-task\SKILL.md"
$requiredMarker = "Inbound daemon sub-session skip"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Write-Log([string]$Message) {
    Add-Content -LiteralPath $logPath -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -Encoding UTF8
}

function Initialize-Environment {
    $paths = @((Join-Path $env:USERPROFILE ".local\bin"), (Join-Path $env:ProgramFiles "nodejs"), (Join-Path $env:APPDATA "npm"))
    $env:Path = (($paths + $env:Path) | Where-Object { $_ }) -join ";"
    foreach ($name in @("OKX_A2A_AI_CODEX_COMMAND", "OKX_A2A_REAL_CODEX_COMMAND")) {
        $value = [Environment]::GetEnvironmentVariable($name, "User")
        if ($value) { Set-Item -Path "Env:$name" -Value $value }
    }
}

function Get-SkillVersion([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $match = Select-String -LiteralPath $Path -Pattern '^\s*version:\s*"?([^"\s]+)' | Select-Object -First 1
    if ($match) { return $match.Matches[0].Groups[1].Value }
    return $null
}

function Repair-SkillSafeguard {
    $markerPresent = (Test-Path -LiteralPath $taskSkill) -and (Select-String -LiteralPath $taskSkill -Pattern $requiredMarker -Quiet)
    if ($markerPresent) { return $true }
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Write-Log "ERROR inbound safeguard is missing and no backup is available"
        return $false
    }
    $currentVersion = Get-SkillVersion $taskSkill
    $backupVersion = Get-SkillVersion $backupPath
    if (-not $currentVersion -or $currentVersion -ne $backupVersion) {
        Write-Log "ERROR inbound safeguard missing; version mismatch current=$currentVersion backup=$backupVersion"
        return $false
    }
    Copy-Item -LiteralPath $backupPath -Destination $taskSkill -Force
    Write-Log "RECOVERED inbound safeguard from same-version backup ($backupVersion)"
    return $true
}

function Invoke-A2A([string[]]$Arguments) {
    $launcher = Join-Path $env:APPDATA "npm\okx-a2a.cmd"
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $launcher @Arguments 2>&1 | ForEach-Object { $_.ToString() }
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Text = ($output -join "`n")
        }
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Convert-A2AJson([string]$Text) {
    $jsonLine = $Text -split "`r?`n" |
        Where-Object { $_.TrimStart().StartsWith("{") -and $_.TrimEnd().EndsWith("}") } |
        Select-Object -First 1
    if (-not $jsonLine) { throw "No JSON object was found in command output." }
    return $jsonLine | ConvertFrom-Json
}

function Invoke-Setup {
    $result = Invoke-A2A @("setup", "--json")
    if ($result.ExitCode -ne 0) {
        Write-Log "ERROR setup failed: $($result.Text.Trim())"
        return $false
    }
    try {
        $json = Convert-A2AJson $result.Text
        if (-not $json.ok -or $json.providerCommand -ne $env:OKX_A2A_AI_CODEX_COMMAND) {
            Write-Log "ERROR provider binding mismatch: $($json.providerCommand)"
            return $false
        }
        Write-Log "OK provider binding verified"
        return $true
    } catch {
        Write-Log "ERROR setup returned invalid JSON"
        return $false
    }
}

function Get-ActiveClients {
    $result = Invoke-A2A @("agent", "refresh", "--json")
    if ($result.ExitCode -ne 0) { return -1 }
    try {
        $json = Convert-A2AJson $result.Text
        if (-not $json.ok) { return -1 }
        return [int]$json.payload.activeClients
    } catch { return -1 }
}

Initialize-Environment
$created = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\OKXA2AWatchdog", [ref]$created)
if (-not $created) { exit 0 }

try {
    Write-Log "START watchdog pid=$PID"
    Repair-SkillSafeguard | Out-Null
    Invoke-Setup | Out-Null
    $consecutiveFailures = 0
    do {
        try {
            $status = Invoke-A2A @("daemon", "status")
            if ($status.ExitCode -ne 0 -or $status.Text -notmatch '\brunning\b') {
                Write-Log "RECOVER daemon was not running"
                Invoke-A2A @("daemon", "start") | Out-Null
                Start-Sleep -Seconds 3
                Invoke-Setup | Out-Null
            }
            $activeClients = Get-ActiveClients
            if ($activeClients -ge 1) {
                if ($consecutiveFailures -gt 0) { Write-Log "OK communication recovered activeClients=$activeClients" }
                $consecutiveFailures = 0
            } else {
                $consecutiveFailures++
                Write-Log "WARN communication check failed count=$consecutiveFailures activeClients=$activeClients"
                if ($consecutiveFailures -ge 2) {
                    Invoke-A2A @("daemon", "restart") | Out-Null
                    Start-Sleep -Seconds 3
                    Invoke-Setup | Out-Null
                    $consecutiveFailures = 0
                }
            }
            Repair-SkillSafeguard | Out-Null
        } catch { Write-Log "ERROR $($_.Exception.Message)" }
        if (-not $Once) { Start-Sleep -Seconds $IntervalSeconds }
    } while (-not $Once)
} finally {
    Write-Log "STOP watchdog pid=$PID"
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
