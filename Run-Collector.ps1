#Requires -RunAsAdministrator

<#
.SYNOPSIS
    VLABS Resilience Ring Manager - Background Collector

.DESCRIPTION
    Polls all peer heartbeat files across all configured rings.
    Appends results to monthly JSONL history files.
    Runs hourly via VLABS_RRM_Collector scheduled task.

.NOTES
    History path:  C:\ProgramData\VLABS_RRM\history\YYYY-MM.jsonl
    Reads from:    \\peer\RR_Backups\_nodeinfo\heartbeat.json (per peer)
#>

param()

#region Self-Update Bootstrap — DO NOT MODIFY THIS BLOCK
# Runs before everything else. Minimal, bulletproof, fail-open.
# If a bad update breaks the code below, THIS block fetches the fix and restarts clean.
# Uses ONLY built-in PowerShell — no custom functions, no dot-sourcing.
try {
    $_b_path   = 'C:\VLABS_ResilienceRingManager'
    $_b_branch = 'main'
    $_b_owner  = 'GonzFC'
    $_b_repo   = 'SecureBackups'
    $_b_curr   = (Get-Content "$_b_path\rrm-version.txt" -Raw -ErrorAction SilentlyContinue).Trim()
    $_b_latest = (Invoke-RestMethod -Uri "https://raw.githubusercontent.com/$_b_owner/$_b_repo/$_b_branch/rrm-version.txt" -UseBasicParsing -TimeoutSec 10).Trim()
    if ($_b_curr -ne $_b_latest) {
        Push-Location $_b_path
        git fetch origin $_b_branch 2>&1 | Out-Null
        git reset --hard "origin/$_b_branch" 2>&1 | Out-Null
        Pop-Location
        & $MyInvocation.MyCommand.Path @PSBoundParameters   # Restart with updated code
        exit 0
    }
} catch { }  # Fail open — if update fails for any reason, continue with existing code
#endregion

$rrmScript = "C:\VLABS_ResilienceRingManager\ResilienceRingManager.ps1"

if (-not (Test-Path $rrmScript)) {
    Write-Error "RRM not found at $rrmScript"
    exit 1
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File $rrmScript -CollectorMode -SkipUpdateCheck
