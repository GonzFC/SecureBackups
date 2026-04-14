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
    [string]$JobName,

    [switch]$SkipUpdateCheck,

    # Run only the auto-update check and exit — no backup job
    [switch]$UpdateOnly
)

# Configuration - Data in ProgramData (separate from git install directory)
$script:ConfigPath = "C:\ProgramData\VLABS_ResilienceRing"
$script:JobsFile = Join-Path $ConfigPath "jobs.json"           # Master data (config)
$script:JobsStatusFile = Join-Path $ConfigPath "jobs-status.json"  # Transaction data (run history)
$script:LogPath = Join-Path $ConfigPath "Logs"

# Repo constants (for auto-update)
$script:RepoOwner  = 'GonzFC'
$script:RepoName   = 'SecureBackups'
$script:RepoBranch = 'main'
$script:InstallPath = $PSScriptRoot
$script:OldRrmUrl  = 'https://mercury.velociraptor-hoki.ts.net'
$script:NewRrmUrl  = 'https://rr-api.ait.vlabs.network'

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
        'ERROR' {
            $script:LastBackupError = $Message
            Write-Host $logEntry -ForegroundColor Red
        }
        'WARNING' { Write-Host $logEntry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $logEntry -ForegroundColor Green }
        default { Write-Host $logEntry -ForegroundColor Gray }
    }
}

#endregion

#region Auto-Update

function Get-LocalRrVersion {
    $versionFile = Join-Path $script:InstallPath 'version.txt'
    if (Test-Path $versionFile) { return (Get-Content $versionFile -Raw).Trim() }
    return $null
}

