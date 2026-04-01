#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Backup Job Management for VLABS Resilience Ring
    
.DESCRIPTION
    Unified backup job creation with:
    - Smart peer selection (auto-distributes to 2+ peers)
    - Retention policies (monthly, weekly, recent)
    - Automatic folder management
    - Ring policies enforcement
    
.NOTES
    Part of VLABS Resilience Ring
#>

#region Ring Policies

function Get-RingPolicies {
    <#
    .SYNOPSIS
        Reads ring policies from local _nodeinfo/ring-policies.json
    .DESCRIPTION
        Returns policies set by RRM, or defaults if not available.
        Policies are published by RRM and enforced after successful backups.
    #>
    
    # Default policies (used if no ring policies file exists)
    $defaults = @{
        RetentionMonthlyMin = 0
        RetentionMonthlyMax = 3
        RetentionWeeklyMin = 0
        RetentionWeeklyMax = 4
        RetentionRecentMin = 1
        RetentionRecentMax = 6
    }
    
    try {
        # Get local storage path from ring config
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
            # Merge with defaults (in case new fields added)
            $result = @{}
            foreach ($key in $defaults.Keys) {
                $result[$key] = if ($null -ne $policyData.Policies.$key) { 
                    $policyData.Policies.$key 
                } else { 
                    $defaults[$key] 
                }
            }
            return [PSCustomObject]$result
        }
    }
    catch {
        # Fall back to defaults on any error
    }
    
    return [PSCustomObject]$defaults
}

#endregion

#region Peer Selection

