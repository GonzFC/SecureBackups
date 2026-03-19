#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Resilience Ring - Distributed Backup System

.DESCRIPTION
    TUI-based backup management system with distributed resilience.
    Manages backup destinations, jobs, and scheduled tasks for file/directory/SQL backups
    across multiple nodes via Tailscale.

    Features:
    - Self-updating via GitHub
    - Checksum verification (SHA256)
    - VLABS Monitor integration (when configured)
    - Tailscale-based NAT traversal

.NOTES
    Part of VLABS Infrastructure Tools
    Requires: Administrator privileges, Tailscale
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdateCheck,
    [switch]$ForceUpdate
)

# Version and repository information
$script:AppName = 'VLABS Resilience Ring'
$script:RepoOwner = 'GonzFC'
$script:RepoName = 'SecureBackups'
$script:RepoBranch = 'main'

# Read version from version.txt (single source of truth)
$versionFile = Join-Path $PSScriptRoot "version.txt"
if (Test-Path $versionFile) {
    $script:AppVersion = (Get-Content $versionFile -Raw).Trim()
} else {
    $script:AppVersion = '0.0.0'  # Fallback if version.txt missing
}

# Paths - Data in ProgramData (separate from git install directory)
# This prevents git reset --hard from deleting config files during updates
$script:InstallPath = $PSScriptRoot
$script:DataPath = "C:\ProgramData\VLABS_ResilienceRing"
$script:ConfigPath = $script:DataPath  # For compatibility with VLABS-SecureBackup.ps1
$script:DestinationsFile = Join-Path $DataPath "destinations.json"
$script:JobsFile = Join-Path $DataPath "jobs.json"
$script:LogPath = Join-Path $DataPath "Logs"
$script:ExecutionScript = Join-Path $PSScriptRoot "Execute-Backup.ps1"

#region Update Management

function Get-LatestVersion {
    <#
    .SYNOPSIS
        Fetches the latest version from GitHub
    #>
    try {
        $versionUrl = "https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/version.txt"
        $latestVersion = (Invoke-RestMethod -Uri $versionUrl -UseBasicParsing -TimeoutSec 10).Trim()
        return $latestVersion
    }
    catch {
        return $null
    }
}

function Test-UpdateAvailable {
    <#
    .SYNOPSIS
        Checks if an update is available
    #>
    param(
        [switch]$Silent
    )

    if (-not $Silent) {
        Write-Host "Checking for updates..." -ForegroundColor Gray -NoNewline
    }

    $latestVersion = Get-LatestVersion

    if ($null -eq $latestVersion) {
        if (-not $Silent) {
            Write-Host " [OFFLINE]" -ForegroundColor Yellow
        }
        return @{ Available = $false; Reason = "Could not reach GitHub" }
    }

    # Compare versions
    try {
        $current = [Version]$script:AppVersion
        $latest = [Version]$latestVersion

        if ($latest -gt $current) {
            if (-not $Silent) {
                Write-Host " [UPDATE AVAILABLE: v$latestVersion]" -ForegroundColor Cyan
            }
            return @{ Available = $true; CurrentVersion = $script:AppVersion; LatestVersion = $latestVersion }
        }
        else {
            if (-not $Silent) {
                Write-Host " [UP TO DATE]" -ForegroundColor Green
            }
            return @{ Available = $false; CurrentVersion = $script:AppVersion; LatestVersion = $latestVersion }
        }
    }
    catch {
        if (-not $Silent) {
            Write-Host " [ERROR]" -ForegroundColor Red
        }
        return @{ Available = $false; Reason = "Version comparison failed" }
    }
}

