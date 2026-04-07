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

# Configuration - Data goes to ProgramData (separate from git install directory)
# This prevents git reset --hard from deleting config files during updates
$script:ConfigPath = "C:\ProgramData\VLABS_ResilienceRing"
$script:LegacyConfigPaths = @("C:\VLABS_SecureBackups", "C:\VLABS_ResilienceRing")
$script:DestinationsFile = Join-Path $ConfigPath "destinations.json"
$script:JobsFile = Join-Path $ConfigPath "jobs.json"           # Master data (config)
$script:JobsStatusFile = Join-Path $ConfigPath "jobs-status.json"  # Transaction data (run history)
$script:LogPath = Join-Path $ConfigPath "Logs"
$script:ExecutionScript = Join-Path $PSScriptRoot "Execute-Backup.ps1"

# Load crypto utilities for machine-independent password encryption
$cryptoUtilsPath = Join-Path $PSScriptRoot "CryptoUtils.ps1"
if (Test-Path $cryptoUtilsPath) {
    . $cryptoUtilsPath
}

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

        # Migrate from legacy paths (old install locations) if needed
        foreach ($LegacyPath in $LegacyConfigPaths) {
            if (-not (Test-Path $LegacyPath)) { continue }
            
            $filesToMigrate = @('destinations.json', 'jobs.json', 'ring-config.json', 'storage-peers.json')
            $migrated = $false
            
            foreach ($file in $filesToMigrate) {
                $legacyFile = Join-Path $LegacyPath $file
                $newFile = Join-Path $ConfigPath $file
                
                if ((Test-Path $legacyFile) -and -not (Test-Path $newFile)) {
                    Copy-Item -Path $legacyFile -Destination $newFile -Force
                    Write-Log "Migrated $file from $LegacyPath" -Level INFO
                    $migrated = $true
                }
            }
            
            # Migrate logs folder
            $legacyLogs = Join-Path $LegacyPath "Logs"
            if ((Test-Path $legacyLogs) -and (Get-ChildItem $legacyLogs -ErrorAction SilentlyContinue)) {
                Get-ChildItem $legacyLogs -File | ForEach-Object {
                    $destFile = Join-Path $LogPath $_.Name
                    if (-not (Test-Path $destFile)) {
                        Copy-Item -Path $_.FullName -Destination $destFile -Force
                    }
                }
                Write-Log "Migrated log files from $LegacyPath" -Level INFO
                $migrated = $true
            }
            
            if ($migrated) {
                Write-Host "[OK] Migrated data from $LegacyPath" -ForegroundColor Green
            }
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
        $result = $content | ConvertFrom-Json

        # Force result to be an array (PowerShell returns single objects as non-arrays)
        if ($result -eq $null) {
            return @()
        }

        # Use @() to ensure we always have an array, even with one item
        return @($result)
    }
    catch {
        Write-Log "Error reading destinations: $_" -Level ERROR
        return @()
    }
}

function Save-Destinations {
    param([Parameter(Mandatory=$true)] $Destinations)

    try {
        # Ensure we always have an array, even if empty
        $destinationsArray = @($Destinations)

        # ConvertTo-Json with explicit array handling
        if ($destinationsArray.Count -eq 0) {
            # Explicitly save empty array as "[]"
            "[]" | Set-Content $DestinationsFile -ErrorAction Stop
        }
        else {
            $destinationsArray | ConvertTo-Json -Depth 10 | Set-Content $DestinationsFile -ErrorAction Stop
        }
        return $true
    }
    catch {
        Write-Log "Error saving destinations: $_" -Level ERROR
        return $false
    }
}

#region Master/Transaction Data Separation
# DESIGN PRINCIPLE: Separate master data (config) from transaction data (status/history)
# - jobs.json: Master data that rarely changes (JobName, BackupType, paths, retention, schedule)
# - jobs-status.json: Transaction data that changes frequently (LastRun, LastStatus, etc.)

function Get-Jobs {
    <#
    .SYNOPSIS
        Load jobs from master data file (jobs.json)
    .DESCRIPTION
        Returns only the job configuration (master data).
        Status information is stored separately in jobs-status.json.
    #>
    try {
        if (-not (Test-Path $JobsFile)) { return @() }
        $content = Get-Content $JobsFile -Raw -ErrorAction Stop
        
        # Handle empty or whitespace-only file
        if ([string]::IsNullOrWhiteSpace($content)) {
            return @()
        }
        
        $result = $content | ConvertFrom-Json

        # Handle corrupted format where jobs are wrapped in {"value": [...]}
        if ($result -is [PSCustomObject] -and $result.PSObject.Properties.Name -contains 'value') {
            Write-Log "Detected corrupted jobs.json format, extracting from 'value' property" -Level WARNING
            $result = $result.value
        }

        # Force result to be an array
        if ($null -eq $result) { return @() }
        return @($result)
    }
    catch {
        Write-Log "Error reading jobs: $_" -Level ERROR
        return @()
    }
}

function Save-Jobs {
    <#
    .SYNOPSIS
        Save jobs to master data file (jobs.json)
    .DESCRIPTION
        Saves only master data. Strips any transaction properties before saving.
    #>
    param([Parameter(Mandatory=$true)] $Jobs)

    try {
        # Strip transaction data properties before saving master data
        $masterDataProperties = @('JobName', 'AppName', 'AppNameClean', 'BackupType', 'BackupObject',
                                   'SourceLocation', 'CustomerCode', 'TargetPeers', 'PeerDestinations',
                                   'Schedule', 'Frequency', 'StartHour', 'Retention', 'RetentionMonthly',
                                   'RetentionWeekly', 'RetentionRecent', 'TaskName', 'Enabled',
                                   'Destination', 'DestinationPath', 'DestinationDomain',
                                   'DestinationUsername', 'DestinationEncryptedPassword', 'CreatedDate')
        
        $cleanJobs = @()
        foreach ($job in $Jobs) {
            $cleanJob = @{}
            foreach ($prop in $masterDataProperties) {
                if ($null -ne $job.$prop) {
                    $cleanJob[$prop] = $job.$prop
                }
            }
            $cleanJobs += [PSCustomObject]$cleanJob
        }
        
        if ($cleanJobs.Count -eq 0) {
            "[]" | Set-Content $JobsFile -ErrorAction Stop
        }
        else {
            $json = ConvertTo-Json -InputObject $cleanJobs -Depth 10
            Set-Content -Path $JobsFile -Value $json -ErrorAction Stop
        }
        return $true
    }
    catch {
        Write-Log "Error saving jobs: $_" -Level ERROR
        return $false
    }
}

function Get-JobsStatus {
    <#
    .SYNOPSIS
        Load job status from transaction data file (jobs-status.json)
    .DESCRIPTION
        Returns a hashtable keyed by JobName with status information.
    #>
    try {
        if (-not (Test-Path $JobsStatusFile)) { return @{} }
        $content = Get-Content $JobsStatusFile -Raw -ErrorAction Stop
        
        if ([string]::IsNullOrWhiteSpace($content)) { return @{} }
        
        $result = $content | ConvertFrom-Json
        
        # Handle corrupted format
        if ($result -is [PSCustomObject] -and $result.PSObject.Properties.Name -contains 'value') {
            $result = $result.value
        }
        
        # Convert to hashtable for fast lookup
        $statusTable = @{}
        if ($result) {
            foreach ($status in @($result)) {
                if ($status.JobName) {
                    $statusTable[$status.JobName] = $status
                }
            }
        }
        return $statusTable
    }
    catch {
        Write-Log "Error reading jobs status: $_" -Level ERROR
        return @{}
    }
}

function Save-JobsStatus {
    <#
    .SYNOPSIS
        Save job status to transaction data file (jobs-status.json)
    #>
    param([hashtable]$StatusTable)
    try {
        $statusArray = @($StatusTable.Values)
        if ($statusArray.Count -eq 0) {
            "[]" | Set-Content $JobsStatusFile -ErrorAction Stop
        }
        else {
            $json = ConvertTo-Json -InputObject $statusArray -Depth 10
            Set-Content -Path $JobsStatusFile -Value $json -ErrorAction Stop
        }
        return $true
    }
    catch {
        Write-Log "Error saving jobs status: $_" -Level ERROR
        return $false
    }
}