function Get-PeerStorageUsage {
    <#
    .SYNOPSIS
        Gets current storage usage for a peer
    #>
    param(
        [string]$TailscaleIP,
        [string]$CustomerCode
    )
    
    $sharePath = "\\$TailscaleIP\$(Get-RRShareName)"
    
    try {
        # Connect to peer
        $connected = Connect-RingShare -TailscaleIP $TailscaleIP -CustomerCode $CustomerCode
        if (-not $connected) { return $null }
        
        # Measure the whole shared storage root because the configured quota
        # applies to the backup folder, not just one customer subfolder.
        $storageRoot = $sharePath
        $usedBytes = 0
        
        if (Test-Path $storageRoot) {
            $usedBytes = (Get-ChildItem $storageRoot -Recurse -ErrorAction SilentlyContinue | 
                         Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        }
        
        Disconnect-RingShare -TailscaleIP $TailscaleIP
        
        return @{
            UsedBytes = if ($usedBytes) { $usedBytes } else { 0 }
            UsedGB = [math]::Round(($usedBytes / 1GB), 2)
        }
    }
    catch {
        Disconnect-RingShare -TailscaleIP $TailscaleIP
        return $null
    }
}

function Select-BackupPeers {
    <#
    .SYNOPSIS
        Automatically selects optimal peers for backup
        
    .DESCRIPTION
        Selection criteria:
        1. Must have at least 2 peers (3 copies total including source)
        2. Prefer peers with lowest storage usage
        3. Only use larger peers when smaller ones hit 70% capacity
    #>
    param(
        [int]$MinPeers = 2,
        [switch]$UseCachedListOnly
    )
    
    $config = Get-RingConfig
    if (-not $config -or -not $config.CustomerCode) {
        Write-Host "[ERROR] Ring not configured" -ForegroundColor Red
        return @()
    }
    
    if ($UseCachedListOnly) {
        Write-Host "Using discovered peer list..." -ForegroundColor Gray
    }
    else {
        Write-Host "Evaluating storage peers..." -ForegroundColor Gray
    }
    
    # Fast path for job creation: use the peer list already discovered via D and
    # distribute new jobs without rescanning the whole ring.
    if ($UseCachedListOnly) {
        $availablePeers = @((Get-StoragePeersList) | Where-Object { $_.TailscaleIP -and $_.TailscaleIP -ne $config.TailscaleIP })
        if ($availablePeers.Count -lt $MinPeers) {
            Write-Host "[WARN] Only $($availablePeers.Count) discovered peers available (need $MinPeers minimum)" -ForegroundColor Yellow
            if ($availablePeers.Count -eq 0) {
                return @()
            }
        }
        
        $assignmentCount = @{}
        foreach ($job in @(Get-Jobs)) {
            foreach ($peer in @($job.PeerDestinations)) {
                if (-not $peer.TailscaleIP) { continue }
                if (-not $assignmentCount.ContainsKey($peer.TailscaleIP)) {
                    $assignmentCount[$peer.TailscaleIP] = 0
                }
                $assignmentCount[$peer.TailscaleIP]++
            }
        }
        
        $candidatePeers = @()
        foreach ($peer in $availablePeers) {
            $candidatePeers += [PSCustomObject]@{
                Hostname = $peer.Hostname
                TailscaleIP = $peer.TailscaleIP
                Location = $peer.Location
                QuotaGB = if ($peer.QuotaGB) { $peer.QuotaGB } else { 100 }
                UsedGB = $null
                UsedPct = $null
                RemainingGB = $null
                PingMs = $null
                AssignmentCount = if ($assignmentCount.ContainsKey($peer.TailscaleIP)) { $assignmentCount[$peer.TailscaleIP] } else { 0 }
            }
        }
        
        return @($candidatePeers | Sort-Object AssignmentCount, @{ Expression = 'QuotaGB'; Descending = $true }, Hostname | Select-Object -First $MinPeers)
    }
    
    # Full validation path for runtime or explicit health checks
    $availablePeers = Get-AvailableStoragePeers
    
    if ($availablePeers.Count -lt $MinPeers) {
        Write-Host "[WARN] Only $($availablePeers.Count) peers available (need $MinPeers minimum)" -ForegroundColor Yellow
        if ($availablePeers.Count -eq 0) {
            return @()
        }
    }
    
    # Get storage usage for each peer
    $peersWithUsage = @()
    foreach ($peer in $availablePeers) {
        Write-Host "." -NoNewline -ForegroundColor Gray
        
        $usage = Get-PeerStorageUsage -TailscaleIP $peer.TailscaleIP -CustomerCode $config.CustomerCode
        
        $usedGB = if ($usage) { $usage.UsedGB } else { 0 }
        $quotaGB = if ($peer.QuotaGB) { $peer.QuotaGB } else { 100 }
        $usedPct = if ($quotaGB -gt 0) {
            [math]::Round(($usedGB / $quotaGB) * 100, 1)
        } else {
            100
        }
        
        $peersWithUsage += [PSCustomObject]@{
            Hostname = $peer.Hostname
            TailscaleIP = $peer.TailscaleIP
            Location = $peer.Location
            QuotaGB = $quotaGB
            UsedGB = $usedGB
            UsedPct = $usedPct
            RemainingGB = [math]::Max(0, [math]::Round($quotaGB - $usedGB, 2))
            PingMs = $peer.PingMs
        }
    }
    Write-Host "" # newline
    
    # Sort by usage percentage (prefer least used)
    $sortedPeers = $peersWithUsage | Sort-Object UsedPct
    
    # Never preselect peers that are already at or above quota.
    $eligiblePeers = $sortedPeers | Where-Object { $_.UsedPct -lt 100 }
    
    # Select peers:
    # - First, try to use peers under 70% capacity
    # - If not enough, use larger peers that still have remaining quota
    $selectedPeers = @()
    $peersUnder70 = $eligiblePeers | Where-Object { $_.UsedPct -lt 70 }
    $peersOver70 = $eligiblePeers | Where-Object { $_.UsedPct -ge 70 } | Sort-Object QuotaGB -Descending
    
    # Take from under-70% first
    foreach ($peer in $peersUnder70) {
        if ($selectedPeers.Count -ge $MinPeers) { break }
        $selectedPeers += $peer
    }
    
    # If still need more, take from over-70% (largest first)
    foreach ($peer in $peersOver70) {
        if ($selectedPeers.Count -ge $MinPeers) { break }
        $selectedPeers += $peer
    }
    
    return $selectedPeers
}

#endregion

#region Retention Policy

function Get-RetentionFolderName {
    <#
    .SYNOPSIS
        Generates folder name based on retention type and date
    #>
    param(
        [string]$AppName,
        [string]$RetentionType,  # 'monthly', 'weekly', 'recent'
        [datetime]$Date = (Get-Date)
    )
    
    switch ($RetentionType) {
        'monthly' {
            # Use year-month format
            return "$AppName-$($Date.ToString('yyyy-MM'))-monthly"
        }
        'weekly' {
            # Use date of Saturday
            return "$AppName-$($Date.ToString('yyyy-MM-dd'))-weekly"
        }
        'recent' {
            # Use datetime
            return "$AppName-$($Date.ToString('yyyy-MM-dd-HHmm'))"
        }
        default {
            return "$AppName-$($Date.ToString('yyyy-MM-dd-HHmm'))"
        }
    }
}

function Get-NextSaturday {
    <#
    .SYNOPSIS
        Gets the most recent Saturday (or today if Saturday)
    #>
    param([datetime]$FromDate = (Get-Date))
    
    $daysUntilSaturday = (6 - [int]$FromDate.DayOfWeek) % 7
    if ($daysUntilSaturday -eq 0 -and $FromDate.DayOfWeek -ne [DayOfWeek]::Saturday) {
        $daysUntilSaturday = 7
    }
    
    # Actually we want LAST Saturday, not next
    $daysSinceSaturday = ([int]$FromDate.DayOfWeek + 1) % 7
    if ($FromDate.DayOfWeek -eq [DayOfWeek]::Saturday) {
        $daysSinceSaturday = 0
    }
    
    return $FromDate.AddDays(-$daysSinceSaturday).Date
}

function Get-LastDayOfMonth {
    <#
    .SYNOPSIS
        Gets the last day of a given month
    #>
    param(
        [datetime]$Date = (Get-Date)
    )
    
    return (New-Object DateTime($Date.Year, $Date.Month, 1)).AddMonths(1).AddDays(-1)
}

function Test-IsRetentionDay {
    <#
    .SYNOPSIS
        Checks if today qualifies for a specific retention type
    #>
    param(
        [string]$RetentionType,
        [datetime]$Date = (Get-Date)
    )
    
    switch ($RetentionType) {
        'monthly' {
            # Last day of month
            $lastDay = Get-LastDayOfMonth -Date $Date
            return $Date.Date -eq $lastDay.Date
        }
        'weekly' {
            # Saturday
            return $Date.DayOfWeek -eq [DayOfWeek]::Saturday
        }
        'recent' {
            # Always qualifies
            return $true
        }
        default {
            return $true
        }
    }
}

#endregion

#region Unified Backup Job

function New-UnifiedBackupJob {
    <#
    .SYNOPSIS
        Creates a new backup job with automatic peer selection and retention policy
    #>
    Clear-Host
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "     CREATE BACKUP JOB" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    # Check if ring is configured
    $ringConfig = Get-RingConfig
    if (-not $ringConfig -or -not $ringConfig.CustomerCode) {
        Write-Host "ERROR: This machine is not configured as a storage peer." -ForegroundColor Red
        Write-Host ""
        Write-Host "Please run 'Add Storage Peer' (P) first." -ForegroundColor Yellow
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
    
    # Clean app name for folder naming
    $appNameClean = $appName -replace '[^\w\-]', '_'

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

    # Step 4: Retention Policy
    Write-Host "`n--- Step 4: Retention Policy ---" -ForegroundColor Yellow
    Write-Host "Configure how many backup copies to keep:"
    Write-Host ""
    Write-Host "Monthly copies are created on the last day of each month."
    Write-Host "Weekly copies are created every Saturday."
    Write-Host "Recent copies are the most recent backups (always created)."
    Write-Host ""
    
    # Get retention limits from ring policies (set by RRM)
    $policies = Get-RingPolicies
    $monthlyMin = $policies.RetentionMonthlyMin; $monthlyMax = $policies.RetentionMonthlyMax
    $weeklyMin = $policies.RetentionWeeklyMin; $weeklyMax = $policies.RetentionWeeklyMax
    $recentMin = $policies.RetentionRecentMin; $recentMax = $policies.RetentionRecentMax
    
    $monthlyRetention = Read-Host "Monthly copies to keep (0-$monthlyMax)"
    if (-not ($monthlyRetention -as [int]) -or [int]$monthlyRetention -lt $monthlyMin -or [int]$monthlyRetention -gt $monthlyMax) {
        Write-Host "`nError: Must be between $monthlyMin and $monthlyMax!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }
    
    $weeklyRetention = Read-Host "Weekly copies to keep (0-$weeklyMax)"
    if (-not ($weeklyRetention -as [int]) -or [int]$weeklyRetention -lt $weeklyMin -or [int]$weeklyRetention -gt $weeklyMax) {
        Write-Host "`nError: Must be between $weeklyMin and $weeklyMax!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }
    
    $recentRetention = Read-Host "Recent copies to keep ($recentMin-$recentMax)"
    if (-not ($recentRetention -as [int]) -or [int]$recentRetention -lt $recentMin -or [int]$recentRetention -gt $recentMax) {
        Write-Host "`nError: Must be between $recentMin and $recentMax!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }
    
    $totalMaxCopies = [int]$monthlyRetention + [int]$weeklyRetention + [int]$recentRetention
    
    Write-Host ""
    Write-Host "Maximum copies: $totalMaxCopies" -ForegroundColor Cyan
    Write-Host "  - Up to $monthlyRetention monthly (end of month)" -ForegroundColor Gray
    Write-Host "  - Up to $weeklyRetention weekly (Saturdays)" -ForegroundColor Gray
    Write-Host "  - Up to $recentRetention recent" -ForegroundColor Gray

    # Step 5: Frequency
    Write-Host "`n--- Step 5: Set Frequency ---" -ForegroundColor Yellow
    $frequency = Read-Host "Run backup every N hours (1-24)"

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

    # Automatic Peer Selection
    Write-Host "`n--- Selecting Storage Peers ---" -ForegroundColor Yellow
    
    $selectedPeers = Select-BackupPeers -MinPeers 2 -UseCachedListOnly
    
    if ($selectedPeers.Count -eq 0) {
        Write-Host "`nNo storage peers available!" -ForegroundColor Red
        Write-Host "Run 'Discover & Update' (D) to find peers." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }
    
    Write-Host ""
    Write-Host "Selected $($selectedPeers.Count) peer(s) for backup:" -ForegroundColor Green
    foreach ($peer in $selectedPeers) {
        if ($null -ne $peer.UsedPct) {
            Write-Host "  - $($peer.Hostname) @ $($peer.Location) ($($peer.UsedPct)% used)" -ForegroundColor White
        }
        else {
            Write-Host "  - $($peer.Hostname) @ $($peer.Location)" -ForegroundColor White
        }
    }

    # Build destination paths
    $typeFolder = switch ($backupType) {
        "F" { "file" }
        "D" { "directory" }
        "SQL" { "database" }
    }
    
    # Create peer destination info
    $peerDestinations = @()
    foreach ($peer in $selectedPeers) {
        $basePath = "\\$($peer.TailscaleIP)\$(Get-RRShareName)\$($customerCode.ToUpper())\$localLocation\$appNameClean\$typeFolder"
        $peerDestinations += @{
            TailscaleIP = $peer.TailscaleIP
            Hostname = $peer.Hostname
            Location = $peer.Location
            BasePath = $basePath
        }
    }

    # Generate job name
    $jobName = "$appNameClean"
    
    # Check for duplicates
    $jobs = @(Get-Jobs)
    if ($jobs | Where-Object { $_.JobName -eq $jobName }) {
        $counter = 2
        while ($jobs | Where-Object { $_.JobName -eq "$jobName-$counter" }) {
            $counter++
        }
        $jobName = "$jobName-$counter"
    }

    # Create job object
    $newJob = @{
        JobName = $jobName
        AppName = $appName
        AppNameClean = $appNameClean
        BackupType = $backupType
        BackupObject = $backupObject
        CustomerCode = $customerCode
        SourceLocation = $localLocation
        
        # Retention policy
        RetentionMonthly = [int]$monthlyRetention
        RetentionWeekly = [int]$weeklyRetention
        RetentionRecent = [int]$recentRetention
        
        # Peer destinations
        PeerDestinations = $peerDestinations
        
        # Schedule
        Frequency = [int]$frequency
        StartHour = [int]$startHour
        
        # Metadata
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
    Write-Host "`n--- Creating Scheduled Task ---" -ForegroundColor Yellow
    if (New-ScheduledBackupTask -Job $newJob) {
        Write-Host ""
        Write-Host "===============================================" -ForegroundColor Green
        Write-Host "     BACKUP JOB CREATED SUCCESSFULLY!" -ForegroundColor Green
        Write-Host "===============================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Job Name:    $jobName" -ForegroundColor White
        Write-Host "  Application: $appName" -ForegroundColor White
        Write-Host "  Type:        $backupType" -ForegroundColor White
        Write-Host "  Source:      $backupObject" -ForegroundColor White
        Write-Host "  Retention:   $monthlyRetention monthly, $weeklyRetention weekly, $recentRetention recent" -ForegroundColor White
        Write-Host "  Frequency:   Every $frequency hour(s) starting at $($startHour):00" -ForegroundColor White
        Write-Host "  Peers:       $($selectedPeers.Count) ($($selectedPeers.Hostname -join ', '))" -ForegroundColor White
        Write-Host ""
        Write-Log "Created backup job: $jobName (App: $appName, Type: $backupType)" -Level SUCCESS
    }
    else {
        Write-Host "`nJob saved but scheduled task creation failed!" -ForegroundColor Red
    }

    # Sync with RRM API - register peer + updated job list
    if (Get-Command 'Register-PeerWithRrmApi' -ErrorAction SilentlyContinue) {
        Write-Host "Syncing with RRM Monitor..." -ForegroundColor Gray -NoNewline
        try {
            $rrmResult = Register-PeerWithRrmApi
            if ($rrmResult) {
                Write-Host " [OK]" -ForegroundColor Green
            } else {
                Write-Host " [SKIP - not configured]" -ForegroundColor Yellow
            }
        } catch {
            Write-Host " [SKIP - $($_.Exception.Message)]" -ForegroundColor Yellow
        }
    }

    Read-Host "`nPress Enter to continue"
}

#endregion

# Functions are available when dot-sourced
