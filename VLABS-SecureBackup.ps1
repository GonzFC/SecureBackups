#Requires -RunAsAdministrator

<#
.SYNOPSIS
    VLABS Secure Backup Tool - TUI-based backup management system
.DESCRIPTION
    Manages backup destinations, backup jobs, and scheduled tasks for file/directory/SQL backups
.NOTES
    Author: VLABS
    Version: 1.0
    Requires: Administrator privileges
#>

# Configuration
$script:ConfigPath = "C:\VLABS_SecureBackups"
$script:DestinationsFile = Join-Path $ConfigPath "destinations.json"
$script:JobsFile = Join-Path $ConfigPath "jobs.json"
$script:LogPath = Join-Path $ConfigPath "Logs"
$script:ExecutionScript = Join-Path $PSScriptRoot "Execute-Backup.ps1"

#region Initialization

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
        if (-not (Test-Path $ConfigPath)) {
            New-Item -Path $ConfigPath -ItemType Directory -Force | Out-Null
            Write-Log "Created configuration directory: $ConfigPath"
        }

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
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logFile = Join-Path $LogPath "VLABS_Backup_$(Get-Date -Format 'yyyyMMdd').log"
        $logEntry = "[$timestamp] [$Level] $Message"

        Add-Content -Path $logFile -Value $logEntry -ErrorAction Stop
    }
    catch {
        Write-Host "Warning: Could not write to log file: $_" -ForegroundColor Yellow
    }
}

function Invoke-LogArchival {
    try {
        $sevenDaysAgo = (Get-Date).AddDays(-7)
        $logFiles = Get-ChildItem -Path $LogPath -Filter "*.log" | Where-Object { $_.LastWriteTime -lt $sevenDaysAgo }

        if ($logFiles.Count -gt 0) {
            $monthYear = Get-Date -Format "yyyy-MM"
            $zipFileName = "VLABS_Backup_Logs_$monthYear.zip"
            $zipFilePath = Join-Path $LogPath $zipFileName

            # Load compression assembly
            Add-Type -AssemblyName System.IO.Compression.FileSystem

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
                    Write-Log "Archived and deleted log file: $($logFile.Name)" -Level INFO
                }
                catch {
                    if ($zip) { $zip.Dispose() }
                    Write-Log "Failed to archive log file $($logFile.Name): $_" -Level ERROR
                }
            }
        }

        # Keep only the last 3 monthly zip files
        $zipFiles = Get-ChildItem -Path $LogPath -Filter "VLABS_Backup_Logs_*.zip" |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -Skip 3

        foreach ($zipFile in $zipFiles) {
            Remove-Item $zipFile.FullName -Force
            Write-Log "Deleted old log archive: $($zipFile.Name)" -Level INFO
        }
    }
    catch {
        Write-Log "Error during log archival: $_" -Level ERROR
    }
}

#endregion

#region Configuration Functions

function Get-Destinations {
    try {
        $content = Get-Content $DestinationsFile -Raw -ErrorAction Stop
        return ($content | ConvertFrom-Json)
    }
    catch {
        Write-Log "Error reading destinations: $_" -Level ERROR
        return @()
    }
}

function Save-Destinations {
    param([Parameter(Mandatory=$true)] $Destinations)

    try {
        $Destinations | ConvertTo-Json -Depth 10 | Set-Content $DestinationsFile -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log "Error saving destinations: $_" -Level ERROR
        return $false
    }
}

function Get-Jobs {
    try {
        $content = Get-Content $JobsFile -Raw -ErrorAction Stop
        return ($content | ConvertFrom-Json)
    }
    catch {
        Write-Log "Error reading jobs: $_" -Level ERROR
        return @()
    }
}

function Save-Jobs {
    param([Parameter(Mandatory=$true)] $Jobs)

    try {
        $Jobs | ConvertTo-Json -Depth 10 | Set-Content $JobsFile -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log "Error saving jobs: $_" -Level ERROR
        return $false
    }
}