function Invoke-AutoUpdate {
    try {
        $versionUrl = "https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/version.txt"
        $latestVersion = (Invoke-RestMethod -Uri $versionUrl -UseBasicParsing -TimeoutSec 10).Trim()
        $currentVersion = Get-LocalRrVersion

        if ($null -eq $currentVersion -or [Version]$latestVersion -le [Version]$currentVersion) { return }

        Write-Log "Auto-update: new version available ($currentVersion -> $latestVersion). Updating..." -Level INFO

        $gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
        $gitRepo = Test-Path (Join-Path $script:InstallPath '.git')

        if ($gitAvailable -and $gitRepo) {
            Push-Location $script:InstallPath
            git fetch origin $script:RepoBranch 2>&1 | Out-Null
            git reset --hard "origin/$script:RepoBranch" 2>&1 | Out-Null
            Pop-Location
        } else {
            $zipUrl   = "https://github.com/$script:RepoOwner/$script:RepoName/archive/refs/heads/$script:RepoBranch.zip"
            $zipPath  = Join-Path $env:TEMP 'RR_Update.zip'
            $tmpPath  = Join-Path $env:TEMP 'RR_Update_Extract'
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
            if (Test-Path $tmpPath) { Remove-Item $tmpPath -Recurse -Force }
            Expand-Archive -Path $zipPath -DestinationPath $tmpPath -Force
            $srcFolder = Get-ChildItem $tmpPath -Directory | Select-Object -First 1
            Get-ChildItem $srcFolder.FullName -File | ForEach-Object {
                Copy-Item $_.FullName -Destination (Join-Path $script:InstallPath $_.Name) -Force
            }
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            Remove-Item $tmpPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        Get-ChildItem -Path $script:InstallPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

        # Ensure Tailscale DNS is enabled on all peers
        $tailscaleCmd = Get-Command tailscale -ErrorAction SilentlyContinue
        $tailscaleExe = if ($tailscaleCmd) { $tailscaleCmd.Source } else { $null }
        if (-not $tailscaleExe) {
            $tailscaleExe = 'C:\Program Files\Tailscale\tailscale.exe'
        }
        if (Test-Path $tailscaleExe) {
            & $tailscaleExe up --accept-dns=true 2>&1 | Out-Null
            Write-Log "Auto-update: Tailscale DNS enabled" -Level INFO
        }

        Write-Log "Auto-update: updated to $latestVersion. Re-launching..." -Level INFO

        # Re-invoke the updated script and skip update check to avoid loop
        $scriptFile = Join-Path $script:InstallPath 'Execute-Backup.ps1'
        if ($UpdateOnly) {
            & powershell.exe -NonInteractive -ExecutionPolicy Bypass `
                -File $scriptFile -UpdateOnly -SkipUpdateCheck
        } else {
            & powershell.exe -NonInteractive -ExecutionPolicy Bypass `
                -File $scriptFile -JobName $JobName -SkipUpdateCheck
        }
        exit $LASTEXITCODE
    }
    catch {
        Write-Log "Auto-update failed (non-fatal): $_" -Level WARNING
    }
}

function Ensure-AutoUpdateTask {
    # Silently registers the RR-AutoUpdate scheduled task if it does not exist.
    # Called on every job run so peers that never open the menu still get it.
    $taskName = "RR-AutoUpdate"
    try {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) { return }   # already installed

        $scriptFile = Join-Path $script:InstallPath 'Execute-Backup.ps1'
        if (-not (Test-Path $scriptFile)) { return }

        $action = New-ScheduledTaskAction `
            -Execute "PowerShell.exe" `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptFile`" -UpdateOnly"

        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Hours 1) `
            -RepetitionDuration (New-TimeSpan -Days 9999)

        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal   = New-ScheduledTaskPrincipal -UserId $currentUser -RunLevel Highest

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
            -MultipleInstances IgnoreNew

        Register-ScheduledTask -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "VLABS Resilience Ring - hourly auto-update check" `
            -ErrorAction Stop | Out-Null

        Write-Log "Registered scheduled task: $taskName (hourly auto-update)" -Level INFO
    }
    catch {
        Write-Log "Could not register auto-update task (non-fatal): $_" -Level WARNING
    }
}

function Invoke-RrmUrlMigration {
    # Silently migrate old RRM URL to the new server if still present in config
    try {
        $configFile = Join-Path $script:ConfigPath 'ring-config.json'
        if (-not (Test-Path $configFile)) { return }
        $config = Get-Content $configFile -Raw | ConvertFrom-Json
        if ($config.RrmApiUrl -eq $script:OldRrmUrl) {
            $config.RrmApiUrl = $script:NewRrmUrl
            $config | ConvertTo-Json -Depth 10 | Set-Content $configFile -Encoding UTF8
            Write-Log "Auto-migration: RrmApiUrl updated to $script:NewRrmUrl" -Level INFO
        }
    }
    catch {
        Write-Log "RRM URL migration failed (non-fatal): $_" -Level WARNING
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

function Get-RingPolicies {
    <#
    .SYNOPSIS
        Reads ring policies from local _nodeinfo/ring-policies.json
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

function Invoke-RingPolicyEnforcement {
    <#
    .SYNOPSIS
        Enforces ring policies on a job's retention settings after successful backup
    .DESCRIPTION
        If a job's retention values exceed ring policy limits, automatically adjusts
        the master data to comply. This ensures ring-wide consistency.
    #>
    param([string]$JobName)
    
    try {
        $policies = Get-RingPolicies
        $jobs = Get-Jobs
        $modified = $false
        
        for ($i = 0; $i -lt $jobs.Count; $i++) {
            if ($jobs[$i].JobName -ne $JobName) { continue }
            
            $job = $jobs[$i]
            
            # Check and enforce Monthly limits
            if ($null -ne $job.RetentionMonthly) {
                if ($job.RetentionMonthly -lt $policies.RetentionMonthlyMin) {
                    Write-Log "Policy enforcement: $JobName Monthly $($job.RetentionMonthly) -> $($policies.RetentionMonthlyMin) (below min)" -Level INFO
                    $jobs[$i] | Add-Member -NotePropertyName 'RetentionMonthly' -NotePropertyValue $policies.RetentionMonthlyMin -Force
                    $modified = $true
                }
                elseif ($job.RetentionMonthly -gt $policies.RetentionMonthlyMax) {
                    Write-Log "Policy enforcement: $JobName Monthly $($job.RetentionMonthly) -> $($policies.RetentionMonthlyMax) (above max)" -Level INFO
                    $jobs[$i] | Add-Member -NotePropertyName 'RetentionMonthly' -NotePropertyValue $policies.RetentionMonthlyMax -Force
                    $modified = $true
                }
            }
            
            # Check and enforce Weekly limits
            if ($null -ne $job.RetentionWeekly) {
                if ($job.RetentionWeekly -lt $policies.RetentionWeeklyMin) {
                    Write-Log "Policy enforcement: $JobName Weekly $($job.RetentionWeekly) -> $($policies.RetentionWeeklyMin) (below min)" -Level INFO
                    $jobs[$i] | Add-Member -NotePropertyName 'RetentionWeekly' -NotePropertyValue $policies.RetentionWeeklyMin -Force
                    $modified = $true
                }
                elseif ($job.RetentionWeekly -gt $policies.RetentionWeeklyMax) {
                    Write-Log "Policy enforcement: $JobName Weekly $($job.RetentionWeekly) -> $($policies.RetentionWeeklyMax) (above max)" -Level INFO
                    $jobs[$i] | Add-Member -NotePropertyName 'RetentionWeekly' -NotePropertyValue $policies.RetentionWeeklyMax -Force
                    $modified = $true
                }
            }
            
            # Check and enforce Recent limits
            if ($null -ne $job.RetentionRecent) {
                if ($job.RetentionRecent -lt $policies.RetentionRecentMin) {
                    Write-Log "Policy enforcement: $JobName Recent $($job.RetentionRecent) -> $($policies.RetentionRecentMin) (below min)" -Level INFO
                    $jobs[$i] | Add-Member -NotePropertyName 'RetentionRecent' -NotePropertyValue $policies.RetentionRecentMin -Force
                    $modified = $true
                }
                elseif ($job.RetentionRecent -gt $policies.RetentionRecentMax) {
                    Write-Log "Policy enforcement: $JobName Recent $($job.RetentionRecent) -> $($policies.RetentionRecentMax) (above max)" -Level INFO
                    $jobs[$i] | Add-Member -NotePropertyName 'RetentionRecent' -NotePropertyValue $policies.RetentionRecentMax -Force
                    $modified = $true
                }
            }
            
            break
        }
        
        if ($modified) {
            Save-Jobs -Jobs $jobs
            Write-Log "Ring policy enforcement: Updated job $JobName to comply with ring limits" -Level INFO
        }
    }
    catch {
        Write-Log "Policy enforcement error: $_" -Level WARNING
    }
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
    .DESCRIPTION
        Called ONLY after successful and integrity-verified backup.
        Retention values: Monthly 0-3, Weekly 0-4, Recent 1-6.
        Recent is always >= 1, so at least one copy always survives.
    #>
    param(
        [string]$BasePath,
        [string]$AppName,
        [int]$MonthlyRetention,
        [int]$WeeklyRetention,
        [int]$RecentRetention
    )
    
    # Safety: Recent must be at least 1 (enforced at input, but double-check)
    if ($RecentRetention -lt 1) { $RecentRetention = 1 }
    
    Write-Log "Applying retention policy: $MonthlyRetention monthly, $WeeklyRetention weekly, $RecentRetention recent" -Level INFO
    
    if (-not (Test-Path $BasePath)) { return }
    
    $allFolders = Get-ChildItem -Path $BasePath -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "$AppName-*" } |
                  Sort-Object Name -Descending
    
    # Separate by type
    $monthlyFolders = $allFolders | Where-Object { $_.Name -match '-monthly$' }
    $weeklyFolders = $allFolders | Where-Object { $_.Name -match '-weekly$' }
    $recentFolders = $allFolders | Where-Object { $_.Name -notmatch '-(monthly|weekly)$' }
    
    # Delete excess monthly (0 = delete all monthly)
    if ($monthlyFolders.Count -gt $MonthlyRetention) {
        $toDelete = $monthlyFolders | Select-Object -Skip $MonthlyRetention
        foreach ($folder in $toDelete) {
            Write-Log "Deleting old monthly backup: $($folder.Name)" -Level INFO
            Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Delete excess weekly (0 = delete all weekly)
    if ($weeklyFolders.Count -gt $WeeklyRetention) {
        $toDelete = $weeklyFolders | Select-Object -Skip $WeeklyRetention
        foreach ($folder in $toDelete) {
            Write-Log "Deleting old weekly backup: $($folder.Name)" -Level INFO
            Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Delete excess recent (always >= 1)
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

#region Tailscale Session

function Ensure-TailscaleForBackup {
    <#
    .SYNOPSIS
        Ensures Tailscale is connected for the duration of a backup job
    .DESCRIPTION
        If Tailscale is already connected, leaves it untouched.
        If it is disconnected, brings it up and marks it for cleanup at the end.
    #>
    $result = [PSCustomObject]@{
        Ready = $false
        StartedByJob = $false
        Mode = 'AlwaysOn'
        Reason = $null
    }
    
    $tailscaleExe = Get-TailscaleExePath
    if (-not $tailscaleExe) {
        $result.Reason = "Tailscale not installed"
        return $result
    }
    
    $config = Get-RingConfig
    $result.Mode = Get-EffectiveTailscaleMode -Config $config
    
    $tsStatus = Test-TailscaleInstalled
    if ($tsStatus.Connected) {
        $result.Ready = $true
        return $result
    }
    
    Write-Log "Tailscale is disconnected. Bringing it up for this backup job..." -Level INFO
    & $tailscaleExe up --accept-dns=false 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $result.Reason = "tailscale up failed"
        return $result
    }
    
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        Start-Sleep -Seconds 1
        $tsStatus = Test-TailscaleInstalled
        if ($tsStatus.Connected) {
            $result.Ready = $true
            $result.StartedByJob = $true
            return $result
        }
    }
    
    $result.Reason = "Tailscale did not reach connected state"
    return $result
}

function Restore-TailscaleAfterBackup {
    <#
    .SYNOPSIS
        Restores Tailscale connectivity after a backup job
    .DESCRIPTION
        Only disconnects Tailscale when the current job explicitly started it.
    #>
    param($Session)
    
    if (-not $Session -or -not $Session.StartedByJob -or $Session.Mode -ne 'PerJob') {
        return
    }
    
    $tailscaleExe = Get-TailscaleExePath
    if (-not $tailscaleExe) {
        return
    }
    
    Write-Log "Stopping Tailscale after backup job completion..." -Level INFO
    & $tailscaleExe down 2>&1 | Out-Null
}

function Test-TailscalePeerReachable {
    <#
    .SYNOPSIS
        Verifies that a destination peer's Tailscale IP responds before attempting SMB
    .DESCRIPTION
        Runs "tailscale ping" with a short timeout. Returns $true only when a pong
        is received, which confirms both that the local Tailscale session is alive
        and that the remote peer is online on the Tailscale network.
    #>
    param(
        [string]$TailscaleIP,
        [int]$TimeoutSeconds = 5
    )

    $tailscaleExe = Get-TailscaleExePath
    if (-not $tailscaleExe) {
        return $false
    }

    try {
        $output = & $tailscaleExe ping --timeout="${TimeoutSeconds}s" --c=1 $TailscaleIP 2>&1
        return ($output -match 'pong from')
    }
    catch {
        return $false
    }
}

#endregion

#region SMB Connection

function Connect-ToPeer {
    param(
        [string]$TailscaleIP,
        [string]$CustomerCode,
        [int]$TimeoutSeconds = 30
    )

    $sharePath = "\\$TailscaleIP\RR_Backups"

    # Check if already connected (use -SimpleMatch to avoid regex issues with backslashes)
    $existing = net use 2>$null | Select-String -SimpleMatch $sharePath
    if ($existing) { return $true }

    # Get service account password
    $password = Get-RingServicePassword -CustomerCode $CustomerCode

    # Run net use in a background job to enforce a timeout.
    # Without this, net use can hang indefinitely when the peer is unreachable.
    $connectJob = Start-Job -ScriptBlock {
        param($path, $pass)
        net use $path /user:RR_Service $pass 2>&1 | Out-Null
        return $LASTEXITCODE
    } -ArgumentList $sharePath, $password

    $finished = Wait-Job -Job $connectJob -Timeout $TimeoutSeconds
    if (-not $finished) {
        Stop-Job  -Job $connectJob -ErrorAction SilentlyContinue
        Remove-Job -Job $connectJob -Force -ErrorAction SilentlyContinue
        net use $sharePath /delete 2>$null | Out-Null
        return $false
    }

    $exitCode = Receive-Job -Job $connectJob
    Remove-Job -Job $connectJob -Force -ErrorAction SilentlyContinue
    return ($exitCode -eq 0)
}

function Disconnect-FromPeer {
    param([string]$TailscaleIP)
    
    $sharePath = "\\$TailscaleIP\RR_Backups"
    net use $sharePath /delete 2>$null | Out-Null
}

#endregion

#region Quota Enforcement

function Get-BackupSourceSizeBytes {
    param($Job)
    
    try {
        if ($Job.BackupType -eq 'F') {
            $file = Get-Item $Job.BackupObject -ErrorAction Stop
            return [int64]$file.Length
        }
        
        $size = (Get-ChildItem $Job.BackupObject -Recurse -File -ErrorAction SilentlyContinue |
                 Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        $result = if ($size) { $size } else { 0 }
        return [int64]$result
    }
    catch {
        return 0
    }
}

function Get-PeerQuotaGB {
    param(
        [string]$TailscaleIP,
        [double]$FallbackQuotaGB = 0
    )
    
    $peer = @(Get-StoragePeersList) | Where-Object { $_.TailscaleIP -eq $TailscaleIP } | Select-Object -First 1
    if ($peer -and $peer.QuotaGB) {
        return [double]$peer.QuotaGB
    }
    
    return [double]$FallbackQuotaGB
}

function Get-PeerStorageUsageBytes {
    param(
        [string]$TailscaleIP,
        [string]$CustomerCode
    )
    
    $sharePath = "\\$TailscaleIP\$(Get-RRShareName)"
    
    try {
        $connected = Connect-ToPeer -TailscaleIP $TailscaleIP -CustomerCode $CustomerCode
        if (-not $connected) {
            return $null
        }
        
        $usedBytes = 0
        if (Test-Path $sharePath) {
            $usedBytes = (Get-ChildItem $sharePath -Recurse -ErrorAction SilentlyContinue |
                          Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        }
        
        $result = if ($usedBytes) { $usedBytes } else { 0 }
        return [int64]$result
    }
    catch {
        return $null
    }
    finally {
        Disconnect-FromPeer -TailscaleIP $TailscaleIP
    }
}

function Get-PeerTypeFolder {
    param([string]$BackupType)
    
    switch ($BackupType) {
        'F' { return 'file' }
        'D' { return 'directory' }
        'SQL' { return 'database' }
        default { return $BackupType.ToLower() }
    }
}

function New-PeerExecutionDescriptor {
    param(
        $Peer,
        $Job,
        [double]$QuotaGB
    )
    
    $appName = if ($Job.AppNameClean) { $Job.AppNameClean } elseif ($Job.AppName) { $Job.AppName } else { $Job.JobName }
    $location = if ($Job.SourceLocation) { $Job.SourceLocation } else { (Get-RingConfig).Location }
    $customerCode = if ($Job.CustomerCode) { $Job.CustomerCode } else { (Get-RingConfig).CustomerCode }
    $typeFolder = Get-PeerTypeFolder -BackupType $Job.BackupType
    
    return [PSCustomObject]@{
        TailscaleIP = $Peer.TailscaleIP
        Hostname = $Peer.Hostname
        Location = $Peer.Location
        QuotaGB = $QuotaGB
        BasePath = "\\$($Peer.TailscaleIP)\$(Get-RRShareName)\$($customerCode.ToUpper())\$location\$appName\$typeFolder"
    }
}

function Test-PeerQuotaCapacity {
    param(
        $Peer,
        $Job,
        [int64]$EstimatedBackupBytes
    )
    
    $customerCode = if ($Job.CustomerCode) { $Job.CustomerCode } else { (Get-RingConfig).CustomerCode }
    $quotaGB = Get-PeerQuotaGB -TailscaleIP $Peer.TailscaleIP -FallbackQuotaGB $Peer.QuotaGB
    
    if ($quotaGB -le 0) {
        Write-Log "Peer $($Peer.Hostname) has no valid quota metadata; skipping quota enforcement for this peer." -Level WARNING
        return [PSCustomObject]@{
            Allowed = $true
            Descriptor = (New-PeerExecutionDescriptor -Peer $Peer -Job $Job -QuotaGB $quotaGB)
        }
    }
    
    $usedBytes = Get-PeerStorageUsageBytes -TailscaleIP $Peer.TailscaleIP -CustomerCode $customerCode
    if ($null -eq $usedBytes) {
        Write-Log "Could not determine current usage for peer $($Peer.Hostname); skipping peer." -Level WARNING
        return [PSCustomObject]@{
            Allowed = $false
            Reason = "Usage unavailable"
        }
    }
    
    $quotaBytes = [int64]($quotaGB * 1GB)
    $projectedBytes = $usedBytes + $EstimatedBackupBytes
    
    if ($projectedBytes -gt $quotaBytes) {
        $usedGB = [math]::Round($usedBytes / 1GB, 2)
        $projectedGB = [math]::Round($projectedBytes / 1GB, 2)
        Write-Log "Skipping peer $($Peer.Hostname): projected usage $projectedGB GB exceeds quota $quotaGB GB (current $usedGB GB)." -Level WARNING
        return [PSCustomObject]@{
            Allowed = $false
            Reason = "Quota exceeded"
            UsedBytes = $usedBytes
            QuotaBytes = $quotaBytes
        }
    }
    
    return [PSCustomObject]@{
        Allowed = $true
        UsedBytes = $usedBytes
        QuotaBytes = $quotaBytes
        Descriptor = (New-PeerExecutionDescriptor -Peer $Peer -Job $Job -QuotaGB $quotaGB)
    }
}

function Resolve-ExecutionPeers {
    param($Job)
    
    $config = Get-RingConfig
    $localPeerIp = if ($config) { $config.TailscaleIP } else { $null }
    $requiredPeers = if ($Job.PeerDestinations -and $Job.PeerDestinations.Count -gt 0) {
        $Job.PeerDestinations.Count
    } else {
        2
    }
    
    $estimatedBackupBytes = Get-BackupSourceSizeBytes -Job $Job
    $preferredByIp = @{}
    foreach ($peer in @($Job.PeerDestinations)) {
        if ($peer.TailscaleIP) {
            $preferredByIp[$peer.TailscaleIP] = $true
        }
    }
    
    $availablePeers = @(Get-AvailableStoragePeers)
    $availableByIp = @{}
    foreach ($peer in $availablePeers) {
        $availableByIp[$peer.TailscaleIP] = $peer
    }
    
    $resolvedPeers = @()
    $selectedIps = @{}
    
    foreach ($peer in @($Job.PeerDestinations)) {
        if ($localPeerIp -and $peer.TailscaleIP -eq $localPeerIp) {
            Write-Log "Skipping local peer entry for job $($Job.JobName); recent backups must target remote peers only." -Level WARNING
            continue
        }
        
        $candidate = if ($availableByIp.ContainsKey($peer.TailscaleIP)) { $availableByIp[$peer.TailscaleIP] } else { $peer }
        $capacity = Test-PeerQuotaCapacity -Peer $candidate -Job $Job -EstimatedBackupBytes $estimatedBackupBytes
        if ($capacity.Allowed) {
            $resolvedPeers += $capacity.Descriptor
            $selectedIps[$candidate.TailscaleIP] = $true
        }
    }
    
    if ($resolvedPeers.Count -lt $requiredPeers) {
        Write-Log "Trying alternate peers because one or more configured destinations have no remaining quota." -Level WARNING
    }
    
    $alternatePeers = $availablePeers | Where-Object {
        -not $selectedIps.ContainsKey($_.TailscaleIP) -and -not $preferredByIp.ContainsKey($_.TailscaleIP)
    }
    
    foreach ($peer in $alternatePeers) {
        if ($resolvedPeers.Count -ge $requiredPeers) { break }
        
        $capacity = Test-PeerQuotaCapacity -Peer $peer -Job $Job -EstimatedBackupBytes $estimatedBackupBytes
        if ($capacity.Allowed) {
            Write-Log "Using alternate peer $($peer.Hostname) for this run." -Level WARNING
            $resolvedPeers += $capacity.Descriptor
            $selectedIps[$peer.TailscaleIP] = $true
        }
    }
    
    return $resolvedPeers
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
    # Support both BasePath (correct) and SharePath (legacy/bug) property names
    $basePath = if ($Peer.BasePath) { $Peer.BasePath } else { $Peer.SharePath }
    # Fallback chain for app name: AppNameClean -> AppName -> JobName
    $appName = if ($Job.AppNameClean) { $Job.AppNameClean } elseif ($Job.AppName) { $Job.AppName } else { $Job.JobName }
    # CustomerCode from job, or fall back to ring-config
    $customerCode = if ($Job.CustomerCode) { $Job.CustomerCode } else { (Get-RingConfig).CustomerCode }
    
    $peerLabel = if ($Peer.Location) { $Peer.Location } elseif ($Peer.Hostname) { $Peer.Hostname } else { $peerIP }
    Write-Log "Backing up to peer: $peerLabel ($peerIP) - Type: $RetentionType" -Level INFO

    # Verify Tailscale can reach this peer before attempting SMB.
    # This catches mid-job Tailscale disconnections early, with a clear error
    # instead of letting net use hang for 30 s and then fail with a generic OS error.
    if (-not (Test-TailscalePeerReachable -TailscaleIP $peerIP)) {
        Write-Log "Tailscale cannot reach peer $peerLabel ($peerIP) — backup skipped" -Level ERROR
        return $false
    }

    # Connect to peer
    if (-not (Connect-ToPeer -TailscaleIP $peerIP -CustomerCode $customerCode)) {
        Write-Log "Failed to connect to peer: $peerLabel ($peerIP)" -Level ERROR
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
            Write-Log "Backup to $($Peer.Hostname) completed but verification failed! Skipping retention cleanup." -Level WARNING
            $success = $false  # Mark as failed if verification fails
        }
        else {
            Write-Log "Backup to $($Peer.Hostname) completed and verified" -Level SUCCESS
            
            # Apply retention cleanup ONLY after successful AND verified backup
            Invoke-RetentionCleanup -BasePath $basePath -AppName $appName `
                -MonthlyRetention $Job.RetentionMonthly `
                -WeeklyRetention $Job.RetentionWeekly `
                -RecentRetention $Job.RetentionRecent
        }
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
    
    $executionPeers = @(Resolve-ExecutionPeers -Job $Job)
    if ($executionPeers.Count -eq 0) {
        Write-Log "No peers have enough remaining quota for this backup run." -Level ERROR
        return $false
    }
    
    if ($Job.PeerDestinations -and $executionPeers.Count -lt $Job.PeerDestinations.Count) {
        Write-Log "Only $($executionPeers.Count) peer(s) have enough quota for this run; backup will continue with reduced redundancy." -Level WARNING
    }
    
    # Track results
    $totalPeers  = $executionPeers.Count
    $successPeers = 0
    $failedPeers  = @()

    # Backup to each peer
    foreach ($peer in $executionPeers) {
        $peerLabel  = if ($peer.Location) { $peer.Location } elseif ($peer.Hostname) { $peer.Hostname } else { $peer.TailscaleIP }
        $peerFailed = $false

        # For each retention type that applies today
        foreach ($retentionType in $retentionTypes) {
            # Skip monthly/weekly if retention count is 0
            if ($retentionType -eq 'monthly' -and $Job.RetentionMonthly -eq 0) { continue }
            if ($retentionType -eq 'weekly'  -and $Job.RetentionWeekly  -eq 0) { continue }

            $result = Invoke-BackupToPeer -Peer $peer -Job $Job -RetentionType $retentionType
            if ($retentionType -eq 'recent') {
                if ($result) { $successPeers++ } else { $peerFailed = $true }
            }
        }

        if ($peerFailed) { $failedPeers += $peerLabel }
    }

    if ($failedPeers.Count -gt 0) {
        $script:LastBackupError = "Failed on: $($failedPeers -join ', ')"
    }

    Write-Log "Backup completed: $successPeers/$totalPeers peers successful$(if($failedPeers.Count -gt 0){" | Failed: $($failedPeers -join ', ')"})" `
        -Level $(if ($successPeers -gt 0) { 'SUCCESS' } else { 'ERROR' })

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

#region RRM Heartbeat

function Get-DiskSpaceInfo {
    <#
    .SYNOPSIS
        Returns disk stats for the peer's main drive.
        Uses StoragePath drive if configured, falls back to the system drive (C:).
        Also reports the size of the RR backup storage folder when available.
    #>
    $config = Get-RingConfig

    # Determine which drive to report: prefer StoragePath, fall back to system drive
    $storagePath = if ($config -and $config.StoragePath) { $config.StoragePath } else { $null }
    $drivePath   = if ($storagePath) { $storagePath } else { $env:SystemDrive + '\' }

    try {
        $driveLetter = (Split-Path -Qualifier $drivePath -ErrorAction Stop).TrimEnd(':')
        $drive = Get-PSDrive -Name $driveLetter -ErrorAction Stop
        $freeBytes   = [long]$drive.Free
        $usedBytes   = [long]$drive.Used
        $totalBytes  = $freeBytes + $usedBytes
        $freePercent = if ($totalBytes -gt 0) { [math]::Round(($freeBytes / $totalBytes) * 100, 1) } else { 0 }

        if ($freePercent -lt 10) {
            Write-Log "WARNING: Disk space critically low ($freePercent% free on $driveLetter`:)" -Level WARNING
        }

        # Backup folder size — only if StoragePath is configured and exists
        $folderBytes = 0L
        if ($storagePath -and (Test-Path $storagePath)) {
            $measured = Get-ChildItem -Path $storagePath -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue
            if ($measured -and $measured.Sum) { $folderBytes = [long]$measured.Sum }
        }

        return @{
            TotalBytes        = $totalBytes
            FreeBytes         = $freeBytes
            UsedBytes         = $usedBytes
            FreePercent       = $freePercent
            BackupFolderBytes = $folderBytes
        }
    }
    catch {
        Write-Log "Could not read disk space info: $_" -Level WARNING
        return $null
    }
}

