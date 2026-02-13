<#
.SYNOPSIS
    VLABS Resilience Ring - Backup Execution Script
.DESCRIPTION
    Executes backup jobs with retention policy support.
    Handles both legacy jobs (single destination) and new jobs (multiple peers + retention).
.PARAMETER JobName
    Name of the backup job to execute
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$JobName
)

# Configuration - Data in ProgramData (separate from git install directory)
$script:ConfigPath = "C:\ProgramData\VLABS_ResilienceRing"
$script:JobsFile = Join-Path $ConfigPath "jobs.json"           # Master data (config)
$script:JobsStatusFile = Join-Path $ConfigPath "jobs-status.json"  # Transaction data (run history)
$script:LogPath = Join-Path $ConfigPath "Logs"

# Load helper modules
$cryptoUtilsPath = Join-Path $PSScriptRoot "CryptoUtils.ps1"
if (Test-Path $cryptoUtilsPath) { . $cryptoUtilsPath }

$peerMgmtPath = Join-Path $PSScriptRoot "PeerManagement.ps1"
if (Test-Path $peerMgmtPath) { . $peerMgmtPath }

# VLABS Monitor Configuration
$script:VlabsMonitorUrl = $env:VLABS_MONITOR_URL
$script:VlabsMonitorEnabled = $false

#region Logging

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARNING','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logFile = Join-Path $LogPath "VLABS_Backup_$(Get-Date -Format 'yyyyMMdd').log"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
    
    switch ($Level) {
        'ERROR' { Write-Host $logEntry -ForegroundColor Red }
        'WARNING' { Write-Host $logEntry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $logEntry -ForegroundColor Green }
        default { Write-Host $logEntry -ForegroundColor Gray }
    }
}

#endregion

#region Configuration - Master/Transaction Data Separation
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
        $content = Get-Content $JobsFile -Raw | ConvertFrom-Json
        
        # Handle corrupted format where jobs are wrapped in {"value": [...]}
        if ($content -is [PSCustomObject] -and $content.PSObject.Properties.Name -contains 'value') {
            $content = $content.value
        }
        
        # Ensure we return an array
        if ($null -eq $content) { return @() }
        if ($content -isnot [Array]) { return @($content) }
        return $content
    }
    catch { return @() }
}

function Save-Jobs {
    <#
    .SYNOPSIS
        Save jobs to master data file (jobs.json)
    .DESCRIPTION
        Saves only master data. Strips any transaction properties before saving.
    #>
    param($Jobs)
    try {
        # Strip transaction data properties before saving master data
        $masterDataProperties = @('JobName', 'BackupType', 'BackupObject', 'TargetPeers', 
                                   'Schedule', 'StartHour', 'Retention', 'RetentionMonthly', 
                                   'RetentionWeekly', 'RetentionRecent', 'TaskName', 'Enabled')
        
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
        
        # Use -InputObject to prevent array wrapping
        $json = ConvertTo-Json -InputObject $cleanJobs -Depth 10
        Set-Content -Path $JobsFile -Value $json -Force
        return $true
    }
    catch { return $false }
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
        $content = Get-Content $JobsStatusFile -Raw | ConvertFrom-Json
        
        # Handle corrupted format
        if ($content -is [PSCustomObject] -and $content.PSObject.Properties.Name -contains 'value') {
            $content = $content.value
        }
        
        # Convert to hashtable for fast lookup
        $statusTable = @{}
        if ($content) {
            foreach ($status in @($content)) {
                if ($status.JobName) {
                    $statusTable[$status.JobName] = $status
                }
            }
        }
        return $statusTable
    }
    catch { return @{} }
}

