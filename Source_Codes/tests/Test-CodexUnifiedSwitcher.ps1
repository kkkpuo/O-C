$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "tools\CodexUnifiedSwitcher.ps1"
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing unified switcher script: $scriptPath"
}

. $scriptPath -NoUi

$requiredFunctions = @(
    "Get-CodexProvider",
    "Save-ModeProfile",
    "Invoke-HistoryProviderSync",
    "Merge-CodexSharedConfigSections",
    "Switch-CodexProfileMode"
)
foreach ($name in $requiredFunctions) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Missing required function: $name"
    }
}

$python = Get-PythonSqliteRunner
if (-not $python) {
    throw "Python 3 with sqlite3 is required for this test"
}

function Invoke-TestPythonSqlite($DatabasePath, $Sql, [switch]$Scalar) {
    $pythonScript = @'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
try:
    if sys.argv[2] == 'scalar':
        value = connection.execute(sys.argv[3]).fetchone()[0]
        print(value)
    else:
        connection.executescript(sys.argv[3])
        connection.commit()
finally:
    connection.close()
'@
    $mode = if ($Scalar) { "scalar" } else { "script" }
    $pythonArgs = @($python.PrefixArgs) + @("-c", $pythonScript, $DatabasePath, $mode, $Sql)
    $result = Invoke-NativeCommandCapture -FilePath $python.Source -Arguments $pythonArgs
    if ($result.ExitCode -ne 0) {
        throw (($result.Output | Out-String).Trim())
    }
    return (($result.Output | Out-String).Trim())
}

$root = Join-Path $env:TEMP ("codex-unified-switch-test-" + [guid]::NewGuid().ToString("N"))
$codexHome = Join-Path $root ".codex"
$appRoot = Join-Path $root "app"
$historyBackupRoot = Join-Path $root "history-sync"
$officialConfig = Join-Path $root "official-config.toml"
$cpamcConfig = Join-Path $root "cpamc-config.toml"

New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $codexHome "sessions") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $appRoot "profiles\cpamc") -Force | Out-Null

Set-Content -LiteralPath $officialConfig -Encoding UTF8 -Value @"
model_provider = "openai"

[plugins."official-only@personal"]
enabled = true
"@
Set-Content -LiteralPath $cpamcConfig -Encoding UTF8 -Value @"
model_provider = "MyOpenAI"

[model_providers.MyOpenAI]
name = "MyOpenAI"
requires_openai_auth = false

[plugins."cpamc-only@personal"]
enabled = true
"@
Set-Content -LiteralPath (Join-Path $codexHome "config.toml") -Encoding UTF8 -Value @"
$(Get-Content -LiteralPath $officialConfig -Raw)

[marketplaces.ponytail]
source_type = "local"
source = "D:\Codex_project\ponytail"

[plugins."ponytail@ponytail"]
enabled = true

[plugins."codegraph@personal"]
enabled = true

[mcp_servers.codegraph]
command = "codegraph"

[hooks.state."ponytail@ponytail:hooks/test.json:session_start:0:0"]
trusted_hash = "sha256:test"
"@
Set-Content -LiteralPath (Join-Path $codexHome "auth.json") -Encoding UTF8 -Value '{"auth_mode":"chatgpt"}'
Set-Content -LiteralPath (Join-Path $appRoot "profiles\cpamc\auth.json") -Encoding UTF8 -Value '{"OPENAI_API_KEY":"test-api-key"}'
Copy-Item -LiteralPath $cpamcConfig -Destination (Join-Path $appRoot "profiles\cpamc\config.toml") -Force

$rolloutPath = Join-Path $codexHome "sessions\rollout-a.jsonl"
$firstLine = '{"timestamp":"2026-06-08T00:00:00.000Z","type":"session_meta","payload":{"id":"thread-a","cwd":"C:\\Work","source":"cli","model_provider":"openai"}}'
Set-Content -LiteralPath $rolloutPath -Encoding UTF8 -Value ($firstLine + "`n" + '{"type":"event_msg","payload":{"type":"user_message","message":"hello"}}')

$dbPath = Join-Path $codexHome "state_5.sqlite"
Invoke-TestPythonSqlite `
    -DatabasePath $dbPath `
    -Sql "CREATE TABLE threads(id TEXT PRIMARY KEY, model_provider TEXT, archived INTEGER DEFAULT 0); INSERT INTO threads(id, model_provider, archived) VALUES('thread-a', 'openai', 0);"