function Update-JobStatus {
    <#
    .SYNOPSIS
        Update status for a specific job in transaction data file
    .DESCRIPTION
        Updates only the transaction data file, not the master data.
    #>
    param(
        [string]$JobName, 
        [string]$Status,
        [int]$DurationSeconds = 0,
        [long]$SizeBytes = 0
    )
    
    $statusTable = Get-JobsStatus
    
    $statusTable[$JobName] = [PSCustomObject]@{
        JobName = $JobName
        LastRun = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        LastStatus = $Status
        LastDurationSeconds = $DurationSeconds
        LastSizeBytes = $SizeBytes
    }
    
    Save-JobsStatus -StatusTable $statusTable
}

function Get-JobsWithStatus {
    <#
    .SYNOPSIS
        Merge master data with transaction data for display purposes
    .DESCRIPTION
        Returns jobs with status information attached (read-only, for display).
    #>
    $jobs = Get-Jobs
    $statusTable = Get-JobsStatus
    
    foreach ($job in $jobs) {
        $status = $statusTable[$job.JobName]
        if ($status) {
            $job | Add-Member -NotePropertyName 'LastRun' -NotePropertyValue $status.LastRun -Force
            $job | Add-Member -NotePropertyName 'LastStatus' -NotePropertyValue $status.LastStatus -Force
            $job | Add-Member -NotePropertyName 'LastDurationSeconds' -NotePropertyValue $status.LastDurationSeconds -Force
            $job | Add-Member -NotePropertyName 'LastSizeBytes' -NotePropertyValue $status.LastSizeBytes -Force
        }
    }
    
    return $jobs
}

function Get-RingPolicies {
    <#
    .SYNOPSIS
        Reads ring policies from local _nodeinfo/ring-policies.json
    .DESCRIPTION
        Returns policies set by RRM, or defaults if not available.
    #>
    $defaults = @{
        RetentionMonthlyMin = 0; RetentionMonthlyMax = 3
        RetentionWeeklyMin = 0; RetentionWeeklyMax = 4
        RetentionRecentMin = 1; RetentionRecentMax = 6
    }
    
    try {
        $config = Get-RingConfig
        if (-not $config -or -not $config.StoragePath) {
            return [PSCustomObject]$defaults
        }
        
        $policyFile = Join-Path $config.StoragePath "_nodeinfo\ring-policies.json"
        if (-not (Test-Path $policyFile)) {
            return [PSCustomObject]$defaults
        }
        
        $policyData = Get-Content $policyFile -Raw | ConvertFrom-Json
        if ($policyData.Policies) {
            $result = @{}
            foreach ($key in $defaults.Keys) {
                $result[$key] = if ($null -ne $policyData.Policies.$key) { $policyData.Policies.$key } else { $defaults[$key] }
            }
            return [PSCustomObject]$result
        }
    }
    catch { }
    
    return [PSCustomObject]$defaults
}

#endregion Master/Transaction Data Separation

#endregion

#region Credential Management Functions

function ConvertTo-EncryptedPassword {
    param(
        [Parameter(Mandatory=$true)]
        [string]$PlainTextPassword
    )

    try {
        # Use AES encryption if CryptoUtils is available (machine-independent)
        if (Get-Command 'Protect-Password' -ErrorAction SilentlyContinue) {
            $encrypted = Protect-Password -PlainTextPassword $PlainTextPassword
            if ($encrypted) {
                return $encrypted
            }
        }
        
        # Fallback to DPAPI (legacy, user-specific)
        $securePassword = ConvertTo-SecureString -String $PlainTextPassword -AsPlainText -Force
        $encryptedPassword = ConvertFrom-SecureString -SecureString $securePassword
        return $encryptedPassword
    }
    catch {
        Write-Log "Error encrypting password: $_" -Level ERROR
        return $null
    }
}

function ConvertFrom-EncryptedPassword {
    param(
        [Parameter(Mandatory=$true)]
        [string]$EncryptedPassword
    )

    try {
        $securePassword = ConvertTo-SecureString -String $EncryptedPassword
        return $securePassword
    }
    catch {
        Write-Log "Error decrypting password: $_" -Level ERROR
        return $null
    }
}

function Get-PlainTextPassword {
    param(
        [Parameter(Mandatory=$true)]
        [System.Security.SecureString]$SecurePassword
    )

    try {
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        return $plainPassword
    }
    catch {
        Write-Log "Error converting secure password: $_" -Level ERROR
        return $null
    }
}

function Split-UncPath {
    param(
        [Parameter(Mandatory=$true)]
        [string]$UncPath
    )

    try {
        # Parse UNC path: \\server\share\subfolder1\subfolder2
        # Return: @{ Server = "server"; Share = "share"; SubPath = "subfolder1\subfolder2"; SharePath = "\\server\share" }

        if ($UncPath -notmatch '^\\\\([^\\]+)\\([^\\]+)(.*)$') {
            Write-Host "Invalid UNC path format. Expected: \\server\share\subfolder" -ForegroundColor Red
            return $null
        }

        $server = $matches[1]
        $share = $matches[2]
        $subPath = $matches[3].TrimStart('\')

        return @{
            Server = $server
            Share = $share
            SubPath = $subPath
            SharePath = "\\$server\$share"
            FullPath = $UncPath
        }
    }
    catch {
        Write-Log "Error parsing UNC path: $_" -Level ERROR
        return $null
    }
}

function Connect-SmbShare {
    param(
        [Parameter(Mandatory=$true)]
        $Destination
    )

    try {
        $pathInfo = Split-UncPath -UncPath $Destination.Path
        if (-not $pathInfo) {
            Write-Host "Failed to parse destination path" -ForegroundColor Red
            return $false
        }

        # Check if already connected
        $existingConnection = net use | Select-String -Pattern "\\\\$($pathInfo.Server)\\$($pathInfo.Share)"
        if ($existingConnection) {
            Write-Log "Share already connected: $($pathInfo.SharePath)" -Level INFO
            return $true
        }

        # Decrypt password
        $securePassword = ConvertFrom-EncryptedPassword -EncryptedPassword $Destination.EncryptedPassword
        if (-not $securePassword) {
            Write-Host "Failed to decrypt password" -ForegroundColor Red
            return $false
        }

        $plainPassword = Get-PlainTextPassword -SecurePassword $securePassword
        if (-not $plainPassword) {
            Write-Host "Failed to retrieve password" -ForegroundColor Red
            return $false
        }

        # Build credentials string
        $userString = if ($Destination.Domain) {
            "$($Destination.Domain)\$($Destination.Username)"
        } else {
            $Destination.Username
        }

        # Connect using net use
        Write-Host "Connecting to $($pathInfo.SharePath)..." -ForegroundColor Yellow

        # Use cmd.exe to properly handle the password with special characters
        $netUseCmd = "net use `"$($pathInfo.SharePath)`" /user:`"$userString`" `"$plainPassword`" 2>&1"
        $result = cmd.exe /c $netUseCmd

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Successfully connected to share" -ForegroundColor Green
            Write-Log "Connected to SMB share: $($pathInfo.SharePath)" -Level SUCCESS
            return $true
        }
        else {
            Write-Host "Failed to connect to share: $result" -ForegroundColor Red
            Write-Log "Failed to connect to SMB share $($pathInfo.SharePath): $result" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Host "Error connecting to SMB share: $_" -ForegroundColor Red
        Write-Log "Error connecting to SMB share: $_" -Level ERROR
        return $false
    }
}

function Disconnect-SmbShare {
    param(
        [Parameter(Mandatory=$true)]
        $Destination
    )

    try {
        $pathInfo = Split-UncPath -UncPath $Destination.Path
        if (-not $pathInfo) {
            Write-Log "Failed to parse destination path for disconnect" -Level WARNING
            return $false
        }

        # Check if connected
        $existingConnection = net use | Select-String -Pattern "\\\\$($pathInfo.Server)\\$($pathInfo.Share)"
        if (-not $existingConnection) {
            Write-Log "Share not connected: $($pathInfo.SharePath)" -Level INFO
            return $true
        }

        # Disconnect using net use
        Write-Host "Disconnecting from $($pathInfo.SharePath)..." -ForegroundColor Yellow

        $result = net use $pathInfo.SharePath /delete 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Successfully disconnected from share" -ForegroundColor Green
            Write-Log "Disconnected from SMB share: $($pathInfo.SharePath)" -Level SUCCESS
            return $true
        }
        else {
            Write-Host "Failed to disconnect from share: $result" -ForegroundColor Yellow
            Write-Log "Failed to disconnect from SMB share $($pathInfo.SharePath): $result" -Level WARNING
            return $false
        }
    }
    catch {
        Write-Host "Error disconnecting from SMB share: $_" -ForegroundColor Yellow
        Write-Log "Error disconnecting from SMB share: $_" -Level WARNING
        return $false
    }
}