function Invoke-SelfUpdate {
    <#
    .SYNOPSIS
        Updates Resilience Ring to the latest version
    #>
    param(
        [switch]$Force,
        [switch]$Auto
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "     RESILIENCE RING - UPDATE" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $updateCheck = Test-UpdateAvailable

    if (-not $updateCheck.Available -and -not $Force) {
        Write-Host "You are running the latest version ($script:AppVersion)" -ForegroundColor Green
        Write-Host ""
        if (-not $Auto) {
            Read-Host "Press Enter to continue"
        }
        return $false
    }

    if ($updateCheck.Available) {
        Write-Host "Current version: $($updateCheck.CurrentVersion)" -ForegroundColor Yellow
        Write-Host "Latest version:  $($updateCheck.LatestVersion)" -ForegroundColor Green
    }
    else {
        Write-Host "Current version: $script:AppVersion" -ForegroundColor Yellow
        Write-Host "Force update requested" -ForegroundColor Cyan
    }

    if (-not $Auto) {
        Write-Host ""
        Write-Host "Would you like to update now? [Y/n]: " -NoNewline -ForegroundColor Yellow
        $response = Read-Host

        if ($response -ne '' -and $response -notmatch '^[Yy]') {
            Write-Host "Update cancelled." -ForegroundColor Yellow
            Read-Host "Press Enter to continue"
            return $false
        }
    }
    else {
        Write-Host ""
        Write-Host "Update available - applying automatically..." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Updating Resilience Ring..." -ForegroundColor Cyan
    Write-Host ""

    # Check if Git is available
    $gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
    $gitRepo = Test-Path (Join-Path $script:InstallPath '.git')

    if ($gitAvailable -and $gitRepo) {
        # Git-based update
        Write-Host "Using Git to update..." -ForegroundColor White

        try {
            Push-Location $script:InstallPath

            Write-Host "  Fetching latest changes..." -ForegroundColor Gray
            $fetchResult = git fetch origin $script:RepoBranch 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Git fetch failed: $fetchResult" }

            Write-Host "  Applying updates..." -ForegroundColor Gray
            $resetResult = git reset --hard "origin/$script:RepoBranch" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Git reset failed: $resetResult" }

            Pop-Location

            # Unblock files
            Get-ChildItem -Path $script:InstallPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

            Write-Host ""
            Write-Host "Update successful!" -ForegroundColor Green

            # Read new version
            $newVersionFile = Join-Path $script:InstallPath 'version.txt'
            if (Test-Path $newVersionFile) {
                $newVersion = (Get-Content $newVersionFile -Raw).Trim()
                Write-Host "New version: $newVersion" -ForegroundColor Cyan
            }

            Write-Host ""
            Write-Host "Please restart Resilience Ring to use the new version." -ForegroundColor Yellow
            Write-Host ""
            if (-not $Auto) {
                Read-Host "Press Enter to exit"
            }
            exit 0
        }
        catch {
            Pop-Location -ErrorAction SilentlyContinue
            Write-Host "Git update failed: $_" -ForegroundColor Red
            Write-Host "Falling back to ZIP download..." -ForegroundColor Yellow
            $gitAvailable = $false
        }
    }

    if (-not $gitAvailable -or -not $gitRepo) {
        # ZIP-based update
        Write-Host "Downloading update package..." -ForegroundColor White

        try {
            $zipUrl = "https://github.com/$script:RepoOwner/$script:RepoName/archive/refs/heads/$script:RepoBranch.zip"
            $zipPath = Join-Path $env:TEMP 'ResilienceRing_Update.zip'
            $extractPath = Join-Path $env:TEMP 'ResilienceRing_Update_Extract'

            # Download
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

            # Extract
            Write-Host "Extracting files..." -ForegroundColor White
            if (Test-Path $extractPath) {
                Remove-Item -Path $extractPath -Recurse -Force
            }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractPath)

            $extractedFolder = Get-ChildItem $extractPath -Directory | Select-Object -First 1

            # Preserve config files
            $configBackup = @{}
            foreach ($file in @('destinations.json', 'jobs.json')) {
                $filePath = Join-Path $script:InstallPath $file
                if (Test-Path $filePath) {
                    $configBackup[$file] = Get-Content $filePath -Raw
                }
            }

            # Copy new files (excluding config)
            Write-Host "Installing update..." -ForegroundColor White
            Get-ChildItem -Path $extractedFolder.FullName -File | Where-Object { $_.Name -notin @('destinations.json', 'jobs.json') } | ForEach-Object {
                Copy-Item -Path $_.FullName -Destination $script:InstallPath -Force
            }

            # Copy subdirectories
            Get-ChildItem -Path $extractedFolder.FullName -Directory | Where-Object { $_.Name -ne 'Logs' } | ForEach-Object {
                $destDir = Join-Path $script:InstallPath $_.Name
                Copy-Item -Path $_.FullName -Destination $destDir -Recurse -Force
            }

            # Restore config files
            foreach ($file in $configBackup.Keys) {
                $filePath = Join-Path $script:InstallPath $file
                $configBackup[$file] | Set-Content $filePath -Force
            }

            # Cleanup
            Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue

            # Unblock files
            Get-ChildItem -Path $script:InstallPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

            Write-Host ""
            Write-Host "Update successful!" -ForegroundColor Green

            # Read new version
            $newVersionFile = Join-Path $script:InstallPath 'version.txt'
            if (Test-Path $newVersionFile) {
                $newVersion = (Get-Content $newVersionFile -Raw).Trim()
                Write-Host "New version: $newVersion" -ForegroundColor Cyan
            }

            Write-Host ""
            Write-Host "Please restart Resilience Ring to use the new version." -ForegroundColor Yellow
            Write-Host ""
            if (-not $Auto) {
                Read-Host "Press Enter to exit"
            }
            exit 0
        }
        catch {
            Write-Host "Update failed: $_" -ForegroundColor Red
            Write-Host ""
            if (-not $Auto) {
                Read-Host "Press Enter to continue"
            }
            return $false
        }
    }
}

#endregion

#region Banner and Initialization

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "      VLABS RESILIENCE RING" -ForegroundColor Cyan
    Write-Host "    Distributed Backup System" -ForegroundColor Cyan
    Write-Host "            v$script:AppVersion" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Initialize-Environment {
    try {
        # Check if running as administrator
        $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-Host "`nERROR: This script must be run as Administrator!" -ForegroundColor Red
            Write-Host "Please right-click and select 'Run as Administrator'" -ForegroundColor Yellow
            Read-Host "`nPress Enter to exit"
            exit 1
        }

        # Create directory structure
        if (-not (Test-Path $LogPath)) {
            New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
            Write-Log "Created logs directory: $LogPath"
        }

        # Initialize JSON files if they don't exist
        if (-not (Test-Path $DestinationsFile)) {
            @() | ConvertTo-Json | Set-Content $DestinationsFile
            Write-Log "Created destinations file: $DestinationsFile"
        }

        if (-not (Test-Path $JobsFile)) {
            @() | ConvertTo-Json | Set-Content $JobsFile
            Write-Log "Created jobs file: $JobsFile"
        }

        # Perform log cleanup/archival
        Invoke-LogArchival

        return $true
    }
    catch {
        Write-Host "`nERROR: Failed to initialize environment: $_" -ForegroundColor Red
        return $false
    }
}