function Save-JobsStatus {
    <#
    .SYNOPSIS
        Save job status to transaction data file (jobs-status.json)
    #>
    param([hashtable]$StatusTable)
    try {
        $statusArray = @($StatusTable.Values)
        $json = ConvertTo-Json -InputObject $statusArray -Depth 10
        Set-Content -Path $JobsStatusFile -Value $json -Force
        return $true
    }
    catch { return $false }
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

# Note: Publish-NodeStatus is defined in PeerManagement.ps1 (loaded above)

#endregion

#region Retention Logic

function Get-TodayRetentionType {
    <#
    .SYNOPSIS
        Determines what type of retention backup to create today
    #>
    $today = Get-Date
    $types = @()
    
    # Check if last day of month
    $lastDayOfMonth = (New-Object DateTime($today.Year, $today.Month, 1)).AddMonths(1).AddDays(-1)
    if ($today.Date -eq $lastDayOfMonth.Date) {
        $types += 'monthly'
    }
    
    # Check if Saturday
    if ($today.DayOfWeek -eq [DayOfWeek]::Saturday) {
        $types += 'weekly'
    }
    
    # Recent is always included
    $types += 'recent'
    
    return $types
}

function Get-RetentionFolderName {
    param(
        [string]$AppName,
        [string]$RetentionType,
        [datetime]$Date = (Get-Date)
    )
    
    switch ($RetentionType) {
        'monthly' { return "$AppName-$($Date.ToString('yyyy-MM'))-monthly" }
        'weekly' { return "$AppName-$($Date.ToString('yyyy-MM-dd'))-weekly" }
        'recent' { return "$AppName-$($Date.ToString('yyyy-MM-dd-HHmm'))" }
        default { return "$AppName-$($Date.ToString('yyyy-MM-dd-HHmm'))" }
    }
}

function Invoke-RetentionCleanup {
    <#
    .SYNOPSIS
        Cleans up old backups based on retention policy
    #>
    param(
        [string]$BasePath,
        [string]$AppName,
        [int]$MonthlyRetention,
        [int]$WeeklyRetention,
        [int]$RecentRetention
    )
    
    Write-Log "Applying retention policy: $MonthlyRetention monthly, $WeeklyRetention weekly, $RecentRetention recent" -Level INFO
    
    if (-not (Test-Path $BasePath)) { return }
    
    $allFolders = Get-ChildItem -Path $BasePath -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "$AppName-*" } |
                  Sort-Object Name -Descending
    
    # Separate by type
    $monthlyFolders = $allFolders | Where-Object { $_.Name -match '-monthly$' }
    $weeklyFolders = $allFolders | Where-Object { $_.Name -match '-weekly$' }
    $recentFolders = $allFolders | Where-Object { $_.Name -notmatch '-(monthly|weekly)$' }
    
    # Delete excess monthly
    if ($monthlyFolders.Count -gt $MonthlyRetention) {
        $toDelete = $monthlyFolders | Select-Object -Skip $MonthlyRetention
        foreach ($folder in $toDelete) {
            Write-Log "Deleting old monthly backup: $($folder.Name)" -Level INFO
            Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Delete excess weekly
    if ($weeklyFolders.Count -gt $WeeklyRetention) {
        $toDelete = $weeklyFolders | Select-Object -Skip $WeeklyRetention
        foreach ($folder in $toDelete) {
            Write-Log "Deleting old weekly backup: $($folder.Name)" -Level INFO
            Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Delete excess recent
    if ($recentFolders.Count -gt $RecentRetention) {
        $toDelete = $recentFolders | Select-Object -Skip $RecentRetention
        foreach ($folder in $toDelete) {
            Write-Log "Deleting old recent backup: $($folder.Name)" -Level INFO
            Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    Write-Log "Retention cleanup completed" -Level SUCCESS
}

#endregion

#region Checksum Verification

function Get-FileChecksum {
    param([string]$FilePath)
    
    if (-not (Test-Path $FilePath -PathType Leaf)) { return $null }
    
    try {
        $hash = Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction Stop
        return $hash.Hash
    }
    catch { return $null }
}

function Test-BackupIntegrity {
    param(
        [string]$SourcePath,
        [string]$DestPath,
        [string]$Type
    )
    
    Write-Log "Verifying backup integrity..." -Level INFO
    
    if ($Type -eq 'F') {
        # Single file
        $srcHash = Get-FileChecksum -FilePath $SourcePath
        $dstHash = Get-FileChecksum -FilePath $DestPath
        
        if ($srcHash -and $dstHash -and ($srcHash -eq $dstHash)) {
            Write-Log "Checksum verified: $srcHash" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "Checksum MISMATCH!" -Level ERROR
            return $false
        }
    }
    else {
        # Directory - sample verification
        $srcFiles = Get-ChildItem -Path $SourcePath -File -Recurse -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 10
        
        $mismatches = 0
        foreach ($file in $srcFiles) {
            $relativePath = $file.FullName.Substring($SourcePath.Length).TrimStart('\')
            $destFile = Join-Path $DestPath $relativePath
            
            if (Test-Path $destFile) {
                $srcHash = Get-FileChecksum -FilePath $file.FullName
                $dstHash = Get-FileChecksum -FilePath $destFile
                if ($srcHash -ne $dstHash) { $mismatches++ }
            }
            else {
                $mismatches++
            }
        }
        
        if ($mismatches -eq 0) {
            Write-Log "Directory integrity verified ($($srcFiles.Count) files sampled)" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "Integrity check failed: $mismatches mismatches" -Level ERROR
            return $false
        }
    }
}

#endregion

#region SMB Connection

function Connect-ToPeer {
    param(
        [string]$TailscaleIP,
        [string]$CustomerCode
    )
    
    $sharePath = "\\$TailscaleIP\RR_Backups"
    
    # Check if already connected (use -SimpleMatch to avoid regex issues with backslashes)
    $existing = net use 2>$null | Select-String -SimpleMatch $sharePath
    if ($existing) { return $true }
    
    # Get service account password
    $password = Get-RingServicePassword -CustomerCode $CustomerCode
    
    $result = net use $sharePath /user:RR_Service $password 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Disconnect-FromPeer {
    param([string]$TailscaleIP)
    
    $sharePath = "\\$TailscaleIP\RR_Backups"
    net use $sharePath /delete 2>$null | Out-Null
}

#endregion

#region Backup Execution

function Invoke-BackupToPeer {
    <#
    .SYNOPSIS
        Executes backup to a single peer with retention management
    #>
    param(
        [Parameter(Mandatory=$true)]
        $Peer,  # Can be hashtable or PSObject (from JSON)
        $Job,
        [string]$RetentionType
    )
    
    $peerIP = $Peer.TailscaleIP
    $basePath = $Peer.BasePath
    $appName = $Job.AppNameClean
    
    Write-Log "Backing up to peer: $($Peer.Hostname) ($peerIP) - Type: $RetentionType" -Level INFO
    
    # Connect to peer
    if (-not (Connect-ToPeer -TailscaleIP $peerIP -CustomerCode $Job.CustomerCode)) {
        Write-Log "Failed to connect to peer: $peerIP" -Level ERROR
        return $false
    }
    
    # Create base path if needed
    if (-not (Test-Path $basePath)) {
        try {
            New-Item -Path $basePath -ItemType Directory -Force | Out-Null
            Write-Log "Created base path: $basePath" -Level INFO
        }
        catch {
            Write-Log "Failed to create base path: $_" -Level ERROR
            Disconnect-FromPeer -TailscaleIP $peerIP
            return $false
        }
    }
    
    # Generate folder name based on retention type
    $folderName = Get-RetentionFolderName -AppName $appName -RetentionType $RetentionType
    $destPath = Join-Path $basePath $folderName
    
    # Create destination folder
    if (-not (Test-Path $destPath)) {
        New-Item -Path $destPath -ItemType Directory -Force | Out-Null
    }
    
    # Execute robocopy
    $robocopyLog = Join-Path $LogPath "robocopy_$($Job.JobName)_$($Peer.Hostname)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    
    $robocopyArgs = @()
    
    if ($Job.BackupType -eq 'F') {
        # Single file
        $sourceFile = Get-Item $Job.BackupObject
        $robocopyArgs = @(
            "`"$($sourceFile.DirectoryName)`"",
            "`"$destPath`"",
            "`"$($sourceFile.Name)`"",
            "/R:3", "/W:5",
            "/LOG:`"$robocopyLog`""
        )
    }
    else {
        # Directory (D or SQL)
        $robocopyArgs = @(
            "`"$($Job.BackupObject)`"",
            "`"$destPath`"",
            "/MIR",
            "/DCOPY:DAT", "/COPY:DAT",
            "/R:3", "/W:5", "/MT:8",
            "/LOG:`"$robocopyLog`""
        )
    }
    
    Write-Log "Running robocopy: $($Job.BackupObject) -> $destPath" -Level INFO
    
    $robocopyCmd = "robocopy $($robocopyArgs -join ' ')"
    try {
        Invoke-Expression $robocopyCmd | Out-Null
        $exitCode = $LASTEXITCODE
        Write-Log "Robocopy completed with exit code: $exitCode" -Level INFO
    }
    catch {
        Write-Log "Robocopy exception: $_" -Level ERROR
        return $false
    }
    
    $success = ($exitCode -le 7)
    
    if ($success) {
        # Verify integrity
        if ($Job.BackupType -eq 'F') {
            $sourceFile = Get-Item $Job.BackupObject
            $destFile = Join-Path $destPath $sourceFile.Name
            $verified = Test-BackupIntegrity -SourcePath $Job.BackupObject -DestPath $destFile -Type 'F'
        }
        else {
            $verified = Test-BackupIntegrity -SourcePath $Job.BackupObject -DestPath $destPath -Type $Job.BackupType
        }
        
        if (-not $verified) {
            Write-Log "Backup to $($Peer.Hostname) completed but verification failed!" -Level WARNING
        }
        else {
            Write-Log "Backup to $($Peer.Hostname) completed and verified" -Level SUCCESS
        }
        
        # Apply retention cleanup
        Invoke-RetentionCleanup -BasePath $basePath -AppName $appName `
            -MonthlyRetention $Job.RetentionMonthly `
            -WeeklyRetention $Job.RetentionWeekly `
            -RecentRetention $Job.RetentionRecent
    }
    else {
        Write-Log "Robocopy failed with exit code: $LASTEXITCODE" -Level ERROR
    }
    
    Disconnect-FromPeer -TailscaleIP $peerIP
    
    return $success
}

function Invoke-UnifiedBackup {
    <#
    .SYNOPSIS
        Executes backup job with new retention system (multiple peers)
    #>
    param($Job)
    
    Write-Log "Starting unified backup: $($Job.JobName) ($($Job.AppName))" -Level INFO
    
    # Determine retention types for today
    $retentionTypes = Get-TodayRetentionType
    Write-Log "Today's retention types: $($retentionTypes -join ', ')" -Level INFO
    
    # Verify source exists
    $sourceExists = if ($Job.BackupType -eq 'F') {
        Test-Path $Job.BackupObject -PathType Leaf
    } else {
        Test-Path $Job.BackupObject -PathType Container
    }
    
    if (-not $sourceExists) {
        Write-Log "Source not found: $($Job.BackupObject)" -Level ERROR
        return $false
    }
    
    # Track results
    $totalPeers = $Job.PeerDestinations.Count
    $successPeers = 0
    
    # Backup to each peer
    foreach ($peer in $Job.PeerDestinations) {
        # For each retention type that applies today
        foreach ($retentionType in $retentionTypes) {
            # Skip monthly/weekly if retention count is 0
            if ($retentionType -eq 'monthly' -and $Job.RetentionMonthly -eq 0) { continue }
            if ($retentionType -eq 'weekly' -and $Job.RetentionWeekly -eq 0) { continue }
            
            $result = Invoke-BackupToPeer -Peer $peer -Job $Job -RetentionType $retentionType
            if ($result -and $retentionType -eq 'recent') {
                $successPeers++
            }
        }
    }
    
    Write-Log "Backup completed: $successPeers/$totalPeers peers successful" -Level $(if($successPeers -gt 0){'SUCCESS'}else{'ERROR'})
    
    return ($successPeers -gt 0)
}

#endregion

#region Legacy Backup Support

function Invoke-LegacyBackup {
    <#
    .SYNOPSIS
        Executes backup with legacy job format (single destination, simple retention)
    #>
    param($Job)
    
    Write-Log "Starting legacy backup: $($Job.JobName)" -Level INFO
    
    # Verify source
    $sourceExists = if ($Job.BackupType -eq 'F') {
        Test-Path $Job.BackupObject -PathType Leaf
    } else {
        Test-Path $Job.BackupObject -PathType Container
    }
    
    if (-not $sourceExists) {
        Write-Log "Source not found: $($Job.BackupObject)" -Level ERROR
        return $false
    }
    
    # Connect to destination using legacy credentials
    $pathInfo = $Job.DestinationPath -match '^\\\\([^\\]+)\\([^\\]+)'
    if (-not $pathInfo) {
        Write-Log "Invalid destination path: $($Job.DestinationPath)" -Level ERROR
        return $false
    }
    
    $server = $matches[1]
    $sharePath = "\\$server\$($matches[2])"
    
    # Try to connect
    $plainPassword = $null
    if (Get-Command 'Unprotect-Password' -ErrorAction SilentlyContinue) {
        $plainPassword = Unprotect-Password -EncryptedPassword $Job.DestinationEncryptedPassword
    }
    
    if ($plainPassword) {
        $user = if ($Job.DestinationDomain) { "$($Job.DestinationDomain)\$($Job.DestinationUsername)" } else { $Job.DestinationUsername }
        net use $sharePath /user:$user $plainPassword 2>$null | Out-Null
    }
    
    # Verify destination accessible
    if (-not (Test-Path $Job.DestinationPath)) {
        Write-Log "Destination not accessible: $($Job.DestinationPath)" -Level ERROR
        return $false
    }
    
    # Create job folder
    $destFolder = Join-Path $Job.DestinationPath $Job.JobName
    if (-not (Test-Path $destFolder)) {
        New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
    }
    
    # Execute robocopy
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $robocopyLog = Join-Path $LogPath "robocopy_$($Job.JobName)_$timestamp.log"
    
    if ($Job.BackupType -eq 'F') {
        $sourceFile = Get-Item $Job.BackupObject
        $destFile = Join-Path $destFolder "$($sourceFile.BaseName)_$timestamp$($sourceFile.Extension)"
        
        $robocopyArgs = @(
            "`"$($sourceFile.DirectoryName)`"",
            "`"$destFolder`"",
            "`"$($sourceFile.Name)`"",
            "/R:3", "/W:5",
            "/LOG:`"$robocopyLog`""
        )
    }
    else {
        $robocopyArgs = @(
            "`"$($Job.BackupObject)`"",
            "`"$destFolder`"",
            "/MIR",
            "/DCOPY:DAT", "/COPY:DAT",
            "/R:3", "/W:5", "/MT:8",
            "/LOG:`"$robocopyLog`""
        )
    }
    
    Write-Log "Running robocopy..." -Level INFO
    $robocopyCmd = "robocopy $($robocopyArgs -join ' ')"
    Invoke-Expression $robocopyCmd | Out-Null
    
    $success = ($LASTEXITCODE -le 7)
    
    if ($success) {
        Write-Log "Legacy backup completed successfully" -Level SUCCESS
        
        # Apply simple retention
        if ($Job.Retention) {
            $items = Get-ChildItem $destFolder | Sort-Object CreationTime -Descending
            if ($items.Count -gt $Job.Retention) {
                $items | Select-Object -Skip $Job.Retention | ForEach-Object {
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    else {
        Write-Log "Robocopy failed with exit code: $LASTEXITCODE" -Level ERROR
    }
    
    # Disconnect
    net use $sharePath /delete 2>$null | Out-Null
    
    return $success
}

#endregion

#region Main

function Invoke-BackupJob {
    param([string]$JobName)
    
    $startTime = Get-Date
    Write-Log "=== Backup Job Started: $JobName ===" -Level INFO
    
    $jobs = Get-Jobs
    $job = $jobs | Where-Object { $_.JobName -eq $JobName }
    
    if (-not $job) {
        Write-Log "Job not found: $JobName" -Level ERROR
        return $false
    }
    
    if ($job.Enabled -eq $false) {
        Write-Log "Job is disabled" -Level WARNING
        return $false
    }
    
    Update-JobStatus -JobName $JobName -Status "Running"
    
    # Determine job type and execute
    $success = $false
    $sizeBytes = 0
    
    if ($job.PeerDestinations -and $job.PeerDestinations.Count -gt 0) {
        # New unified backup with retention
        $success = Invoke-UnifiedBackup -Job $job
        
        # Calculate source size
        try {
            if ($job.BackupType -eq 'F') {
                $sizeBytes = (Get-Item $job.BackupObject -ErrorAction SilentlyContinue).Length
            }
            else {
                $sizeBytes = (Get-ChildItem $job.BackupObject -Recurse -File -ErrorAction SilentlyContinue | 
                              Measure-Object -Property Length -Sum).Sum
            }
        }
        catch { $sizeBytes = 0 }
    }
    elseif ($job.DestinationPath) {
        # Legacy single-destination backup
        $success = Invoke-LegacyBackup -Job $job
    }
    else {
        Write-Log "Job has no valid destination configuration" -Level ERROR
    }
    
    $endTime = Get-Date
    $durationSeconds = [int]($endTime - $startTime).TotalSeconds
    
    $finalStatus = if ($success) { "Success" } else { "Failed" }
    Update-JobStatus -JobName $JobName -Status $finalStatus -DurationSeconds $durationSeconds -SizeBytes $sizeBytes
    
    # Publish status to share for RRM
    Publish-NodeStatus
    
    Write-Log "=== Backup Job Completed: $JobName - $finalStatus (${durationSeconds}s) ===" -Level $(if($success){'SUCCESS'}else{'ERROR'})
    
    return $success
}

# Main entry point
try {
    if (-not (Test-Path $LogPath)) {
        New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
    }
    
    $result = Invoke-BackupJob -JobName $JobName
    exit $(if ($result) { 0 } else { 1 })
}
catch {
    Write-Log "Fatal error: $_" -Level ERROR
    exit 1
}
