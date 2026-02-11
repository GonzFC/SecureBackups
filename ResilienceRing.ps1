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
$script:AppVersion = '1.1.1'
$script:AppName = 'Resilience Ring'
$script:RepoOwner = 'GonzFC'
$script:RepoName = 'SecureBackups'
$script:RepoBranch = 'main'

# Paths - use installation directory, not legacy path
$script:InstallPath = $PSScriptRoot
$script:ConfigPath = $PSScriptRoot
$script:DestinationsFile = Join-Path $ConfigPath "destinations.json"
$script:JobsFile = Join-Path $ConfigPath "jobs.json"
$script:LogPath = Join-Path $ConfigPath "Logs"
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
        [switch]$Force
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
        Read-Host "Press Enter to continue"
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

    Write-Host ""
    Write-Host "Would you like to update now? [Y/n]: " -NoNewline -ForegroundColor Yellow
    $response = Read-Host

    if ($response -ne '' -and $response -notmatch '^[Yy]') {
        Write-Host "Update cancelled." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return $false
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
            Read-Host "Press Enter to exit"
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
            Read-Host "Press Enter to exit"
            exit 0
        }
        catch {
            Write-Host "Update failed: $_" -ForegroundColor Red
            Write-Host ""
            Read-Host "Press Enter to continue"
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
    Write-Host "         RESILIENCE RING" -ForegroundColor Cyan
    Write-Host "    Distributed Backup System" -ForegroundColor Cyan
    Write-Host "         v$script:AppVersion" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "         Powered by VLABS" -ForegroundColor DarkGray
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
    # We need to load the functions but not execute the main entry point
    # Read the script, remove the main execution block, then invoke
    $legacyContent = Get-Content $legacyScript -Raw
    
    # Remove the #Requires directive (we handle admin check ourselves)
    $legacyContent = $legacyContent -replace '#Requires -RunAsAdministrator', ''
    
    # Remove everything after "# Main entry point" or "# Initialize and start"
    $legacyContent = $legacyContent -replace '(?s)#region Main Entry Point.*', ''
    $legacyContent = $legacyContent -replace '(?s)# Initialize and start.*', ''
    $legacyContent = $legacyContent -replace '(?s)# Main entry point.*', ''
    
    try {
        # Execute the content to define all functions
        . ([ScriptBlock]::Create($legacyContent))
        Write-Host "[OK] Core functions loaded" -ForegroundColor Green
    }
    catch {
        Write-Host "[WARN] Some legacy functions may not be available: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
else {
    Write-Host "[ERROR] Legacy script not found: $legacyScript" -ForegroundColor Red
    Write-Host "Please ensure VLABS-SecureBackup.ps1 is in the same directory." -ForegroundColor Yellow
}

#endregion

#region Main Menu

function Show-MainMenu {
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "         RESILIENCE RING v$script:AppVersion" -ForegroundColor Cyan
    Write-Host "    Distributed Backup System" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    Write-Host " DESTINATIONS" -ForegroundColor Yellow
    Write-Host "   1. Create Destination" -ForegroundColor White
    Write-Host "   2. Edit Destination" -ForegroundColor White
    Write-Host "   3. Delete Destination" -ForegroundColor White

    Write-Host ""
    Write-Host " BACKUP JOBS" -ForegroundColor Yellow
    Write-Host "   4. Create Backup Job" -ForegroundColor White
    Write-Host "   5. Edit Backup Job" -ForegroundColor White
    Write-Host "   6. Delete Backup Job" -ForegroundColor White
    Write-Host "   7. Run Backup Job Now" -ForegroundColor White

    Write-Host ""
    Write-Host " STATUS" -ForegroundColor Yellow
    Write-Host "   8. Show All Backup Jobs" -ForegroundColor White
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
            "1" { New-BackupDestination }
            "2" { Edit-BackupDestination }
            "3" { Remove-BackupDestination }
            "4" { New-BackupJob }
            "5" { Edit-BackupJob }
            "6" { Remove-BackupJob }
            "7" { Invoke-BackupJobNow }
            "8" { Show-AllBackupJobs }
            "9" { Show-BackupStatus }
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

# Check for updates (unless skipped)
if (-not $SkipUpdateCheck) {
    $updateInfo = Test-UpdateAvailable
    if ($updateInfo.Available) {
        Write-Host ""
        Write-Host "A new version is available! Use 'U' from the menu to update." -ForegroundColor Yellow
    }
}
elseif ($ForceUpdate) {
    Invoke-SelfUpdate -Force
}

Write-Host ""
Write-Host "Press any key to continue..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

# Start main loop
Start-MainLoop

#endregion