#endregion

#region Destination Management

function Test-SmbDestination {
    param(
        [Parameter(Mandatory=$true)]
        $Destination
    )

    try {
        # Validate UNC path format
        $pathInfo = Split-UncPath -UncPath $Destination.Path
        if (-not $pathInfo) {
            return $false
        }

        # Connect to the share
        Write-Host "Step 1: Connecting to share..." -ForegroundColor Cyan
        if (-not (Connect-SmbShare -Destination $Destination)) {
            return $false
        }

        # Navigate to and test the full path including subfolders
        Write-Host "Step 2: Verifying path and subfolders..." -ForegroundColor Cyan
        if (-not (Test-Path $Destination.Path)) {
            Write-Host "Path does not exist: $($Destination.Path)" -ForegroundColor Red
            Write-Host "Creating directory structure..." -ForegroundColor Yellow
            try {
                New-Item -Path $Destination.Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-Host "Directory created successfully" -ForegroundColor Green
            }
            catch {
                Write-Host "Failed to create directory: $_" -ForegroundColor Red
                Disconnect-SmbShare -Destination $Destination
                return $false
            }
        }

        # Test write permissions
        Write-Host "Step 3: Testing write permissions..." -ForegroundColor Cyan
        $testFile = Join-Path $Destination.Path "vlabs_test_$(Get-Date -Format 'yyyyMMddHHmmss').tmp"
        try {
            "test" | Out-File -FilePath $testFile -ErrorAction Stop
            Remove-Item $testFile -Force -ErrorAction Stop
            Write-Host "Write test successful!" -ForegroundColor Green
        }
        catch {
            Write-Host "Path is not writable: $_" -ForegroundColor Red
            Disconnect-SmbShare -Destination $Destination
            return $false
        }

        # Disconnect from the share
        Write-Host "Step 4: Disconnecting from share..." -ForegroundColor Cyan
        Disconnect-SmbShare -Destination $Destination | Out-Null

        Write-Host "`nDestination verification completed successfully!" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Error testing destination: $_" -ForegroundColor Red
        Disconnect-SmbShare -Destination $Destination | Out-Null
        return $false
    }
}

