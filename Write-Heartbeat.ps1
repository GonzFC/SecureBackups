#Requires -RunAsAdministrator

<#
.SYNOPSIS
    VLABS Resilience Ring - Heartbeat Publisher

.DESCRIPTION
    Publishes this node's liveness + backup status to its RR_Backups share.
    Called hourly by the VLABS_RR_Heartbeat scheduled task.

.NOTES
    Output: <StoragePath>\_nodeinfo\heartbeat.json
    Consumed by: Resilience Ring Manager (RRM) collector
#>

param()

#region Self-Update Bootstrap — DO NOT MODIFY THIS BLOCK
# Runs before everything else. Minimal, bulletproof, fail-open.
# If a bad update breaks the code below, THIS block fetches the fix and restarts clean.
# Uses ONLY built-in PowerShell — no custom functions, no dot-sourcing.
try {
    $_b_path   = 'C:\VLABS_ResilienceRing'
    $_b_branch = 'main'
    $_b_owner  = 'GonzFC'
    $_b_repo   = 'SecureBackups'
    $_b_curr   = (Get-Content "$_b_path\version.txt" -Raw -ErrorAction SilentlyContinue).Trim()
    $_b_latest = (Invoke-RestMethod -Uri "https://raw.githubusercontent.com/$_b_owner/$_b_repo/$_b_branch/version.txt" -UseBasicParsing -TimeoutSec 10).Trim()
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

$script:ConfigPath = "C:\ProgramData\VLABS_ResilienceRing"
$script:InstallPath = "C:\VLABS_ResilienceRing"

# Load dependencies
$cryptoUtilsPath = Join-Path $script:InstallPath "CryptoUtils.ps1"
if (Test-Path $cryptoUtilsPath) { . $cryptoUtilsPath }

$peerMgmtPath = Join-Path $script:InstallPath "PeerManagement.ps1"
if (Test-Path $peerMgmtPath) { . $peerMgmtPath }

# Run
Publish-Heartbeat
