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

$script:ConfigPath = "C:\ProgramData\VLABS_ResilienceRing"
$script:InstallPath = "C:\VLABS_ResilienceRing"

# Load dependencies
$cryptoUtilsPath = Join-Path $script:InstallPath "CryptoUtils.ps1"
if (Test-Path $cryptoUtilsPath) { . $cryptoUtilsPath }

$peerMgmtPath = Join-Path $script:InstallPath "PeerManagement.ps1"
if (Test-Path $peerMgmtPath) { . $peerMgmtPath }

# Run
Publish-Heartbeat