#endregion

#region Logging Functions

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [ValidateSet('INFO','WARNING','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )

    try {
        if (-not (Test-Path $script:LogPath)) {
            New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null
        }
        
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logFile = Join-Path $script:LogPath "ResilienceRing_$(Get-Date -Format 'yyyyMMdd').log"
        $logEntry = "[$timestamp] [$Level] $Message"

        Add-Content -Path $logFile -Value $logEntry -ErrorAction Stop
    }
    catch {
        # Silently continue if logging fails
    }
}

function Invoke-LogArchival {
    try {
        if (-not (Test-Path $script:LogPath)) { return }
        
        $sevenDaysAgo = (Get-Date).AddDays(-7)
        $logFiles = Get-ChildItem -Path $script:LogPath -Filter "*.log" -ErrorAction SilentlyContinue | 
                    Where-Object { $_.LastWriteTime -lt $sevenDaysAgo }

        if ($logFiles.Count -gt 0) {
            $monthYear = Get-Date -Format "yyyy-MM"
            $zipFileName = "ResilienceRing_Logs_$monthYear.zip"
            $zipFilePath = Join-Path $script:LogPath $zipFileName

            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

            foreach ($logFile in $logFiles) {
                try {
                    if (Test-Path $zipFilePath) {
                        $zip = [System.IO.Compression.ZipFile]::Open($zipFilePath, 'Update')
                    }
                    else {
                        $zip = [System.IO.Compression.ZipFile]::Open($zipFilePath, 'Create')
                    }

                    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $logFile.FullName, $logFile.Name) | Out-Null
                    $zip.Dispose()

                    Remove-Item $logFile.FullName -Force
                }
                catch {
                    if ($zip) { $zip.Dispose() }
                }
            }
        }

        # Keep only last 3 monthly archives
        $zipFiles = Get-ChildItem -Path $script:LogPath -Filter "ResilienceRing_Logs_*.zip" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -Skip 3

        foreach ($zipFile in $zipFiles) {
            Remove-Item $zipFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Log archival is non-critical
    }
}

#endregion

#region Core Functions - Load from Legacy Script

# Dot-source the legacy script to get all the backup functions
$legacyScript = Join-Path $PSScriptRoot "VLABS-SecureBackup.ps1"
if (Test-Path $legacyScript) {
    try {
        # Set environment variable to prevent legacy script from running its main loop
        $env:RESILIENCE_RING_IMPORT = "1"
        
        # Dot-source to load all functions into current scope
        . $legacyScript
        
        # Clear the environment variable
        Remove-Item Env:RESILIENCE_RING_IMPORT -ErrorAction SilentlyContinue
        
        Write-Host "[OK] Core functions loaded" -ForegroundColor Green
    }
    catch {
        Remove-Item Env:RESILIENCE_RING_IMPORT -ErrorAction SilentlyContinue
        Write-Host "[ERROR] Failed to load core functions: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit 1
    }
}
else {
    Write-Host "[ERROR] Core script not found: $legacyScript" -ForegroundColor Red
    Write-Host "Please ensure VLABS-SecureBackup.ps1 is in the same directory." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# Load Peer Management functions
$peerScript = Join-Path $PSScriptRoot "PeerManagement.ps1"
if (Test-Path $peerScript) {
    try {
        . $peerScript
        Write-Host "[OK] Peer management loaded" -ForegroundColor Green
    }
    catch {
        Write-Host "[WARN] Peer management not loaded: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Load Backup Job functions (unified workflow)
$backupJobScript = Join-Path $PSScriptRoot "BackupJob.ps1"
if (Test-Path $backupJobScript) {
    try {
        . $backupJobScript
        Write-Host "[OK] Backup job module loaded" -ForegroundColor Green
    }
    catch {
        Write-Host "[WARN] Backup job module not loaded: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

#endregion

#region Main Menu

function Show-MainMenu {
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "      VLABS RESILIENCE RING" -ForegroundColor Cyan
    Write-Host "    Distributed Backup System" -ForegroundColor Cyan
    Write-Host "            v$script:AppVersion" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    Write-Host " BACKUP JOBS" -ForegroundColor Yellow
    Write-Host "   1. Create Backup Job" -ForegroundColor White
    Write-Host "   2. Edit Backup Job" -ForegroundColor White
    Write-Host "   3. Delete Backup Job" -ForegroundColor White
    Write-Host "   4. Run Backup Job Now" -ForegroundColor White
    Write-Host "   5. Show All Backup Jobs" -ForegroundColor White

    Write-Host ""
    Write-Host " STORAGE PEERS" -ForegroundColor Yellow
    Write-Host "   P. Add Storage Peer (configure this machine)" -ForegroundColor White
    Write-Host "   S. Show Available Storage Peers" -ForegroundColor White
    Write-Host "   D. Discover & Update Peer List" -ForegroundColor White
    Write-Host "   T. Configure Tailscale Mode" -ForegroundColor White
    Write-Host "   R. Rebalance Storage" -ForegroundColor White

    Write-Host ""
    Write-Host " STATUS" -ForegroundColor Yellow
    Write-Host "   9. View Status & History" -ForegroundColor White

    Write-Host ""
    Write-Host " SYSTEM" -ForegroundColor Yellow
    Write-Host "   U. Check for Updates" -ForegroundColor White
    Write-Host "   0. Exit" -ForegroundColor White

    Write-Host "`n========================================" -ForegroundColor Cyan
}

function Start-MainLoop {
    while ($true) {
        Show-MainMenu
        $choice = Read-Host "`nEnter your choice"

        switch ($choice.ToUpper()) {
            # Backup Jobs (unified workflow)
            "1" { 
                if (Get-Command 'New-UnifiedBackupJob' -ErrorAction SilentlyContinue) {
                    New-UnifiedBackupJob
                } else {
                    Write-Host "Unified backup not available, using legacy..." -ForegroundColor Yellow
                    New-BackupJob
                }
            }
            "2" { Edit-BackupJob }
            "3" { Remove-BackupJob }
            "4" { Invoke-BackupJobNow }
            "5" { Show-AllBackupJobs }
            
            # Storage Peers
            "P" { Add-StoragePeer }
            "S" { Show-StoragePeers }
            "D" { Update-PeerList; Read-Host "`nPress Enter to continue" }
            "T" { Set-TailscaleMode }
            "R" { Invoke-StorageRebalance }
            
            # Status
            "9" { Show-BackupStatus }
            
            # System
            "U" { Invoke-SelfUpdate }
            "0" {
                Write-Host "`nExiting Resilience Ring..." -ForegroundColor Cyan
                Write-Log "Application closed" -Level INFO
                exit 0
            }
            default {
                Write-Host "`nInvalid choice! Please try again." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

#endregion

#region Main Entry Point

# Show banner
Show-Banner

# Initialize environment
Write-Host "Initializing..." -ForegroundColor Gray
if (-not (Initialize-Environment)) {
    Read-Host "`nPress Enter to exit"
    exit 1
}
Write-Host "[OK] Environment ready" -ForegroundColor Green

# Check for updates
if ($ForceUpdate) {
    Invoke-SelfUpdate -Force -Auto
}
elseif (-not $SkipUpdateCheck) {
    $updateInfo = Test-UpdateAvailable
    if ($updateInfo.Available) {
        Write-Host ""
        Write-Host "A new version is available. Applying update now..." -ForegroundColor Yellow
        Invoke-SelfUpdate -Auto
    }
}

# Validate jobs and scheduled tasks
if (Get-Command 'Invoke-JobsValidation' -ErrorAction SilentlyContinue) {
    Write-Host "Validating jobs and tasks..." -ForegroundColor Gray -NoNewline
    $validation = Invoke-JobsValidation
    
    # Build summary of silent repairs (not shown as issues)
    $summary = @()
    if ($validation.JobsMigrated -gt 0) { $summary += "$($validation.JobsMigrated) migrated" }
    if ($validation.JobsRepaired -gt 0) { $summary += "$($validation.JobsRepaired) auto-fixed" }
    if ($validation.TasksCreated -gt 0) { $summary += "$($validation.TasksCreated) tasks created" }
    if ($validation.TasksFixed -gt 0) { $summary += "$($validation.TasksFixed) tasks synced" }
    
    if ($validation.Issues.Count -eq 0) {
        # All good - show OK with summary
        if ($summary.Count -gt 0) {
            Write-Host " [OK: $($summary -join ', ')]" -ForegroundColor Green
        }
        else {
            Write-Host " [OK: $($validation.JobsChecked) jobs]" -ForegroundColor Green
        }
    }
    else {
        # Has issues that need attention, but still show what was auto-fixed
        if ($summary.Count -gt 0) {
            Write-Host " [$($summary -join ', ')]" -ForegroundColor Green
        }
        Write-Host "" # New line before issues
        foreach ($issue in $validation.Issues) {
            Write-Host "  ! $issue" -ForegroundColor Yellow
        }
    }
}

# Publish node status for RRM
if (Get-Command 'Publish-NodeStatus' -ErrorAction SilentlyContinue) {
    Write-Host "Publishing node status..." -ForegroundColor Gray -NoNewline
    if (Publish-NodeStatus) {
        Write-Host " [OK]" -ForegroundColor Green
    }
    else {
        Write-Host " [SKIP - not a storage peer]" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Press any key to continue..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

# Start main loop
Start-MainLoop

#endregion
