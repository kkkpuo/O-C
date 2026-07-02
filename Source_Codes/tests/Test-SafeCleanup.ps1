$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot "tools\CodexUnifiedSwitcher.ps1"
. $scriptPath -NoUi

foreach ($name in @("Get-SafeCleanupCandidates", "Invoke-SafeCleanup", "Format-CleanupResult")) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Missing required function: $name"
    }
}

$root = Join-Path $env:TEMP ("o-c-cleanup-test-" + [guid]::NewGuid().ToString("N"))
$backupRoot = Join-Path $root "backup"
$fakeRepo = Join-Path $root "repo"

try {
    foreach ($folder in @(
        "codex-switch\backups",
        "history-sync",
        "c-o-safety-backups"
    )) {
        $dir = Join-Path $backupRoot $folder
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        1..5 | ForEach-Object {
            $item = Join-Path $dir "old-$_"
            New-Item -ItemType Directory -Path $item -Force | Out-Null
            (Get-Item -LiteralPath $item).LastWriteTime = (Get-Date).AddDays(-30 - $_)
        }
    }

    New-Item -ItemType Directory -Path (Join-Path $fakeRepo "dist") -Force | Out-Null
    1..4 | ForEach-Object {
        $zip = Join-Path $fakeRepo "dist\O-C-v0.$_-win-x64.zip"
        Set-Content -LiteralPath $zip -Value "zip$_"
        (Get-Item -LiteralPath $zip).LastWriteTime = (Get-Date).AddDays(0 - $_)
    }

    $preview = Invoke-SafeCleanup -BackupRoot $backupRoot -RepoRoot $fakeRepo -RetentionDays 14 -KeepMinimum 3 -Preview
    if ($preview.Count -lt 1) {
        throw "Expected cleanup preview candidates"
    }
    if (-not (Test-Path -LiteralPath $preview.Items[0].Path)) {
        throw "Preview must not delete files"
    }

    $result = Invoke-SafeCleanup -BackupRoot $backupRoot -RepoRoot $fakeRepo -RetentionDays 14 -KeepMinimum 3
    if ($result.Count -ne $preview.Count) {
        throw "Cleanup count should match preview count"
    }
    foreach ($item in $result.Items) {
        if (Test-Path -LiteralPath $item.Path) {
            throw "Expected cleanup item to be removed: $($item.Path)"
        }
    }

    $remainingZips = @(Get-ChildItem -LiteralPath (Join-Path $fakeRepo "dist") -Filter "O-C-v*.zip" -File)
    if ($remainingZips.Count -ne 2) {
        throw "Expected cleanup to keep the newest two release zips"
    }

    Write-Host "Safe cleanup checks passed."
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