try {
    $cpamcResult = Switch-CodexProfileMode `
        -Target "CPAMC" `
        -CodexHome $codexHome `
        -OfficialConfigPath $officialConfig `
        -CPAMCConfigPath $cpamcConfig `
        -AppRoot $appRoot `
        -HistoryBackupRoot $historyBackupRoot `
        -SkipProcessCheck

    if ($cpamcResult.TargetProvider -ne "MyOpenAI") {
        throw "Expected CPAMC target provider MyOpenAI, got $($cpamcResult.TargetProvider)"
    }
    if ($cpamcResult.CodexRestart.Started -or $cpamcResult.CodexRestart.Warning) {
        throw "SkipProcessCheck must not start Codex or return a restart warning"
    }
    if (-not $cpamcResult.PostSync.BackupDir.StartsWith($historyBackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Expected CPAMC history backup under temp history root, got $($cpamcResult.PostSync.BackupDir)"
    }
    if ((Get-CodexProvider -CodexHome $codexHome) -ne "MyOpenAI") {
        throw "Expected config provider MyOpenAI after CPAMC switch"
    }
    if ((Get-CodexAuthKind -CodexHome $codexHome) -ne "api") {
        throw "Expected API-key auth after CPAMC switch"
    }
    $cpamcConfigAfterSwitch = Get-Content -LiteralPath (Join-Path $codexHome "config.toml") -Raw
    foreach ($expected in @(
        '[plugins."ponytail@ponytail"]',
        '[plugins."codegraph@personal"]',
        '[plugins."official-only@personal"]',
        '[plugins."cpamc-only@personal"]',
        '[mcp_servers.codegraph]',
        '[hooks.state."ponytail@ponytail:hooks/test.json:session_start:0:0"]'
    )) {
        if (-not $cpamcConfigAfterSwitch.Contains($expected)) {
            throw "Expected shared config section after CPAMC switch: $expected"
        }
    }
    if ((Get-Content -LiteralPath $rolloutPath -Raw) -notmatch '"model_provider"\s*:\s*"MyOpenAI"') {
        throw "Expected rollout provider MyOpenAI after CPAMC switch"
    }
    $dbProvider = Invoke-TestPythonSqlite `
        -DatabasePath $dbPath `
        -Sql "SELECT model_provider FROM threads WHERE id='thread-a';" `
        -Scalar
    if ($dbProvider -ne "MyOpenAI") {
        throw "Expected SQLite provider MyOpenAI after CPAMC switch, got $dbProvider"
    }
    $cpamcBackupDb = Join-Path $cpamcResult.PostSync.BackupDir "state_5.sqlite"
    if (-not (Test-Path -LiteralPath $cpamcBackupDb)) {
        throw "Expected consistent SQLite backup before CPAMC sync"
    }
    $cpamcBackupProvider = Invoke-TestPythonSqlite `
        -DatabasePath $cpamcBackupDb `
        -Sql "SELECT model_provider FROM threads WHERE id='thread-a';" `
        -Scalar
    if ($cpamcBackupProvider -ne "openai") {
        throw "Expected CPAMC backup to preserve openai provider, got $cpamcBackupProvider"
    }

    $oauthResult = Switch-CodexProfileMode `
        -Target "OAuth" `
        -CodexHome $codexHome `
        -OfficialConfigPath $officialConfig `
        -CPAMCConfigPath $cpamcConfig `
        -AppRoot $appRoot `
        -HistoryBackupRoot $historyBackupRoot `
        -SkipProcessCheck

    if ($oauthResult.TargetProvider -ne "openai") {
        throw "Expected OAuth target provider openai, got $($oauthResult.TargetProvider)"
    }
    if ($oauthResult.CodexRestart.Started -or $oauthResult.CodexRestart.Warning) {
        throw "SkipProcessCheck must not start Codex or return a restart warning"
    }
    if (-not $oauthResult.PostSync.BackupDir.StartsWith($historyBackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Expected OAuth history backup under temp history root, got $($oauthResult.PostSync.BackupDir)"
    }
    if ((Get-CodexProvider -CodexHome $codexHome) -ne "openai") {
        throw "Expected config provider openai after OAuth switch"
    }
    $oauthConfigAfterSwitch = Get-Content -LiteralPath (Join-Path $codexHome "config.toml") -Raw
    foreach ($expected in @(
        '[plugins."ponytail@ponytail"]',
        '[plugins."codegraph@personal"]',
        '[plugins."official-only@personal"]',
        '[plugins."cpamc-only@personal"]',
        '[mcp_servers.codegraph]',
        '[hooks.state."ponytail@ponytail:hooks/test.json:session_start:0:0"]'
    )) {
        if (-not $oauthConfigAfterSwitch.Contains($expected)) {
            throw "Expected shared config section after OAuth switch: $expected"
        }
    }
    if ((Get-Content -LiteralPath (Join-Path $codexHome "auth.json") -Raw) -notmatch '"auth_mode"\s*:\s*"chatgpt"') {
        throw "Expected restored OpenAI auth after OAuth switch"
    }
    if ((Get-ChildItem -LiteralPath $codexHome -Filter "auth.json.api-before-oauth-*" -ErrorAction SilentlyContinue).Count -lt 1) {
        throw "Expected API auth to be moved aside before OAuth"
    }
    if ((Get-Content -LiteralPath $rolloutPath -Raw) -notmatch '"model_provider"\s*:\s*"openai"') {
        throw "Expected rollout provider openai after OAuth switch"
    }
    $dbProvider = Invoke-TestPythonSqlite `
        -DatabasePath $dbPath `
        -Sql "SELECT model_provider FROM threads WHERE id='thread-a';" `
        -Scalar
    if ($dbProvider -ne "openai") {
        throw "Expected SQLite provider openai after OAuth switch, got $dbProvider"
    }
    $oauthBackupDb = Join-Path $oauthResult.PostSync.BackupDir "state_5.sqlite"
    $oauthBackupProvider = Invoke-TestPythonSqlite `
        -DatabasePath $oauthBackupDb `
        -Sql "SELECT model_provider FROM threads WHERE id='thread-a';" `
        -Scalar
    if ($oauthBackupProvider -ne "MyOpenAI") {
        throw "Expected OAuth backup to preserve MyOpenAI provider, got $oauthBackupProvider"
    }
    $savedApiProfile = Get-Content -LiteralPath (Join-Path $appRoot "profiles\cpamc\auth.json") -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$savedApiProfile.OPENAI_API_KEY)) {
        throw "Expected MyOpenAI API credentials to remain in the CPAMC profile"
    }

    Write-Host "Codex unified switcher checks passed."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
