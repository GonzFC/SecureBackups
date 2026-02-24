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

$rrmScript = "C:\VLABS_ResilienceRingManager\ResilienceRingManager.ps1"

if (-not (Test-Path $rrmScript)) {
    Write-Error "RRM not found at $rrmScript"
    exit 1
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File $rrmScript -CollectorMode -SkipUpdateCheck