#endregion

#region Destination Management

function Test-SmbDestination {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    try {
        # Validate UNC path format
        if ($Path -notmatch '^\\\\[^\\]+\\[^\\]+') {
            Write-Host "Invalid UNC path format. Expected: \\server\folder" -ForegroundColor Red
            return $false
        }

        # Test if path is reachable
        if (-not (Test-Path $Path)) {
            Write-Host "Path is not reachable or does not exist." -ForegroundColor Red
            return $false
        }

        # Test write permissions
        $testFile = Join-Path $Path "vlabs_test_$(Get-Date -Format 'yyyyMMddHHmmss').tmp"
        try {
            "test" | Out-File -FilePath $testFile -ErrorAction Stop
            Remove-Item $testFile -Force -ErrorAction Stop
            return $true
        }
        catch {
            Write-Host "Path is not writable: $_" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "Error testing destination: $_" -ForegroundColor Red
        return $false
    }
}

function New-BackupDestination {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     CREATE BACKUP DESTINATION" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    # Get short name
    $shortName = Read-Host "Enter a short name for this destination"
    if ([string]::IsNullOrWhiteSpace($shortName)) {
        Write-Host "`nError: Short name cannot be empty!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Check if name already exists
    $destinations = Get-Destinations
    if ($destinations | Where-Object { $_.ShortName -eq $shortName }) {
        Write-Host "`nError: A destination with this name already exists!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Get SMB path
    $smbPath = Read-Host "Enter SMB path (e.g., \\server\folder)"
    if ([string]::IsNullOrWhiteSpace($smbPath)) {
        Write-Host "`nError: SMB path cannot be empty!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Verify destination
    Write-Host "`nVerifying destination..." -ForegroundColor Yellow
    if (-not (Test-SmbDestination -Path $smbPath)) {
        Write-Host "`nDestination verification failed!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Add destination
    $newDestination = @{
        ShortName = $shortName
        Path = $smbPath
        CreatedDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    $destinations += $newDestination

    if (Save-Destinations -Destinations $destinations) {
        Write-Host "`nDestination '$shortName' created successfully!" -ForegroundColor Green
        Write-Log "Created destination: $shortName -> $smbPath" -Level SUCCESS
    }
    else {
        Write-Host "`nFailed to save destination!" -ForegroundColor Red
    }

    Read-Host "`nPress Enter to continue"
}

function Show-Destinations {
    $destinations = Get-Destinations

    if ($destinations.Count -eq 0) {
        Write-Host "`nNo destinations configured." -ForegroundColor Yellow
        return $null
    }

    Write-Host "`nConfigured Destinations:" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan

    for ($i = 0; $i -lt $destinations.Count; $i++) {
        $dest = $destinations[$i]
        Write-Host "`n[$($i + 1)] " -NoNewline -ForegroundColor Yellow
        Write-Host "$($dest.ShortName)" -ForegroundColor White
        Write-Host "    Path: $($dest.Path)" -ForegroundColor Gray
        Write-Host "    Created: $($dest.CreatedDate)" -ForegroundColor Gray
    }
    Write-Host ""

    return $destinations
}

function Edit-BackupDestination {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     EDIT BACKUP DESTINATION" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    $destinations = Show-Destinations
    if ($null -eq $destinations -or $destinations.Count -eq 0) {
        Read-Host "`nPress Enter to continue"
        return
    }

    $selection = Read-Host "`nSelect destination number to edit (or 0 to cancel)"
    $index = [int]$selection - 1

    if ($selection -eq "0" -or $index -lt 0 -or $index -ge $destinations.Count) {
        return
    }

    $dest = $destinations[$index]
    Write-Host "`nEditing: $($dest.ShortName)" -ForegroundColor Yellow
    Write-Host "Current path: $($dest.Path)" -ForegroundColor Gray

    $newPath = Read-Host "`nEnter new SMB path (or press Enter to keep current)"
    if (-not [string]::IsNullOrWhiteSpace($newPath)) {
        Write-Host "`nVerifying new destination..." -ForegroundColor Yellow
        if (Test-SmbDestination -Path $newPath) {
            $destinations[$index].Path = $newPath
            if (Save-Destinations -Destinations $destinations) {
                Write-Host "`nDestination updated successfully!" -ForegroundColor Green
                Write-Log "Updated destination: $($dest.ShortName) -> $newPath" -Level SUCCESS
            }
        }
        else {
            Write-Host "`nDestination verification failed! Changes not saved." -ForegroundColor Red
        }
    }

    Read-Host "`nPress Enter to continue"
}

function Remove-BackupDestination {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     DELETE BACKUP DESTINATION" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    $destinations = Show-Destinations
    if ($null -eq $destinations -or $destinations.Count -eq 0) {
        Read-Host "`nPress Enter to continue"
        return
    }

    # Check if any jobs use these destinations
    $jobs = Get-Jobs

    $selection = Read-Host "`nSelect destination number to delete (or 0 to cancel)"
    $index = [int]$selection - 1

    if ($selection -eq "0" -or $index -lt 0 -or $index -ge $destinations.Count) {
        return
    }

    $dest = $destinations[$index]

    # Check if destination is in use
    $jobsUsingDest = $jobs | Where-Object { $_.Destination -eq $dest.ShortName }
    if ($jobsUsingDest) {
        Write-Host "`nWARNING: This destination is used by the following backup jobs:" -ForegroundColor Red
        foreach ($job in $jobsUsingDest) {
            Write-Host "  - $($job.JobName)" -ForegroundColor Yellow
        }
        Write-Host "`nPlease delete or modify these jobs first!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    $confirm = Read-Host "`nAre you sure you want to delete '$($dest.ShortName)'? (yes/no)"
    if ($confirm -eq "yes") {
        $destinations = $destinations | Where-Object { $_.ShortName -ne $dest.ShortName }
        if (Save-Destinations -Destinations $destinations) {
            Write-Host "`nDestination deleted successfully!" -ForegroundColor Green
            Write-Log "Deleted destination: $($dest.ShortName)" -Level SUCCESS
        }
    }

    Read-Host "`nPress Enter to continue"
}

#endregion

#region Backup Job Management

function New-BackupJob {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     CREATE BACKUP JOB - WIZARD" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    # Check if destinations exist
    $destinations = Get-Destinations
    if ($destinations.Count -eq 0) {
        Write-Host "No destinations configured. Please create a destination first!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Job name
    $jobName = Read-Host "Enter a name for this backup job"
    if ([string]::IsNullOrWhiteSpace($jobName)) {
        Write-Host "`nError: Job name cannot be empty!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Check if job name already exists
    $jobs = Get-Jobs
    if ($jobs | Where-Object { $_.JobName -eq $jobName }) {
        Write-Host "`nError: A job with this name already exists!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Step 1: Select backup type
    Write-Host "`n--- Step 1: Select Backup Type ---" -ForegroundColor Yellow
    Write-Host "F  = File (single file)"
    Write-Host "D  = Directory (entire folder)"
    Write-Host "SQL = SQL Server Database (backup folder)"
    $backupType = Read-Host "`nEnter type (F/D/SQL)"

    $backupType = $backupType.ToUpper()
    if ($backupType -notin @("F", "D", "SQL")) {
        Write-Host "`nInvalid backup type!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Step 1.1: Enter backup object
    Write-Host "`n--- Step 1.1: Enter Backup Object ---" -ForegroundColor Yellow

    $backupObject = ""
    switch ($backupType) {
        "F" {
            $backupObject = Read-Host "Enter full path and filename (e.g., C:\Data\important.db)"
            if (-not (Test-Path $backupObject -PathType Leaf)) {
                Write-Host "`nWarning: File does not exist!" -ForegroundColor Yellow
                $confirm = Read-Host "Continue anyway? (yes/no)"
                if ($confirm -ne "yes") { return }
            }
        }
        "D" {
            $backupObject = Read-Host "Enter full directory path (e.g., C:\Data\Documents)"
            if (-not (Test-Path $backupObject -PathType Container)) {
                Write-Host "`nWarning: Directory does not exist!" -ForegroundColor Yellow
                $confirm = Read-Host "Continue anyway? (yes/no)"
                if ($confirm -ne "yes") { return }
            }
        }
        "SQL" {
            $backupObject = Read-Host "Enter SQL backup folder path (e.g., C:\SQLBackups)"
            if (-not (Test-Path $backupObject -PathType Container)) {
                Write-Host "`nWarning: Directory does not exist!" -ForegroundColor Yellow
                $confirm = Read-Host "Continue anyway? (yes/no)"
                if ($confirm -ne "yes") { return }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($backupObject)) {
        Write-Host "`nError: Backup object cannot be empty!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Step 2: Select destination
    Write-Host "`n--- Step 2: Select Destination ---" -ForegroundColor Yellow
    Show-Destinations | Out-Null

    $destSelection = Read-Host "`nSelect destination number (or 0 to cancel)"
    $destIndex = [int]$destSelection - 1

    if ($destSelection -eq "0" -or $destIndex -lt 0 -or $destIndex -ge $destinations.Count) {
        Write-Host "`nOperation cancelled." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    $selectedDestination = $destinations[$destIndex]

    # Step 3: Set retention
    Write-Host "`n--- Step 3: Set Retention Policy ---" -ForegroundColor Yellow
    $retention = Read-Host "How many backup copies to keep at destination?"

    if (-not ($retention -as [int]) -or [int]$retention -lt 1) {
        Write-Host "`nError: Retention must be a positive number!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Step 4: Set frequency
    Write-Host "`n--- Step 4: Set Frequency ---" -ForegroundColor Yellow
    $frequency = Read-Host "Run backup every N hours (enter N)"

    if (-not ($frequency -as [int]) -or [int]$frequency -lt 1 -or [int]$frequency -gt 24) {
        Write-Host "`nError: Frequency must be between 1 and 24 hours!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    $startHour = Read-Host "Starting at hour (0-23, 24-hour format)"

    if (-not ($startHour -as [int]) -or [int]$startHour -lt 0 -or [int]$startHour -gt 23) {
        Write-Host "`nError: Start hour must be between 0 and 23!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Create job object
    $newJob = @{
        JobName = $jobName
        BackupType = $backupType
        BackupObject = $backupObject
        Destination = $selectedDestination.ShortName
        DestinationPath = $selectedDestination.Path
        Retention = [int]$retention
        Frequency = [int]$frequency
        StartHour = [int]$startHour
        CreatedDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        TaskName = "VLABS_Backup_$jobName"
        LastRun = $null
        LastStatus = $null
        Enabled = $true
    }

    # Save job
    $jobs += $newJob
    if (-not (Save-Jobs -Jobs $jobs)) {
        Write-Host "`nFailed to save job!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Create scheduled task
    Write-Host "`nCreating Windows Scheduled Task..." -ForegroundColor Yellow
    if (New-ScheduledBackupTask -Job $newJob) {
        Write-Host "`nBackup job '$jobName' created successfully!" -ForegroundColor Green
        Write-Log "Created backup job: $jobName (Type: $backupType, Destination: $($selectedDestination.ShortName))" -Level SUCCESS
    }
    else {
        Write-Host "`nJob created but scheduled task creation failed!" -ForegroundColor Red
    }

    Read-Host "`nPress Enter to continue"
}

function New-ScheduledBackupTask {
    param(
        [Parameter(Mandatory=$true)]
        $Job
    )

    try {
        # Check if execution script exists
        if (-not (Test-Path $ExecutionScript)) {
            Write-Host "Execution script not found: $ExecutionScript" -ForegroundColor Red
            return $false
        }

        # Delete existing task if it exists
        $existingTask = Get-ScheduledTask -TaskName $Job.TaskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Unregister-ScheduledTask -TaskName $Job.TaskName -Confirm:$false -ErrorAction Stop
            Write-Log "Removed existing scheduled task: $($Job.TaskName)" -Level INFO
        }

        # Create task action
        $action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ExecutionScript`" -JobName `"$($Job.JobName)`""

        # Create triggers based on frequency
        $triggers = @()
        $startTime = Get-Date -Hour $Job.StartHour -Minute 0 -Second 0

        # Create daily trigger
        $trigger = New-ScheduledTaskTrigger -Daily -At $startTime

        # If frequency is less than 24 hours, add repetition
        if ($Job.Frequency -lt 24) {
            $trigger.Repetition = New-ScheduledTaskTrigger -Once -At $startTime -RepetitionInterval (New-TimeSpan -Hours $Job.Frequency) -RepetitionDuration ([TimeSpan]::MaxValue) | Select-Object -ExpandProperty Repetition
        }

        $triggers += $trigger

        # Create task principal (run with highest privileges)
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

        # Create task settings
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

        # Register the task
        Register-ScheduledTask -TaskName $Job.TaskName `
            -Action $action `
            -Trigger $triggers `
            -Principal $principal `
            -Settings $settings `
            -Description "VLABS Secure Backup: $($Job.JobName)" `
            -ErrorAction Stop | Out-Null

        Write-Log "Created scheduled task: $($Job.TaskName)" -Level SUCCESS
        return $true
    }
    catch {
        Write-Host "Error creating scheduled task: $_" -ForegroundColor Red
        Write-Log "Failed to create scheduled task for $($Job.JobName): $_" -Level ERROR
        return $false
    }
}

function Show-AllBackupJobs {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     ALL BACKUP JOBS" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    $jobs = Get-Jobs

    if ($jobs.Count -eq 0) {
        Write-Host "No backup jobs configured." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $job = $jobs[$i]
        $typeMap = @{ "F" = "File"; "D" = "Directory"; "SQL" = "SQL Database" }

        Write-Host "[$($i + 1)] " -NoNewline -ForegroundColor Yellow
        Write-Host "$($job.JobName)" -NoNewline -ForegroundColor White

        if ($job.Enabled -eq $false) {
            Write-Host " [DISABLED]" -ForegroundColor Red
        }
        else {
            Write-Host ""
        }

        Write-Host "    Type: $($typeMap[$job.BackupType])" -ForegroundColor Gray
        Write-Host "    Source: $($job.BackupObject)" -ForegroundColor Gray
        Write-Host "    Destination: $($job.Destination) ($($job.DestinationPath))" -ForegroundColor Gray
        Write-Host "    Retention: $($job.Retention) copies" -ForegroundColor Gray
        Write-Host "    Frequency: Every $($job.Frequency) hour(s), starting at $($job.StartHour):00" -ForegroundColor Gray

        if ($job.LastRun) {
            $statusColor = if ($job.LastStatus -eq "Success") { "Green" } else { "Red" }
            Write-Host "    Last Run: $($job.LastRun) - " -NoNewline -ForegroundColor Gray
            Write-Host "$($job.LastStatus)" -ForegroundColor $statusColor
        }
        else {
            Write-Host "    Last Run: Never" -ForegroundColor Gray
        }

        Write-Host ""
    }

    Read-Host "Press Enter to continue"
}

function Invoke-BackupJobNow {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     RUN BACKUP JOB NOW" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    $jobs = Get-Jobs

    if ($jobs.Count -eq 0) {
        Write-Host "No backup jobs configured." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    # Display jobs
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $job = $jobs[$i]
        Write-Host "[$($i + 1)] " -NoNewline -ForegroundColor Yellow
        Write-Host "$($job.JobName)" -NoNewline -ForegroundColor White

        if ($job.Enabled -eq $false) {
            Write-Host " [DISABLED]" -ForegroundColor Red
        }
        else {
            Write-Host ""
        }
    }

    $selection = Read-Host "`nSelect job number to run (or 0 to cancel)"
    $index = [int]$selection - 1

    if ($selection -eq "0" -or $index -lt 0 -or $index -ge $jobs.Count) {
        return
    }

    $job = $jobs[$index]

    Write-Host "`nStarting backup job: $($job.JobName)..." -ForegroundColor Yellow
    Write-Log "Manual execution requested for job: $($job.JobName)" -Level INFO

    try {
        # Execute asynchronously
        $scriptBlock = {
            param($ExecutionScript, $JobName)
            & PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File $ExecutionScript -JobName $JobName
        }

        Start-Job -ScriptBlock $scriptBlock -ArgumentList $ExecutionScript, $job.JobName | Out-Null

        Write-Host "`nBackup job started in background." -ForegroundColor Green
        Write-Host "Check the status view or logs for progress." -ForegroundColor Cyan
    }
    catch {
        Write-Host "`nError starting backup job: $_" -ForegroundColor Red
        Write-Log "Error starting manual backup for $($job.JobName): $_" -Level ERROR
    }

    Read-Host "`nPress Enter to continue"
}

function Edit-BackupJob {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     EDIT BACKUP JOB" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    $jobs = Get-Jobs

    if ($jobs.Count -eq 0) {
        Write-Host "No backup jobs configured." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    # Display jobs
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        Write-Host "[$($i + 1)] $($jobs[$i].JobName)" -ForegroundColor Yellow
    }

    $selection = Read-Host "`nSelect job number to edit (or 0 to cancel)"
    $index = [int]$selection - 1

    if ($selection -eq "0" -or $index -lt 0 -or $index -ge $jobs.Count) {
        return
    }

    $job = $jobs[$index]

    Write-Host "`nEditing: $($job.JobName)" -ForegroundColor Yellow
    Write-Host "`nWhat would you like to edit?" -ForegroundColor Cyan
    Write-Host "1. Retention ($($job.Retention) copies)"
    Write-Host "2. Frequency (Every $($job.Frequency) hours, starting at $($job.StartHour):00)"
    Write-Host "3. Enable/Disable Job (Currently: $(if($job.Enabled){'Enabled'}else{'Disabled'}))"
    Write-Host "4. Cancel"

    $choice = Read-Host "`nEnter choice"

    switch ($choice) {
        "1" {
            $newRetention = Read-Host "Enter new retention (number of copies to keep)"
            if (($newRetention -as [int]) -and [int]$newRetention -gt 0) {
                $jobs[$index].Retention = [int]$newRetention
                Write-Host "`nRetention updated!" -ForegroundColor Green
            }
            else {
                Write-Host "`nInvalid retention value!" -ForegroundColor Red
            }
        }
        "2" {
            $newFrequency = Read-Host "Enter new frequency (hours, 1-24)"
            $newStartHour = Read-Host "Enter new start hour (0-23)"

            if (($newFrequency -as [int]) -and [int]$newFrequency -ge 1 -and [int]$newFrequency -le 24 -and
                ($newStartHour -as [int]) -and [int]$newStartHour -ge 0 -and [int]$newStartHour -le 23) {

                $jobs[$index].Frequency = [int]$newFrequency
                $jobs[$index].StartHour = [int]$newStartHour

                # Recreate scheduled task
                if (New-ScheduledBackupTask -Job $jobs[$index]) {
                    Write-Host "`nFrequency updated and scheduled task recreated!" -ForegroundColor Green
                }
            }
            else {
                Write-Host "`nInvalid frequency or start hour!" -ForegroundColor Red
            }
        }
        "3" {
            $jobs[$index].Enabled = -not $jobs[$index].Enabled
            $status = if ($jobs[$index].Enabled) { "enabled" } else { "disabled" }

            # Enable or disable the scheduled task
            try {
                if ($jobs[$index].Enabled) {
                    Enable-ScheduledTask -TaskName $job.TaskName -ErrorAction Stop | Out-Null
                }
                else {
                    Disable-ScheduledTask -TaskName $job.TaskName -ErrorAction Stop | Out-Null
                }
                Write-Host "`nJob $status!" -ForegroundColor Green
                Write-Log "Job $($job.JobName) $status" -Level INFO
            }
            catch {
                Write-Host "`nError updating scheduled task: $_" -ForegroundColor Red
            }
        }
        "4" {
            Read-Host "`nPress Enter to continue"
            return
        }
        default {
            Write-Host "`nInvalid choice!" -ForegroundColor Red
        }
    }

    if ($choice -in @("1", "2", "3")) {
        if (Save-Jobs -Jobs $jobs) {
            Write-Log "Updated job: $($job.JobName)" -Level SUCCESS
        }
    }

    Read-Host "`nPress Enter to continue"
}

function Remove-BackupJob {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     DELETE BACKUP JOB" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    $jobs = Get-Jobs

    if ($jobs.Count -eq 0) {
        Write-Host "No backup jobs configured." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    # Display jobs
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        Write-Host "[$($i + 1)] $($jobs[$i].JobName)" -ForegroundColor Yellow
    }

    $selection = Read-Host "`nSelect job number to delete (or 0 to cancel)"
    $index = [int]$selection - 1

    if ($selection -eq "0" -or $index -lt 0 -or $index -ge $jobs.Count) {
        return
    }

    $job = $jobs[$index]

    $confirm = Read-Host "`nAre you sure you want to delete '$($job.JobName)'? (yes/no)"
    if ($confirm -eq "yes") {
        # Remove scheduled task
        try {
            $task = Get-ScheduledTask -TaskName $job.TaskName -ErrorAction SilentlyContinue
            if ($task) {
                Unregister-ScheduledTask -TaskName $job.TaskName -Confirm:$false -ErrorAction Stop
                Write-Log "Removed scheduled task: $($job.TaskName)" -Level SUCCESS
            }
        }
        catch {
            Write-Host "`nWarning: Could not remove scheduled task: $_" -ForegroundColor Yellow
        }

        # Remove from jobs list
        $jobs = $jobs | Where-Object { $_.JobName -ne $job.JobName }

        if (Save-Jobs -Jobs $jobs) {
            Write-Host "`nJob deleted successfully!" -ForegroundColor Green
            Write-Log "Deleted backup job: $($job.JobName)" -Level SUCCESS
        }
    }

    Read-Host "`nPress Enter to continue"
}

function Show-BackupStatus {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     BACKUP STATUS & HISTORY" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    $jobs = Get-Jobs

    if ($jobs.Count -eq 0) {
        Write-Host "No backup jobs configured." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    foreach ($job in $jobs) {
        Write-Host "`n$($job.JobName)" -ForegroundColor White
        Write-Host ("=" * 60) -ForegroundColor Gray

        # Status
        $statusText = if ($job.Enabled) { "Enabled" } else { "Disabled" }
        $statusColor = if ($job.Enabled) { "Green" } else { "Red" }
        Write-Host "Status: " -NoNewline -ForegroundColor Gray
        Write-Host $statusText -ForegroundColor $statusColor

        # Last run
        if ($job.LastRun) {
            Write-Host "Last Run: $($job.LastRun)" -ForegroundColor Gray

            $lastStatusColor = if ($job.LastStatus -eq "Success") { "Green" } elseif ($job.LastStatus -eq "Failed") { "Red" } else { "Yellow" }
            Write-Host "Last Status: " -NoNewline -ForegroundColor Gray
            Write-Host $job.LastStatus -ForegroundColor $lastStatusColor
        }
        else {
            Write-Host "Last Run: Never executed" -ForegroundColor Yellow
        }

        # Next scheduled run
        try {
            $task = Get-ScheduledTask -TaskName $job.TaskName -ErrorAction SilentlyContinue
            if ($task) {
                $taskInfo = Get-ScheduledTaskInfo -TaskName $job.TaskName -ErrorAction SilentlyContinue
                if ($taskInfo -and $taskInfo.NextRunTime) {
                    Write-Host "Next Run: $($taskInfo.NextRunTime)" -ForegroundColor Gray
                }
            }
        }
        catch {
            # Silently continue if we can't get task info
        }

        Write-Host "Source: $($job.BackupObject)" -ForegroundColor Gray
        Write-Host "Destination: $($job.DestinationPath)" -ForegroundColor Gray
    }

    Write-Host "`n`nRecent Log Entries:" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Gray

    # Show last 10 log entries
    $todayLog = Join-Path $LogPath "VLABS_Backup_$(Get-Date -Format 'yyyyMMdd').log"
    if (Test-Path $todayLog) {
        $logEntries = Get-Content $todayLog -Tail 10
        foreach ($entry in $logEntries) {
            if ($entry -match '\[ERROR\]') {
                Write-Host $entry -ForegroundColor Red
            }
            elseif ($entry -match '\[WARNING\]') {
                Write-Host $entry -ForegroundColor Yellow
            }
            elseif ($entry -match '\[SUCCESS\]') {
                Write-Host $entry -ForegroundColor Green
            }
            else {
                Write-Host $entry -ForegroundColor Gray
            }
        }
    }
    else {
        Write-Host "No log entries for today." -ForegroundColor Yellow
    }

    Read-Host "`n`nPress Enter to continue"
}

#endregion

#region Main Menu

function Show-MainMenu {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "         VLABS SECURE BACKUP TOOL" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    Write-Host " 1. Create Destination" -ForegroundColor White
    Write-Host " 2. Create Backup Job" -ForegroundColor White
    Write-Host " 3. Run Backup Job Now" -ForegroundColor White
    Write-Host " 4. Show all Backup Jobs" -ForegroundColor White
    Write-Host " 5. Edit Destination" -ForegroundColor White
    Write-Host " 6. Delete Destination" -ForegroundColor White
    Write-Host " 7. Edit Backup Job" -ForegroundColor White
    Write-Host " 8. Delete Backup Job" -ForegroundColor White
    Write-Host " 9. View Backup Status & History" -ForegroundColor White
    Write-Host " 0. Exit" -ForegroundColor White

    Write-Host "`n===============================================" -ForegroundColor Cyan
}

function Start-MainLoop {
    while ($true) {
        Show-MainMenu
        $choice = Read-Host "`nEnter your choice"

        switch ($choice) {
            "1" { New-BackupDestination }
            "2" { New-BackupJob }
            "3" { Invoke-BackupJobNow }
            "4" { Show-AllBackupJobs }
            "5" { Edit-BackupDestination }
            "6" { Remove-BackupDestination }
            "7" { Edit-BackupJob }
            "8" { Remove-BackupJob }
            "9" { Show-BackupStatus }
            "0" {
                Write-Host "`nExiting VLABS Secure Backup Tool..." -ForegroundColor Cyan
                Write-Log "Application closed" -Level INFO
                exit 0
            }
            default {
                Write-Host "`nInvalid choice! Please try again." -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
    }
}

#endregion

#region Main Entry Point

# Initialize and start
Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host "    VLABS SECURE BACKUP TOOL - INITIALIZING" -ForegroundColor Cyan
Write-Host "===============================================`n" -ForegroundColor Cyan

if (Initialize-Environment) {
    Write-Host "Initialization complete!" -ForegroundColor Green
    Write-Log "Application started" -Level INFO
    Start-Sleep -Seconds 1
    Start-MainLoop
}
else {
    Write-Host "`nFailed to initialize. Exiting..." -ForegroundColor Red
    exit 1
}

#endregion
