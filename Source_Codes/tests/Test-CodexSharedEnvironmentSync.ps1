$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "tools\CodexUnifiedSwitcher.ps1"
. $scriptPath -NoUi

foreach ($name in @(
    "Export-CodexSharedEnvironment",
    "Import-CodexSharedEnvironment",
    "Get-CodexSharedConfigContent"
)) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Missing required function: $name"
    }
}

$root = Join-Path $env:TEMP ("codex-shared-env-sync-test-" + [guid]::NewGuid().ToString("N"))
$sourceHome = Join-Path $root "source\.codex"
$targetHome = Join-Path $root "target\.codex"
$syncRoot = Join-Path $root "sync"

try {
    New-Item -ItemType Directory -Path $sourceHome,$targetHome -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sourceHome "skills\custom-skill") -Force | Out-Null

    Set-Content -LiteralPath (Join-Path $sourceHome "config.toml") -Encoding UTF8 -Value @"
model_provider = "openai"

[marketplaces.ponytail]
source_type = "git"
source = "https://github.com/DietrichGebert/ponytail.git"

[plugins."ponytail@ponytail"]
enabled = true

[mcp_servers.codegraph]
command = "codegraph"

[hooks.state."ponytail@ponytail:hooks/test.json:session_start:0:0"]
trusted_hash = "sha256:test"
"@
    Set-Content -LiteralPath (Join-Path $sourceHome "hooks.json") -Encoding UTF8 -Value '{"hooks":[]}'
    Set-Content -LiteralPath (Join-Path $sourceHome "skills\custom-skill\SKILL.md") -Encoding UTF8 -Value "# Custom Skill"

    Set-Content -LiteralPath (Join-Path $targetHome "config.toml") -Encoding UTF8 -Value @"
model_provider = "MyOpenAI"

[model_providers.MyOpenAI]
name = "MyOpenAI"
"@

    Export-CodexSharedEnvironment -CodexHome $sourceHome -SyncRoot $syncRoot | Out-Null
    Import-CodexSharedEnvironment -CodexHome $targetHome -SyncRoot $syncRoot | Out-Null

    $targetConfig = Get-Content -LiteralPath (Join-Path $targetHome "config.toml") -Raw
    foreach ($expected in @(
        'model_provider = "MyOpenAI"',
        '[model_providers.MyOpenAI]',
        '[marketplaces.ponytail]',
        '[plugins."ponytail@ponytail"]',
        '[mcp_servers.codegraph]',
        '[hooks.state."ponytail@ponytail:hooks/test.json:session_start:0:0"]'
    )) {
        if (-not $targetConfig.Contains($expected)) {
            throw "Expected imported shared config: $expected"
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $targetHome "hooks.json"))) {
        throw "Expected hooks.json to be imported"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $targetHome "skills\custom-skill\SKILL.md"))) {
        throw "Expected custom skill to be imported"
    }

    if (Test-Path -LiteralPath (Join-Path $syncRoot "environment\auth.json")) {
        throw "Shared environment sync must not export auth.json"
    }

    Write-Host "Codex shared environment sync checks passed."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