function Send-RrmHeartbeat {
    <#
    .SYNOPSIS
        Sends execution result for a single job to the RRM API heartbeat endpoint.
        Updates peer status (online/last_seen), upserts the job, and records the execution.
        Non-fatal  -  failures are logged as warnings only.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$JobName,

        [Parameter(Mandatory=$true)]
        [ValidateSet('Success','Failed','Warning','Running')]
        [string]$Status,

        [Parameter(Mandatory=$true)]
        [string]$RanAt,          # ISO 8601 string  -  start time of the execution

        [int]$DurationSeconds    = 0,
        [long]$SizeBytes         = 0,
        [string]$ErrorMessage    = $null,
        $DiskInfo                = $null   # hashtable from Get-DiskSpaceInfo, optional
    )

    $config = Get-RingConfig
    if (-not $config) {
        Write-Log "RRM heartbeat skipped: no ring-config.json found" -Level INFO
        return
    }

    # Use default URL for peers not yet configured with RRM
    $rrmUrl = if ($config.RrmApiUrl) { $config.RrmApiUrl } else { 'https://rr-api.ait.vlabs.network' }

    # If no ApiKey, attempt registration first so we can send heartbeats
    if (-not $config.RrmApiKey) {
        Write-Log "RRM heartbeat skipped: RrmApiKey not set. Run option M in the menu to register." -Level INFO
        return
    }

    $apiUrl   = $rrmUrl.TrimEnd('/')
    $endpoint = "$apiUrl/api/heartbeat"
    $typeMap  = @{ 'F' = 'file'; 'D' = 'directory'; 'SQL' = 'database' }

    # Load the job definition to send current config alongside the execution
    $job = @(Get-Jobs) | Where-Object { $_.JobName -eq $JobName }
    if (-not $job) {
        Write-Log "RRM heartbeat skipped: job '$JobName' not found in jobs.json" -Level WARNING
        return
    }

    $destinations = @()
    foreach ($dest in @($job.PeerDestinations)) {
        $destinations += @{
            hostname    = $dest.Hostname
            tailscaleIp = $dest.TailscaleIP
            location    = $dest.Location
            basePath    = $dest.BasePath
        }
    }

    $diskPayload = $null
    if ($DiskInfo) {
        $diskPayload = @{
            totalBytes        = $DiskInfo.TotalBytes
            freeBytes         = $DiskInfo.FreeBytes
            freePercent       = $DiskInfo.FreePercent
            backupFolderBytes = $DiskInfo.BackupFolderBytes
        }
    }

    $payload = @{
        hostname  = $config.Hostname
        rrVersion = (Get-LocalRrVersion)
        disk      = $diskPayload
        jobs      = @(
            @{
                name             = $job.JobName
                backupType       = if ($typeMap.ContainsKey($job.BackupType)) { $typeMap[$job.BackupType] } else { $job.BackupType }
                backupObject     = $job.BackupObject
                frequencyHours   = [int]$(if ($job.Frequency -ne $null) { $job.Frequency | Select-Object -First 1 } else { 24 })
                retentionMonthly = [int]$(if ($job.RetentionMonthly -ne $null) { $job.RetentionMonthly | Select-Object -First 1 } else { 3 })
                retentionWeekly  = [int]$(if ($job.RetentionWeekly -ne $null) { $job.RetentionWeekly | Select-Object -First 1 } else { 4 })
                retentionRecent  = [int]$(if ($job.RetentionRecent -ne $null) { $job.RetentionRecent | Select-Object -First 1 } else { 7 })
                enabled          = [bool]($job.Enabled -ne $false)
                lastExecution    = @{
                    status       = $Status.ToLower()
                    ranAt        = $RanAt
                    durationSec  = $DurationSeconds
                    sizeBytes    = $SizeBytes
                    errorMessage = $ErrorMessage
                }
                destinations = $destinations
            }
        )
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod `
            -Uri         $endpoint `
            -Method      POST `
            -Headers     @{ 'X-Api-Key' = $config.RrmApiKey } `
            -Body        $payload `
            -ContentType 'application/json' `
            -TimeoutSec  30 `
            -ErrorAction Stop | Out-Null

        Write-Log "RRM heartbeat OK  -  job='$JobName' status='$Status'" -Level INFO
    }
    catch {
        # Non-fatal: peer keeps working even if the API is unreachable
        Write-Log "RRM heartbeat failed (non-fatal): $_" -Level WARNING
    }
}

#endregion

#region Main

function Invoke-BackupJob {
    param([string]$JobName)

    $startTime = Get-Date
    Write-Log "=== Backup Job Started: $JobName ===" -Level INFO

    $tailscaleSession = Ensure-TailscaleForBackup
    if (-not $tailscaleSession.Ready) {
        Write-Log "Cannot start backup because Tailscale is unavailable: $($tailscaleSession.Reason)" -Level ERROR
        Update-JobStatus -JobName $JobName -Status "Failed" -DurationSeconds 0 -SizeBytes 0
        return $false
    }

    # These are set inside try/catch so the finally block can always write the final status.
    $finalStatus    = 'Failed'
    $durationSeconds = 0
    $sizeBytes       = 0
    $success         = $false

    try {
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
            Write-Log "Job '$JobName' has no destination configured. Add peer destinations via menu option D (Discover peers) or check job settings." -Level ERROR
            return $false
        }

        $durationSeconds = [int]((Get-Date) - $startTime).TotalSeconds
        $finalStatus     = if ($success) { "Success" } else { "Failed" }

        # Send heartbeat to RRM API
        $errorMsg = if (-not $success) { if ($script:LastBackupError) { $script:LastBackupError } else { "Backup failed - check log for details" } } else { $null }
        $diskInfo = Get-DiskSpaceInfo
        Send-RrmHeartbeat `
            -JobName          $JobName `
            -Status           $finalStatus `
            -RanAt            $startTime.ToString('o') `
            -DurationSeconds  $durationSeconds `
            -SizeBytes        $sizeBytes `
            -ErrorMessage     $errorMsg `
            -DiskInfo         $diskInfo

        # After successful backup, enforce ring policies on job master data
        if ($success) {
            Invoke-RingPolicyEnforcement -JobName $JobName
        }

        # Publish status to share for RRM
        Publish-NodeStatus

        return $success
    }
    catch {
        $durationSeconds = [int]((Get-Date) - $startTime).TotalSeconds
        $finalStatus     = 'Failed'
        Write-Log "Unhandled error in backup job '$JobName': $_" -Level ERROR
        Send-RrmHeartbeat -JobName $JobName -Status $finalStatus -RanAt $startTime.ToString('o') `
            -DurationSeconds $durationSeconds -SizeBytes $sizeBytes -ErrorMessage $script:LastBackupError `
            -DiskInfo (Get-DiskSpaceInfo)
    }
    finally {
        # Always write the final status — even if the job crashed or was interrupted.
        Update-JobStatus -JobName $JobName -Status $finalStatus -DurationSeconds $durationSeconds -SizeBytes $sizeBytes
        Write-Log "=== Backup Job Completed: $JobName - $finalStatus (${durationSeconds}s) ===" -Level $(if ($finalStatus -eq 'Success') { 'SUCCESS' } else { 'ERROR' })
        Restore-TailscaleAfterBackup -Session $tailscaleSession
    }
}

# Main entry point
try {
    if (-not (Test-Path $LogPath)) {
        New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
    }

    # -UpdateOnly mode: just check/apply update and exit — no backup
    if ($UpdateOnly) {
        if (-not $SkipUpdateCheck) {
            Invoke-AutoUpdate
        }
        # Also ensure the scheduled task exists (this is where it gets installed
        # on peers that updated but haven't run a job yet)
        Ensure-AutoUpdateTask
        Write-Log "UpdateOnly: already on latest version $(Get-LocalRrVersion)" -Level INFO
        exit 0
    }

    # Normal mode: require -JobName
    if (-not $JobName) {
        Write-Error "JobName is required unless -UpdateOnly is specified."
        exit 1
    }

    # Auto-update: check for new version and re-launch if updated
    if (-not $SkipUpdateCheck) {
        Invoke-AutoUpdate
    }

    # Ensure the hourly auto-update task exists (registers silently if missing)
    Ensure-AutoUpdateTask

    # Migrate old RRM URL to new server if needed
    Invoke-RrmUrlMigration

    $result = Invoke-BackupJob -JobName $JobName
    exit $(if ($result) { 0 } else { 1 })
}
catch {
    Write-Log "Fatal error: $_" -Level ERROR
    exit 1
}