function New-BackupDestination {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     CREATE BACKUP DESTINATION" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    # Check if ring is configured
    $ringConfig = Get-RingConfig
    if (-not $ringConfig -or -not $ringConfig.CustomerCode) {
        Write-Host "ERROR: This machine is not configured as a storage peer." -ForegroundColor Red
        Write-Host ""
        Write-Host "Please run 'Add Storage Peer' (P) first to configure this machine." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }
    
    $localLocation = Get-LocalLocation
    $customerCode = $ringConfig.CustomerCode
    
    Write-Host "Customer: $customerCode" -ForegroundColor Cyan
    Write-Host "Location: $localLocation" -ForegroundColor Cyan
    Write-Host ""

    # Step 1: Application Name
    Write-Host "--- Step 1: Application Name ---" -ForegroundColor Yellow
    Write-Host "Enter a name for the application being backed up."
    Write-Host "Examples: Community, Salto, SAP, QuickBooks"
    Write-Host ""
    $appName = Read-Host "Application Name"
    if ([string]::IsNullOrWhiteSpace($appName)) {
        Write-Host "`nError: Application name cannot be empty!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Step 2: Backup Type
    Write-Host "`n--- Step 2: Select Backup Type ---" -ForegroundColor Yellow
    Write-Host "F   = File (single file)"
    Write-Host "D   = Directory (entire folder)"
    Write-Host "SQL = SQL Server Database (backup folder)"
    $backupType = Read-Host "`nEnter type (F/D/SQL)"

    $backupType = $backupType.ToUpper()
    if ($backupType -notin @("F", "D", "SQL")) {
        Write-Host "`nInvalid backup type!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    # Step 3: Backup Object
    Write-Host "`n--- Step 3: Enter Backup Object ---" -ForegroundColor Yellow
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

    # Step 4: Select Storage Peer
    Write-Host "`n--- Step 4: Select Storage Peer ---" -ForegroundColor Yellow
    Write-Host "Checking available storage peers..." -ForegroundColor Gray
    
    $availablePeers = Get-AvailableStoragePeers
    
    if ($availablePeers.Count -eq 0) {
        Write-Host "`nNo storage peers available!" -ForegroundColor Red
        Write-Host ""
        Write-Host "Possible reasons:" -ForegroundColor Gray
        Write-Host "  - Other machines haven't run 'Add Storage Peer' (P)" -ForegroundColor Gray
        Write-Host "  - Other machines are offline" -ForegroundColor Gray
        Write-Host "  - Run 'Discover & Update' (D) to refresh the peer list" -ForegroundColor Gray
        Read-Host "`nPress Enter to continue"
        return
    }
    
    Write-Host ""
    Write-Host "  #  | Ping   | Location             | Tailscale Name" -ForegroundColor Gray
    Write-Host " ----|--------|----------------------|--------------------" -ForegroundColor Gray
    
    for ($i = 0; $i -lt $availablePeers.Count; $i++) {
        $peer = $availablePeers[$i]
        $pingColor = if ($peer.PingMs -lt 50) { 'Green' } elseif ($peer.PingMs -lt 100) { 'Yellow' } else { 'Red' }
        $locationStr = if ($peer.Location) { $peer.Location } else { "N/A" }
        if ($locationStr.Length -gt 20) { $locationStr = $locationStr.Substring(0, 17) + "..." }
        $hostStr = if ($peer.Hostname) { $peer.Hostname } else { "Unknown" }
        
        Write-Host (" {0,2} |" -f ($i + 1)) -NoNewline
        Write-Host (" {0,5}ms" -f $peer.PingMs) -ForegroundColor $pingColor -NoNewline
        Write-Host (" | {0,-20} | {1}" -f $locationStr, $hostStr)
    }
    
    Write-Host ""
    $peerSelection = Read-Host "Select storage peer number (or 0 to cancel)"
    $peerIndex = [int]$peerSelection - 1
    
    if ($peerSelection -eq "0" -or $peerIndex -lt 0 -or $peerIndex -ge $availablePeers.Count) {
        Write-Host "`nOperation cancelled." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }
    
    $selectedPeer = $availablePeers[$peerIndex]
    
    # Build destination path
    # Format: \\IP\RR_Backups\CUSTOMER_CODE\Location\Application\type\
    $destPath = Get-DestinationPath `
        -TailscaleIP $selectedPeer.TailscaleIP `
        -CustomerCode $customerCode `
        -Location $localLocation `
        -Application $appName `
        -BackupType $backupType
    
    Write-Host "`nDestination path will be:" -ForegroundColor Cyan
    Write-Host "  $destPath" -ForegroundColor White
    
    # Create destination path and verify
    Write-Host "`n--- Verifying Destination ---" -ForegroundColor Yellow
    
    if (-not (Initialize-DestinationPath -TailscaleIP $selectedPeer.TailscaleIP -DestinationPath $destPath -CustomerCode $customerCode)) {
        Write-Host "`nDestination verification failed!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }
    
    # Generate short name from app name
    $shortName = "$appName-$backupType-$($selectedPeer.Hostname)"
    
    # Get service account credentials for this destination
    $servicePassword = Get-RingServicePassword -CustomerCode $customerCode
    $encryptedPassword = ConvertTo-EncryptedPassword -PlainTextPassword $servicePassword
    
    # Check if destination name already exists
    $destinations = @(Get-Destinations)
    if ($destinations | Where-Object { $_.ShortName -eq $shortName }) {
        $counter = 2
        $baseShortName = $shortName
        while ($destinations | Where-Object { $_.ShortName -eq $shortName }) {
            $shortName = "$baseShortName-$counter"
            $counter++
        }
    }
    
    # Create destination object
    $newDestination = @{
        ShortName = $shortName
        Application = $appName
        BackupType = $backupType
        BackupObject = $backupObject
        Path = $destPath
        StoragePeerIP = $selectedPeer.TailscaleIP
        StoragePeerHostname = $selectedPeer.Hostname
        StoragePeerLocation = $selectedPeer.Location
        CustomerCode = $customerCode
        SourceLocation = $localLocation
        Domain = ""
        Username = "RR_Service"
        EncryptedPassword = $encryptedPassword
        CreatedDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    
    $destinations += $newDestination
    
    if (Save-Destinations -Destinations $destinations) {
        Write-Host "`n===============================================" -ForegroundColor Green
        Write-Host "     DESTINATION CREATED SUCCESSFULLY!" -ForegroundColor Green
        Write-Host "===============================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Name:        $shortName" -ForegroundColor White
        Write-Host "  Application: $appName" -ForegroundColor White
        Write-Host "  Type:        $backupType" -ForegroundColor White
        Write-Host "  Source:      $backupObject" -ForegroundColor White
        Write-Host "  Destination: $destPath" -ForegroundColor White
        Write-Host "  Storage Peer: $($selectedPeer.Hostname) @ $($selectedPeer.Location)" -ForegroundColor White
        Write-Host ""
        Write-Log "Created destination: $shortName -> $destPath" -Level SUCCESS
    }
    else {
        Write-Host "`nFailed to save destination!" -ForegroundColor Red
    }

    Read-Host "`nPress Enter to continue"
}

function Show-Destinations {
    $destinations = @(Get-Destinations)

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
    Write-Host "Current user: $($dest.Domain)\$($dest.Username)" -ForegroundColor Gray

    Write-Host "`nWhat would you like to edit?" -ForegroundColor Cyan
    Write-Host "1. Path"
    Write-Host "2. Credentials (domain, username, password)"
    Write-Host "3. Cancel"

    $choice = Read-Host "`nEnter choice"

    $updated = $false

    switch ($choice) {
        "1" {
            $newPath = Read-Host "`nEnter new SMB path (e.g., \\server\share\subfolder1\subfolder2)"
            if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                # Validate path format
                $pathInfo = Split-UncPath -UncPath $newPath
                if ($pathInfo) {
                    # Create test destination with new path
                    $testDest = @{
                        Path = $newPath
                        Domain = $dest.Domain
                        Username = $dest.Username
                        EncryptedPassword = $dest.EncryptedPassword
                    }

                    Write-Host "`nVerifying new destination..." -ForegroundColor Yellow
                    if (Test-SmbDestination -Destination $testDest) {
                        $destinations[$index].Path = $newPath
                        $updated = $true
                    }
                    else {
                        Write-Host "`nDestination verification failed! Changes not saved." -ForegroundColor Red
                    }
                }
            }
        }
        "2" {
            Write-Host "`n--- Update Credentials ---" -ForegroundColor Yellow
            $newDomain = Read-Host "Enter domain (current: $($dest.Domain), press Enter to keep)"
            $newUsername = Read-Host "Enter username (current: $($dest.Username), press Enter to keep)"
            $newPassword = Read-Host "Enter new password (press Enter to keep current)" -AsSecureString

            $passwordChanged = $false
            $plainNewPassword = Get-PlainTextPassword -SecurePassword $newPassword
            if (-not [string]::IsNullOrWhiteSpace($plainNewPassword)) {
                $passwordChanged = $true
            }

            # Update fields
            if (-not [string]::IsNullOrWhiteSpace($newDomain)) {
                $destinations[$index].Domain = $newDomain
            }
            if (-not [string]::IsNullOrWhiteSpace($newUsername)) {
                $destinations[$index].Username = $newUsername
            }
            if ($passwordChanged) {
                $encryptedPassword = ConvertTo-EncryptedPassword -PlainTextPassword $plainNewPassword
                if ($encryptedPassword) {
                    $destinations[$index].EncryptedPassword = $encryptedPassword
                }
            }

            # Test the updated credentials
            Write-Host "`nVerifying updated credentials..." -ForegroundColor Yellow
            if (Test-SmbDestination -Destination $destinations[$index]) {
                $updated = $true
            }
            else {
                Write-Host "`nCredential verification failed! Reverting changes." -ForegroundColor Red
                # Revert changes
                $destinations[$index] = $dest
            }
        }
        "3" {
            Read-Host "`nPress Enter to continue"
            return
        }
        default {
            Write-Host "`nInvalid choice!" -ForegroundColor Red
        }
    }

    if ($updated) {
        if (Save-Destinations -Destinations $destinations) {
            Write-Host "`nDestination updated successfully!" -ForegroundColor Green
            Write-Log "Updated destination: $($dest.ShortName)" -Level SUCCESS
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
    $jobs = @(Get-Jobs)

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
        # Use @() to ensure we get an empty array, not null, if this is the last item
        $destinations = @($destinations | Where-Object { $_.ShortName -ne $dest.ShortName })
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
    $destinations = @(Get-Destinations)
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
    $jobs = @(Get-Jobs)
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

    # Create job object (including credentials from destination)
    $newJob = @{
        JobName = $jobName
        BackupType = $backupType
        BackupObject = $backupObject
        Destination = $selectedDestination.ShortName
        DestinationPath = $selectedDestination.Path
        DestinationDomain = $selectedDestination.Domain
        DestinationUsername = $selectedDestination.Username
        DestinationEncryptedPassword = $selectedDestination.EncryptedPassword
        Retention = [int]$retention
        Frequency = [int]$frequency
        StartHour = [int]$startHour
        CreatedDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        TaskName = "VLABS_Backup_$jobName"
        Enabled = $true
        # Note: LastRun/LastStatus are now stored in jobs-status.json (transaction data)
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

        # If frequency is less than 24 hours, use a Once trigger with repetition
        if ($Job.Frequency -lt 24) {
            # Use -Once trigger with repetition interval and duration
            # Use 9999 days as practical "indefinite" duration (about 27 years)
            $repetitionDuration = New-TimeSpan -Days 9999
            $repetitionInterval = New-TimeSpan -Hours $Job.Frequency

            $trigger = New-ScheduledTaskTrigger -Once -At $startTime `
                -RepetitionInterval $repetitionInterval `
                -RepetitionDuration $repetitionDuration
        }
        else {
            # For 24-hour frequency, just use a daily trigger
            $trigger = New-ScheduledTaskTrigger -Daily -At $startTime
        }

        $triggers += $trigger

        # Create task principal (run as current user with highest privileges)
        # This ensures DPAPI encryption/decryption works correctly for stored credentials
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -RunLevel Highest

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

    # Use Get-JobsWithStatus to merge master data with transaction data for display
    $jobs = @(Get-JobsWithStatus)

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

        # Handle both new format (PeerDestinations) and legacy format (Destination/DestinationPath)
        $backupTypeDisplay = if ($job.BackupType) { $typeMap[$job.BackupType] } else { "Unknown" }
        Write-Host "    Type: $backupTypeDisplay" -ForegroundColor Gray
        Write-Host "    Source: $($job.BackupObject)" -ForegroundColor Gray
        
        if ($job.PeerDestinations -and $job.PeerDestinations.Count -gt 0) {
            Write-Host "    Peers: $($job.PeerDestinations.Count) destination(s)" -ForegroundColor Gray
        }
        elseif ($job.DestinationPath) {
            Write-Host "    Destination: $($job.Destination) ($($job.DestinationPath))" -ForegroundColor Gray
        }
        
        # Handle both new retention format and legacy
        if ($null -ne $job.RetentionMonthly -or $null -ne $job.RetentionWeekly -or $null -ne $job.RetentionRecent) {
            Write-Host "    Retention: $($job.RetentionMonthly) monthly, $($job.RetentionWeekly) weekly, $($job.RetentionRecent) recent" -ForegroundColor Gray
        }
        elseif ($job.Retention) {
            Write-Host "    Retention: $($job.Retention) copies" -ForegroundColor Gray
        }
        
        Write-Host "    Frequency: Every $($job.Frequency) hour(s), starting at $($job.StartHour):00" -ForegroundColor Gray

        if ($job.LastRun) {
            $statusColor = if ($job.LastStatus -eq "Success") { "Green" } elseif ($job.LastStatus -eq "Running") { "Yellow" } else { "Red" }
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

    $jobs = @(Get-Jobs)

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

    # Use Get-JobsWithStatus for display (includes LastRun/LastStatus)
    $jobs = @(Get-JobsWithStatus)

    if ($jobs.Count -eq 0) {
        Write-Host "No backup jobs configured." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    # Display jobs with details
    Write-Host "Available Jobs:" -ForegroundColor Yellow
    Write-Host ""
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $j = $jobs[$i]
        $status = if ($j.Enabled -eq $false) { "[DISABLED]" } else { "" }
        $lastStatus = if ($j.LastStatus) { "- Last: $($j.LastStatus)" } else { "- Never run" }
        Write-Host "  [$($i + 1)] $($j.JobName) $status" -ForegroundColor $(if($j.Enabled -eq $false){"Gray"}else{"White"})
        Write-Host "      Type: $($j.BackupType) | Source: $(Split-Path $j.BackupObject -Leaf) $lastStatus" -ForegroundColor Gray
    }

    Write-Host ""
    $selection = Read-Host "Select job number to edit (or 0 to cancel)"
    $index = [int]$selection - 1

    if ($selection -eq "0" -or $index -lt 0 -or $index -ge $jobs.Count) {
        return
    }

    $job = $jobs[$index]
    
    # Determine if new format (has RetentionMonthly) or legacy (has Retention)
    $isNewFormat = $null -ne $job.RetentionMonthly

    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     EDIT: $($job.JobName)" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan
    
    # Show current settings
    Write-Host "Current Settings:" -ForegroundColor Yellow
    Write-Host "  Application:  $($job.AppName)" -ForegroundColor White
    Write-Host "  Type:         $($job.BackupType)" -ForegroundColor White
    Write-Host "  Source:       $($job.BackupObject)" -ForegroundColor White
    if ($job.SourceLocation) {
        Write-Host "  Location:     $($job.SourceLocation)" -ForegroundColor White
    }
    
    if ($isNewFormat) {
        Write-Host "  Retention:    $($job.RetentionMonthly) monthly, $($job.RetentionWeekly) weekly, $($job.RetentionRecent) recent" -ForegroundColor White
        if ($job.PeerDestinations) {
            Write-Host "  Peers:        $($job.PeerDestinations.Count) destination(s)" -ForegroundColor White
        }
    }
    else {
        Write-Host "  Retention:    $($job.Retention) copies (legacy)" -ForegroundColor White
    }
    
    Write-Host "  Frequency:    Every $($job.Frequency) hour(s), starting at $($job.StartHour):00" -ForegroundColor White
    Write-Host "  Status:       $(if($job.Enabled -ne $false){'Enabled'}else{'Disabled'})" -ForegroundColor $(if($job.Enabled -ne $false){"Green"}else{"Red"})
    
    Write-Host ""
    Write-Host "What would you like to edit?" -ForegroundColor Cyan
    Write-Host "  1. Retention policy"
    Write-Host "  2. Schedule (frequency and start hour)"
    Write-Host "  3. Enable/Disable job"
    Write-Host "  4. Source path"
    Write-Host "  5. Destination peers"
    Write-Host "  0. Cancel"

    $choice = Read-Host "`nEnter choice"

    switch ($choice) {
        "1" {
            Write-Host ""
            if ($isNewFormat) {
                # Get retention limits from ring policies (set by RRM)
                $policies = Get-RingPolicies
                $monthlyMin = $policies.RetentionMonthlyMin; $monthlyMax = $policies.RetentionMonthlyMax
                $weeklyMin = $policies.RetentionWeeklyMin; $weeklyMax = $policies.RetentionWeeklyMax
                $recentMin = $policies.RetentionRecentMin; $recentMax = $policies.RetentionRecentMax
                
                Write-Host "Current: $($job.RetentionMonthly) monthly, $($job.RetentionWeekly) weekly, $($job.RetentionRecent) recent" -ForegroundColor Gray
                Write-Host "Limits: Monthly 0-$monthlyMax, Weekly 0-$weeklyMax, Recent $recentMin-$recentMax" -ForegroundColor Gray
                Write-Host ""
                $newMonthly = Read-Host "Monthly copies (0-$monthlyMax) [$($job.RetentionMonthly)]"
                $newWeekly = Read-Host "Weekly copies (0-$weeklyMax) [$($job.RetentionWeekly)]"
                $newRecent = Read-Host "Recent copies ($recentMin-$recentMax) [$($job.RetentionRecent)]"
                
                if ([string]::IsNullOrWhiteSpace($newMonthly)) { $newMonthly = $job.RetentionMonthly }
                if ([string]::IsNullOrWhiteSpace($newWeekly)) { $newWeekly = $job.RetentionWeekly }
                if ([string]::IsNullOrWhiteSpace($newRecent)) { $newRecent = $job.RetentionRecent }
                
                # Validate within limits
                $valid = $true
                if (($newMonthly -as [int]) -lt $monthlyMin -or ($newMonthly -as [int]) -gt $monthlyMax) {
                    Write-Host "Monthly must be between $monthlyMin and $monthlyMax" -ForegroundColor Red
                    $valid = $false
                }
                if (($newWeekly -as [int]) -lt $weeklyMin -or ($newWeekly -as [int]) -gt $weeklyMax) {
                    Write-Host "Weekly must be between $weeklyMin and $weeklyMax" -ForegroundColor Red
                    $valid = $false
                }
                if (($newRecent -as [int]) -lt $recentMin -or ($newRecent -as [int]) -gt $recentMax) {
                    Write-Host "Recent must be between $recentMin and $recentMax" -ForegroundColor Red
                    $valid = $false
                }
                
                if ($valid) {
                    $jobs[$index].RetentionMonthly = [int]$newMonthly
                    $jobs[$index].RetentionWeekly = [int]$newWeekly
                    $jobs[$index].RetentionRecent = [int]$newRecent
                    Write-Host "`nRetention updated!" -ForegroundColor Green
                }
            }
            else {
                Write-Host "Current: $($job.Retention) copies" -ForegroundColor Gray
                $newRetention = Read-Host "Enter new retention (number of copies to keep)"
                if (($newRetention -as [int]) -and [int]$newRetention -gt 0) {
                    $jobs[$index].Retention = [int]$newRetention
                    Write-Host "`nRetention updated!" -ForegroundColor Green
                }
                else {
                    Write-Host "`nInvalid retention value!" -ForegroundColor Red
                }
            }
        }
        "2" {
            Write-Host ""
            Write-Host "Current: Every $($job.Frequency) hour(s), starting at $($job.StartHour):00" -ForegroundColor Gray
            $newFrequency = Read-Host "Frequency in hours (1-24) [$($job.Frequency)]"
            $newStartHour = Read-Host "Start hour (0-23) [$($job.StartHour)]"

            if ([string]::IsNullOrWhiteSpace($newFrequency)) { $newFrequency = $job.Frequency }
            if ([string]::IsNullOrWhiteSpace($newStartHour)) { $newStartHour = $job.StartHour }

            if (($newFrequency -as [int]) -ge 1 -and ($newFrequency -as [int]) -le 24 -and
                ($newStartHour -as [int]) -ge 0 -and ($newStartHour -as [int]) -le 23) {

                $jobs[$index].Frequency = [int]$newFrequency
                $jobs[$index].StartHour = [int]$newStartHour

                # Recreate scheduled task
                Write-Host "Updating scheduled task..." -ForegroundColor Gray
                if (New-ScheduledBackupTask -Job $jobs[$index]) {
                    Write-Host "`nSchedule updated!" -ForegroundColor Green
                }
            }
            else {
                Write-Host "`nInvalid frequency or start hour!" -ForegroundColor Red
            }
        }
        "3" {
            $jobs[$index].Enabled = -not ($jobs[$index].Enabled -ne $false)
            $status = if ($jobs[$index].Enabled) { "enabled" } else { "disabled" }

            # Enable or disable the scheduled task
            try {
                $taskName = if ($job.TaskName) { $job.TaskName } else { "VLABS_Backup_$($job.JobName)" }
                if ($jobs[$index].Enabled) {
                    Enable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
                }
                else {
                    Disable-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
                }
                Write-Host "`nJob $status!" -ForegroundColor Green
                Write-Log "Job $($job.JobName) $status" -Level INFO
            }
            catch {
                Write-Host "`nJob $status in config, but scheduled task error: $_" -ForegroundColor Yellow
            }
        }
        "4" {
            Write-Host ""
            Write-Host "Current source: $($job.BackupObject)" -ForegroundColor Gray
            $newPath = Read-Host "Enter new source path"
            
            if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                if (Test-Path $newPath) {
                    $jobs[$index].BackupObject = $newPath
                    Write-Host "`nSource path updated!" -ForegroundColor Green
                }
                else {
                    Write-Host "`nWarning: Path does not exist!" -ForegroundColor Yellow
                    $confirm = Read-Host "Save anyway? (yes/no)"
                    if ($confirm -eq "yes") {
                        $jobs[$index].BackupObject = $newPath
                        Write-Host "`nSource path updated!" -ForegroundColor Green
                    }
                }
            }
        }
        "5" {
            # Manage destination peers
            $availablePeers = @(Get-StoragePeersList)
            if ($availablePeers.Count -eq 0) {
                Write-Host "`nNo peers in local list. Run 'Discover & Update' (D) first." -ForegroundColor Yellow
            }
            else {
                $currentDestinations = if ($jobs[$index].PeerDestinations) { @($jobs[$index].PeerDestinations) } else { @() }

                :peerMenu while ($true) {
                    Clear-Host
                    Write-Host "`n===============================================" -ForegroundColor Cyan
                    Write-Host "     DESTINATION PEERS: $($job.JobName)" -ForegroundColor Cyan
                    Write-Host "===============================================`n" -ForegroundColor Cyan

                    Write-Host "Current destinations:" -ForegroundColor Yellow
                    if ($currentDestinations.Count -eq 0) {
                        Write-Host "  (none)" -ForegroundColor Gray
                    }
                    else {
                        for ($d = 0; $d -lt $currentDestinations.Count; $d++) {
                            $dest = $currentDestinations[$d]
                            $label = if ($dest.Location) { $dest.Location } else { $dest.Hostname }
                            Write-Host "  [$($d+1)] $label | $($dest.Hostname) | $($dest.TailscaleIP)" -ForegroundColor White
                        }
                    }

                    Write-Host ""
                    Write-Host "Available peers to add:" -ForegroundColor Yellow
                    $addable = @($availablePeers | Where-Object {
                        $ip = $_.TailscaleIP
                        -not ($currentDestinations | Where-Object { $_.TailscaleIP -eq $ip })
                    })
                    if ($addable.Count -eq 0) {
                        Write-Host "  (all known peers are already destinations)" -ForegroundColor Gray
                    }
                    else {
                        for ($a = 0; $a -lt $addable.Count; $a++) {
                            $p = $addable[$a]
                            $label = if ($p.Location) { $p.Location } else { $p.Hostname }
                            Write-Host "  [A$($a+1)] $label | $($p.Hostname) | $($p.TailscaleIP)" -ForegroundColor Cyan
                        }
                    }

                    Write-Host ""
                    Write-Host "  R# - Remove destination (e.g. R1)" -ForegroundColor Gray
                    Write-Host "  A# - Add peer as destination (e.g. A1)" -ForegroundColor Gray
                    Write-Host "  0  - Done" -ForegroundColor Gray
                    Write-Host ""
                    $peerChoice = (Read-Host "Choice").Trim()

                    if ($peerChoice -eq "0") { break peerMenu }

                    if ($peerChoice -match '^[Rr](\d+)$') {
                        $rIdx = [int]$Matches[1] - 1
                        if ($rIdx -ge 0 -and $rIdx -lt $currentDestinations.Count) {
                            $removed = $currentDestinations[$rIdx]
                            $label = if ($removed.Location) { $removed.Location } else { $removed.Hostname }
                            $currentDestinations = @($currentDestinations | Where-Object { $_.TailscaleIP -ne $removed.TailscaleIP })
                            Write-Host "[OK] Removed: $label" -ForegroundColor Green
                            Start-Sleep -Milliseconds 600
                        }
                        else { Write-Host "Invalid number." -ForegroundColor Red; Start-Sleep -Milliseconds 600 }
                    }
                    elseif ($peerChoice -match '^[Aa](\d+)$') {
                        $aIdx = [int]$Matches[1] - 1
                        if ($aIdx -ge 0 -and $aIdx -lt $addable.Count) {
                            $toAdd = $addable[$aIdx]
                            $currentDestinations += [PSCustomObject]@{
                                Hostname    = $toAdd.Hostname
                                TailscaleIP = $toAdd.TailscaleIP
                                Location    = $toAdd.Location
                                CustomerCode = $toAdd.CustomerCode
                                BasePath    = $toAdd.StoragePath
                            }
                            $label = if ($toAdd.Location) { $toAdd.Location } else { $toAdd.Hostname }
                            Write-Host "[OK] Added: $label" -ForegroundColor Green
                            Start-Sleep -Milliseconds 600
                        }
                        else { Write-Host "Invalid number." -ForegroundColor Red; Start-Sleep -Milliseconds 600 }
                    }
                    else { Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Milliseconds 600 }
                }

                $jobs[$index].PeerDestinations = $currentDestinations
                Write-Host "`nDestination peers updated!" -ForegroundColor Green
            }
        }
        "0" {
            return
        }
        default {
            Write-Host "`nInvalid choice!" -ForegroundColor Red
        }
    }

    if ($choice -in @("1", "2", "3", "4", "5")) {
        if (Save-Jobs -Jobs $jobs) {
            Write-Log "Updated job: $($job.JobName)" -Level SUCCESS
            
            # Publish updated status
            if (Get-Command 'Publish-NodeStatus' -ErrorAction SilentlyContinue) {
                Publish-NodeStatus | Out-Null
            }
        }
    }

    Read-Host "`nPress Enter to continue"
}

function Remove-BackupJob {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     DELETE BACKUP JOB" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    $jobs = @(Get-Jobs)

    if ($jobs.Count -eq 0) {
        Write-Host "No backup jobs configured." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    # Display jobs with details
    Write-Host "Available Jobs:" -ForegroundColor Yellow
    Write-Host ""
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $j = $jobs[$i]
        $status = if ($j.Enabled -eq $false) { "[DISABLED]" } else { "" }
        Write-Host "  [$($i + 1)] $($j.JobName) $status" -ForegroundColor $(if($j.Enabled -eq $false){"Gray"}else{"White"})
        Write-Host "      Type: $($j.BackupType) | Source: $(Split-Path $j.BackupObject -Leaf)" -ForegroundColor Gray
    }

    Write-Host ""
    $selection = Read-Host "Select job number to delete (or 0 to cancel)"
    $index = [int]$selection - 1

    if ($selection -eq "0" -or $index -lt 0 -or $index -ge $jobs.Count) {
        return
    }

    $job = $jobs[$index]

    # Show what will be deleted
    Write-Host ""
    Write-Host "Job to delete:" -ForegroundColor Red
    Write-Host "  Name:   $($job.JobName)" -ForegroundColor White
    Write-Host "  Type:   $($job.BackupType)" -ForegroundColor White
    Write-Host "  Source: $($job.BackupObject)" -ForegroundColor White
    if ($job.PeerDestinations) {
        Write-Host "  Peers:  $($job.PeerDestinations.Count) destination(s)" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "WARNING: This will remove the job configuration and scheduled task." -ForegroundColor Yellow
    Write-Host "         Backup copies on peers will NOT be deleted." -ForegroundColor Yellow
    Write-Host ""

    $confirm = Read-Host "Type 'DELETE' to confirm"
    if ($confirm -eq "DELETE") {
        # Determine task name
        $taskName = if ($job.TaskName) { $job.TaskName } else { "VLABS_Backup_$($job.JobName)" }
        
        # Remove scheduled task
        try {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($task) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
                Write-Host "Removed scheduled task: $taskName" -ForegroundColor Green
                Write-Log "Removed scheduled task: $taskName" -Level SUCCESS
            }
            else {
                Write-Host "Scheduled task not found (may have been removed manually)" -ForegroundColor Gray
            }
        }
        catch {
            Write-Host "Warning: Could not remove scheduled task: $_" -ForegroundColor Yellow
        }

        # Remove from jobs list
        $jobs = @($jobs | Where-Object { $_.JobName -ne $job.JobName })

        if (Save-Jobs -Jobs $jobs) {
            Write-Host ""
            Write-Host "Job '$($job.JobName)' deleted successfully!" -ForegroundColor Green
            Write-Log "Deleted backup job: $($job.JobName)" -Level SUCCESS
            
            # Publish updated status
            if (Get-Command 'Publish-NodeStatus' -ErrorAction SilentlyContinue) {
                Publish-NodeStatus | Out-Null
            }
        }
    }
    else {
        Write-Host "`nDeletion cancelled." -ForegroundColor Yellow
    }

    Read-Host "`nPress Enter to continue"
}

function Show-BackupStatus {
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     BACKUP STATUS & HISTORY" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    # Use Get-JobsWithStatus to merge master data with transaction data for display
    $jobs = @(Get-JobsWithStatus)
    $ringConfig = if (Get-Command 'Get-RingConfig' -ErrorAction SilentlyContinue) { Get-RingConfig } else { $null }
    $inventoryGroups = @()
    $inventorySummary = $null
    if ($ringConfig -and $ringConfig.StoragePath -and (Get-Command 'Get-NodeStorageInventory' -ErrorAction SilentlyContinue)) {
        $inventorySummary = Get-NodeStorageInventory -StoragePath $ringConfig.StoragePath
        if (Get-Command 'Get-NodeStorageInventoryGroups' -ErrorAction SilentlyContinue) {
            $inventoryGroups = @(Get-NodeStorageInventoryGroups -StoragePath $ringConfig.StoragePath)
        }
    }

    if ($jobs.Count -eq 0) {
        Write-Host "No backup jobs configured." -ForegroundColor Yellow
        if ($inventorySummary -and $inventorySummary.TotalBackupSets -gt 0) {
            Write-Host ""
            Write-Host "Stored backups on this peer:" -ForegroundColor Cyan
            Write-Host "  Backup sets: $($inventorySummary.TotalBackupSets)" -ForegroundColor White
            Write-Host "  Files:       $($inventorySummary.TotalFiles)" -ForegroundColor White
            Write-Host "  Storage:     $(Format-RRSize -Bytes $inventorySummary.TotalBytes)" -ForegroundColor White
        }
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
        if ($job.SourceLocation) {
            Write-Host "Source Location: $($job.SourceLocation)" -ForegroundColor Gray
        }
        
        if ($job.PeerDestinations -and $job.PeerDestinations.Count -gt 0) {
            Write-Host "Configured Peers:" -ForegroundColor Cyan
            foreach ($peer in @($job.PeerDestinations)) {
                $peerLabel = if ($peer.Hostname) { $peer.Hostname } else { $peer.TailscaleIP }
                $peerBits = @($peerLabel)
                if ($peer.Location) { $peerBits += "@ $($peer.Location)" }
                if ($peer.TailscaleIP) { $peerBits += $peer.TailscaleIP }
                Write-Host "  - $($peerBits -join ' | ')" -ForegroundColor White
            }
        }
        elseif ($job.DestinationPath) {
            Write-Host "Destination: $($job.DestinationPath)" -ForegroundColor Gray
        }
    }
    
    Write-Host "`n`nStored Backups On This Peer:" -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Gray
    
    if (-not $ringConfig -or -not $ringConfig.StoragePath) {
        Write-Host "This machine is not configured as a storage peer." -ForegroundColor Yellow
    }
    elseif (-not (Test-Path $ringConfig.StoragePath)) {
        Write-Host "Storage path not found: $($ringConfig.StoragePath)" -ForegroundColor Yellow
    }
    elseif (-not $inventorySummary -or $inventorySummary.TotalBackupSets -eq 0) {
        Write-Host "No backup sets currently stored on this peer." -ForegroundColor Yellow
    }
    else {
        Write-Host "Storage Path: $($ringConfig.StoragePath)" -ForegroundColor Gray
        Write-Host "Backup Sets:  $($inventorySummary.TotalBackupSets)" -ForegroundColor White
        Write-Host "Files:        $($inventorySummary.TotalFiles)" -ForegroundColor White
        Write-Host "Storage Used: $(Format-RRSize -Bytes $inventorySummary.TotalBytes)" -ForegroundColor White
        Write-Host ""
        
        foreach ($group in @($inventoryGroups)) {
            Write-Host "$($group.Application) [$($group.BackupType)]" -ForegroundColor White
            Write-Host "  Source:       $($group.SourceLocation)" -ForegroundColor Gray
            Write-Host "  Backup Sets:  $($group.BackupSetCount)" -ForegroundColor Gray
            Write-Host "  Stored Size:  $($group.TotalSizeDisplay)" -ForegroundColor Gray
            if ($group.TotalFiles -ne $null) {
                Write-Host "  Files:        $($group.TotalFiles)" -ForegroundColor Gray
            }
            if ($group.LatestWriteTime) {
                Write-Host "  Latest:       $($group.LatestBackupFolder) @ $($group.LatestWriteTime)" -ForegroundColor Gray
            }
            elseif ($group.LatestBackupFolder) {
                Write-Host "  Latest:       $($group.LatestBackupFolder)" -ForegroundColor Gray
            }
            Write-Host ""
        }
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

#region Re-authentication Functions

function Invoke-ReauthenticateAllDestinations {
    <#
    .SYNOPSIS
        Re-authenticates all destinations, migrating credentials to AES format
    #>
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     RE-AUTHENTICATE ALL DESTINATIONS" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan
    
    $destinations = @(Get-Destinations)
    
    if ($destinations.Count -eq 0) {
        Write-Host "No destinations configured." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }
    
    Write-Host "This will re-encrypt all destination passwords using machine-independent" -ForegroundColor Yellow
    Write-Host "encryption, ensuring scheduled tasks work regardless of which user runs them." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "You will need to enter the password for each destination." -ForegroundColor White
    Write-Host ""
    
    $confirm = Read-Host "Continue? (yes/no)"
    if ($confirm -ne "yes") {
        return
    }
    
    Write-Host ""
    
    foreach ($dest in $destinations) {
        Write-Host "----------------------------------------" -ForegroundColor Gray
        Write-Host "Destination: $($dest.ShortName)" -ForegroundColor Cyan
        Write-Host "Path: $($dest.Path)" -ForegroundColor Gray
        Write-Host "User: $($dest.Domain)\$($dest.Username)" -ForegroundColor Gray
        Write-Host ""
        
        # Check if already using AES
        if ($dest.EncryptedPassword -and $dest.EncryptedPassword.StartsWith("AES:")) {
            Write-Host "Already using machine-independent encryption." -ForegroundColor Green
            $reenter = Read-Host "Re-enter password anyway? (yes/no)"
            if ($reenter -ne "yes") {
                continue
            }
        }
        
        $password = Read-Host "Enter password for $($dest.ShortName)" -AsSecureString
        $plainPassword = Get-PlainTextPassword -SecurePassword $password
        
        if ([string]::IsNullOrWhiteSpace($plainPassword)) {
            Write-Host "Skipped (empty password)" -ForegroundColor Yellow
            continue
        }
        
        # Encrypt with AES
        $encrypted = ConvertTo-EncryptedPassword -PlainTextPassword $plainPassword
        if ($encrypted) {
            # Update destination
            $dest.EncryptedPassword = $encrypted
            Write-Host "Password re-encrypted successfully!" -ForegroundColor Green
        }
        else {
            Write-Host "Failed to encrypt password!" -ForegroundColor Red
        }
        
        Write-Host ""
    }
    
    # Save destinations
    if (Save-Destinations -Destinations $destinations) {
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "All destinations updated successfully!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Log "Re-authenticated all destinations with machine-independent encryption" -Level SUCCESS
        
        # Also update jobs with new credentials
        Write-Host ""
        Write-Host "Updating backup jobs with new credentials..." -ForegroundColor Cyan
        
        $jobs = @(Get-Jobs)
        $updatedCount = 0
        
        foreach ($job in $jobs) {
            $dest = $destinations | Where-Object { $_.ShortName -eq $job.Destination }
            if ($dest) {
                $job.DestinationEncryptedPassword = $dest.EncryptedPassword
                $updatedCount++
            }
        }
        
        if (Save-Jobs -Jobs $jobs) {
            Write-Host "$updatedCount job(s) updated with new credentials." -ForegroundColor Green
        }
    }
    else {
        Write-Host "Failed to save destinations!" -ForegroundColor Red
    }
    
    Read-Host "`nPress Enter to continue"
}

function Test-DestinationCredentials {
    <#
    .SYNOPSIS
        Tests if destination credentials can be decrypted
    #>
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     TEST CREDENTIAL DECRYPTION" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan
    
    $destinations = @(Get-Destinations)
    
    if ($destinations.Count -eq 0) {
        Write-Host "No destinations configured." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }
    
    $needsReauth = $false
    
    foreach ($dest in $destinations) {
        Write-Host "$($dest.ShortName): " -NoNewline -ForegroundColor White
        
        if (-not $dest.EncryptedPassword) {
            Write-Host "NO PASSWORD STORED" -ForegroundColor Red
            $needsReauth = $true
            continue
        }
        
        # Check encryption type
        if ($dest.EncryptedPassword.StartsWith("AES:")) {
            # AES encrypted
            if (Get-Command 'Unprotect-Password' -ErrorAction SilentlyContinue) {
                $result = Unprotect-Password -EncryptedPassword $dest.EncryptedPassword
                if ($result) {
                    Write-Host "OK (AES - Machine Independent)" -ForegroundColor Green
                }
                else {
                    Write-Host "FAILED (AES decryption error)" -ForegroundColor Red
                    $needsReauth = $true
                }
            }
            else {
                Write-Host "UNKNOWN (CryptoUtils not loaded)" -ForegroundColor Yellow
            }
        }
        else {
            # DPAPI encrypted (legacy)
            try {
                $securePassword = ConvertTo-SecureString -String $dest.EncryptedPassword -ErrorAction Stop
                Write-Host "OK (DPAPI - User Specific) - Consider re-auth for portability" -ForegroundColor Yellow
            }
            catch {
                Write-Host "FAILED (DPAPI - Wrong user context)" -ForegroundColor Red
                $needsReauth = $true
            }
        }
    }
    
    Write-Host ""
    
    if ($needsReauth) {
        Write-Host "Some credentials need re-authentication!" -ForegroundColor Red
        Write-Host "Use the 'Re-authenticate All Destinations' option from the menu." -ForegroundColor Yellow
    }
    else {
        Write-Host "All credentials are accessible." -ForegroundColor Green
    }
    
    Read-Host "`nPress Enter to continue"
}

#endregion

#region Uninstall

function Invoke-Uninstall {
    <#
    .SYNOPSIS
        Removes all Resilience Ring configuration from this machine.
        Tailscale is intentionally NOT removed.
    #>
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Red
    Write-Host "       UNINSTALL RESILIENCE RING" -ForegroundColor Red
    Write-Host "===============================================`n" -ForegroundColor Red

    Write-Host "This will permanently remove:" -ForegroundColor Yellow
    Write-Host "  - All backup job scheduled tasks" -ForegroundColor White
    Write-Host "  - SMB share (RR_Backups)" -ForegroundColor White
    Write-Host "  - Service account (RR_Service)" -ForegroundColor White
    Write-Host "  - All configuration (jobs, destinations, ring config)" -ForegroundColor White
    Write-Host "  - Start Menu shortcut" -ForegroundColor White
    Write-Host "  - Application files (C:\VLABS_ResilienceRing\)" -ForegroundColor White
    Write-Host ""
    Write-Host "The following will NOT be removed:" -ForegroundColor Green
    Write-Host "  - Tailscale (stays installed and connected)" -ForegroundColor White
    Write-Host "  - Your actual backup data files" -ForegroundColor White
    Write-Host ""
    Write-Host "WARNING: This action cannot be undone!" -ForegroundColor Red
    Write-Host ""

    $confirm = Read-Host "Type UNINSTALL to confirm, or press Enter to cancel"
    if ($confirm -ne "UNINSTALL") {
        Write-Host "`nUninstall cancelled." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    Write-Host ""
    Write-Host "Starting uninstall..." -ForegroundColor Cyan
    Write-Host ""

    # Step 1: Remove scheduled tasks
    Write-Host "[ 1/6 ] Removing scheduled tasks..." -ForegroundColor Yellow
    $jobs = @(Get-Jobs)
    $taskCount = 0
    foreach ($job in $jobs) {
        if ($job.TaskName) {
            $task = Get-ScheduledTask -TaskName $job.TaskName -ErrorAction SilentlyContinue
            if ($task) {
                Unregister-ScheduledTask -TaskName $job.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                Write-Host "       Removed task: $($job.TaskName)" -ForegroundColor Gray
                $taskCount++
            }
        }
    }
    if ($taskCount -eq 0) {
        Write-Host "       No scheduled tasks found." -ForegroundColor Gray
    } else {
        Write-Host "       Removed $taskCount task(s)." -ForegroundColor Green
    }

    # Step 2: Remove SMB share
    Write-Host "[ 2/6 ] Removing SMB share (RR_Backups)..." -ForegroundColor Yellow
    $share = Get-SmbShare -Name "RR_Backups" -ErrorAction SilentlyContinue
    if ($share) {
        Remove-SmbShare -Name "RR_Backups" -Force -ErrorAction SilentlyContinue
        Write-Host "       Share removed." -ForegroundColor Green
    } else {
        Write-Host "       Share not found (already removed)." -ForegroundColor Gray
    }

    # Step 3: Remove service account
    Write-Host "[ 3/6 ] Removing service account (RR_Service)..." -ForegroundColor Yellow
    $user = Get-LocalUser -Name "RR_Service" -ErrorAction SilentlyContinue
    if ($user) {
        Remove-LocalUser -Name "RR_Service" -ErrorAction SilentlyContinue
        Write-Host "       Account removed." -ForegroundColor Green
    } else {
        Write-Host "       Account not found (already removed)." -ForegroundColor Gray
    }

    # Step 4: Remove configuration files
    Write-Host "[ 4/6 ] Removing configuration files..." -ForegroundColor Yellow
    $configDir = "C:\ProgramData\VLABS_ResilienceRing"
    $configFiles = @(
        "ring-config.json", "jobs.json", "jobs-status.json",
        "destinations.json", "storage-peers.json", "peer-info.json", "debug.log"
    )
    foreach ($file in $configFiles) {
        $path = Join-Path $configDir $file
        if (Test-Path $path) {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
            Write-Host "       Removed: $file" -ForegroundColor Gray
        }
    }

    # Ask about logs
    $logsDir = Join-Path $configDir "Logs"
    if (Test-Path $logsDir) {
        Write-Host ""
        $keepLogs = Read-Host "       Keep log files? (yes/no)"
        if ($keepLogs -ne "yes") {
            Remove-Item $logsDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "       Logs removed." -ForegroundColor Gray
        } else {
            Write-Host "       Logs kept at: $logsDir" -ForegroundColor Gray
        }
    }

    # Remove config dir if now empty
    if ((Test-Path $configDir)) {
        $remaining = Get-ChildItem $configDir -Recurse -ErrorAction SilentlyContinue
        if (-not $remaining) {
            Remove-Item $configDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "       Configuration files removed." -ForegroundColor Green

    # Step 5: Remove Start Menu shortcut
    Write-Host "[ 5/6 ] Removing Start Menu shortcut..." -ForegroundColor Yellow
    $shortcut = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Resilience Ring.lnk"
    if (Test-Path $shortcut) {
        Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
        Write-Host "       Shortcut removed." -ForegroundColor Green
    } else {
        Write-Host "       Shortcut not found." -ForegroundColor Gray
    }

    # Step 6: Schedule removal of application directory
    # (cannot delete while running from it — schedule for a few seconds after exit)
    Write-Host "[ 6/6 ] Scheduling removal of application directory..." -ForegroundColor Yellow
    $appDir = "C:\VLABS_ResilienceRing"
    if (Test-Path $appDir) {
        Start-Process "cmd" -ArgumentList "/c timeout /t 4 /nobreak >nul && rmdir /s /q `"$appDir`"" -WindowStyle Hidden
        Write-Host "       Scheduled for removal: $appDir" -ForegroundColor Green
    } else {
        Write-Host "       App directory not found." -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "===============================================" -ForegroundColor Green
    Write-Host "   Resilience Ring has been uninstalled." -ForegroundColor Green
    Write-Host "   Tailscale remains installed and active." -ForegroundColor Green
    Write-Host "===============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "This window will close in 5 seconds..." -ForegroundColor Gray
    Write-Log "Resilience Ring uninstalled by user" -Level INFO
    Start-Sleep -Seconds 5
    exit 0
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
    Write-Host ""
    Write-Host " U. Uninstall Resilience Ring" -ForegroundColor DarkRed

    Write-Host "`n===============================================" -ForegroundColor Cyan
}

function Start-MainLoop {
    while ($true) {
        Show-MainMenu
        $choice = Read-Host "`nEnter your choice"

        switch ($choice.ToUpper()) {
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
            "U" { Invoke-Uninstall }
            default {
                Write-Host "`nInvalid choice! Please try again." -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
    }
}

#endregion

#region Main Entry Point

# Only run the main loop if this script is executed directly (not dot-sourced/imported)
# Check if we're being dot-sourced by looking at the invocation
$scriptName = $MyInvocation.MyCommand.Name
$isDirectExecution = ($scriptName -eq 'VLABS-SecureBackup.ps1') -or ($scriptName -eq $null -and $MyInvocation.Line -notmatch '^\s*\.')

if ($isDirectExecution -and -not $env:RESILIENCE_RING_IMPORT) {
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
}

#endregion
