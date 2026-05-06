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

    # Run only the auto-update check and exit  -  no backup job
    [switch]$UpdateOnly,

    # Send heartbeat for all jobs with known status and exit  -  no backup job
    [switch]$HeartbeatOnly
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
$script:OldRrmUrl  = 'https://rr-api.ait.vlabs.network'
$script:NewRrmUrl  = 'https://mercury.velociraptor-hoki.ts.net'

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
    # Try the script's own directory first ($PSScriptRoot via $script:InstallPath).
    # If that path is empty (e.g. task launched with -Command instead of -File),
    # fall back to the known install locations so we always find version.txt.
    $candidates = @(
        $script:InstallPath,
        'C:\VLABS_ResilienceRing',
        'C:\VLABS_resiliencering',
        'C:\vlabs_resiliencering'
    ) | Where-Object { $_ -ne '' -and $_ -ne $null }

    foreach ($dir in $candidates) {
        $versionFile = Join-Path $dir 'version.txt'
        if (Test-Path $versionFile) { return (Get-Content $versionFile -Raw).Trim() }
    }
    return $null
}

function Invoke-AutoUpdate {
    try {
        # Try GitHub Contents API first (no CDN caching).
        # Fall back to raw.githubusercontent.com in case the API is firewalled.
        $latestVersion = $null
        $currentVersion = Get-LocalRrVersion

        try {
            $versionUrl  = "https://api.github.com/repos/$script:RepoOwner/$script:RepoName/contents/version.txt?ref=$script:RepoBranch"
            $apiResponse = Invoke-RestMethod -Uri $versionUrl -UseBasicParsing -TimeoutSec 10 `
                               -Headers @{ 'Accept' = 'application/vnd.github.v3+json'; 'User-Agent' = 'RR-AutoUpdate' }
            $latestVersion = [System.Text.Encoding]::UTF8.GetString(
                                 [System.Convert]::FromBase64String(
                                     ($apiResponse.content -replace "`n","" -replace "`r","")
                                 )).Trim()
        }
        catch {
            Write-Log "Auto-update: GitHub API unreachable ($_), trying raw URL..." -Level WARNING
        }

        if (-not $latestVersion) {
            try {
                $rawUrl        = "https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/version.txt"
                $latestVersion = (Invoke-RestMethod -Uri $rawUrl -UseBasicParsing -TimeoutSec 10).Trim()
            }
            catch {
                Write-Log "Auto-update: version check failed (raw URL also unreachable): $_" -Level WARNING
                return
            }
        }

        Write-Log "Auto-update: current=$currentVersion  latest=$latestVersion" -Level INFO

        # Only skip if we know the local version AND it is already current.
        # If $currentVersion is null (version.txt unreadable) we MUST update --
        # skipping would leave the peer stuck forever on an unknown version.
        if ($currentVersion -ne $null -and [Version]$latestVersion -le [Version]$currentVersion) {
            Write-Log "Auto-update: already up to date ($currentVersion)" -Level INFO
            return
        }
        if ($null -eq $currentVersion) {
            Write-Log "Auto-update: local version unreadable -- forcing update to $latestVersion" -Level WARNING
        }

        Write-Log "Auto-update: new version available ($currentVersion -> $latestVersion). Updating..." -Level INFO

        $gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
        $gitRepo = Test-Path (Join-Path $script:InstallPath '.git')

        if ($gitAvailable -and $gitRepo) {
            $gitTimeout = 60
            foreach ($gitArgs in @("fetch origin $script:RepoBranch", "reset --hard origin/$script:RepoBranch")) {
                $proc = Start-Process -FilePath "git" -ArgumentList $gitArgs `
                            -WorkingDirectory $script:InstallPath `
                            -NoNewWindow -PassThru -ErrorAction SilentlyContinue
                if ($proc -and -not $proc.WaitForExit($gitTimeout * 1000)) {
                    $proc.Kill()
                    Write-Log "Auto-update: git timed out  -  skipping update" -Level WARNING
                    return
                }
            }
        }
        else {
            # Download files one-by-one via GitHub Contents API.
            # This is far more reliable than a ZIP archive download because:
            #   - Each file is small (< 100 KB) with its own 30-second timeout
            #   - No ZIP extraction step that can fail or hang
            #   - Works even when bulk archive downloads are blocked by firewalls
            Write-Log "Auto-update: downloading files via GitHub API..." -Level INFO

            $contentsUrl = "https://api.github.com/repos/$script:RepoOwner/$script:RepoName/contents?ref=$script:RepoBranch"
            $fileList    = Invoke-RestMethod -Uri $contentsUrl -UseBasicParsing -TimeoutSec 15 `
                               -Headers @{ 'Accept' = 'application/vnd.github.v3+json'; 'User-Agent' = 'RR-AutoUpdate' }

            $downloaded = 0
            $failed     = 0
            foreach ($item in ($fileList | Where-Object { $_.type -eq 'file' -and $_.download_url })) {
                try {
                    $destPath = Join-Path $script:InstallPath $item.name
                    if ($item.name -match '\.ps1$') {
                        # PS1 files must be saved as UTF-16 LE with BOM so Windows
                        # PowerShell 5.1 parses them correctly (avoids parse errors
                        # with subexpressions like $($var.Property) inside strings).
                        # Download to a temp file first (avoids PS5.1 Content type issues)
                        $tmpPath = $destPath + '.tmp'
                        Invoke-WebRequest -Uri $item.download_url -UseBasicParsing -TimeoutSec 30 -OutFile $tmpPath
                        $text    = [System.IO.File]::ReadAllText($tmpPath, [System.Text.Encoding]::UTF8)
                        $utf16Le = [System.Text.Encoding]::Unicode
                        $bom     = $utf16Le.GetPreamble()
                        $bytes   = $utf16Le.GetBytes($text)
                        $all     = New-Object byte[] ($bom.Length + $bytes.Length)
                        [System.Buffer]::BlockCopy($bom,   0, $all, 0,           $bom.Length)
                        [System.Buffer]::BlockCopy($bytes, 0, $all, $bom.Length, $bytes.Length)
                        [System.IO.File]::WriteAllBytes($destPath, $all)
                        Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
                    } else {
                        Invoke-WebRequest -Uri $item.download_url -UseBasicParsing -TimeoutSec 30 -OutFile $destPath
                    }
                    $downloaded++
                }
                catch {
                    Write-Log "Auto-update: failed to download $($item.name): $_" -Level WARNING
                    $failed++
                }
            }

            if ($downloaded -eq 0) {
                Write-Log "Auto-update: no files downloaded  -  skipping update" -Level WARNING
                return
            }
            Write-Log "Auto-update: $downloaded file(s) downloaded, $failed failed" -Level INFO
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

function Repair-Ps1Encodings {
    # Self-healing: ensure every .ps1 file in the install directory is UTF-16 LE with BOM.
    # Peers that auto-updated while running an old Execute-Backup.ps1 (without the UTF-16
    # conversion code) ended up with UTF-8 files, which cause Windows PowerShell 5.1 parse
    # errors on subexpressions like $($var.Property) inside strings.
    # This function silently re-encodes any such files so they work correctly.
    try {
        $ps1Files = Get-ChildItem -Path $script:InstallPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue
        foreach ($file in $ps1Files) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
                # Skip files that already have UTF-16 LE BOM (FF FE)
                if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { continue }
                # Re-read as UTF-8 and save as UTF-16 LE with BOM
                $text    = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
                $utf16Le = [System.Text.Encoding]::Unicode
                $bom     = $utf16Le.GetPreamble()
                $encoded = $utf16Le.GetBytes($text)
                $all     = New-Object byte[] ($bom.Length + $encoded.Length)
                [System.Buffer]::BlockCopy($bom,     0, $all, 0,           $bom.Length)
                [System.Buffer]::BlockCopy($encoded, 0, $all, $bom.Length, $encoded.Length)
                [System.IO.File]::WriteAllBytes($file.FullName, $all)
                Write-Log "Repair-Ps1Encodings: re-encoded $($file.Name) to UTF-16 LE" -Level INFO
            }
            catch {
                Write-Log "Repair-Ps1Encodings: could not re-encode $($file.Name): $_" -Level WARNING
            }
        }
    }
    catch {
        Write-Log "Repair-Ps1Encodings failed (non-fatal): $_" -Level WARNING
    }
}

function Ensure-AutoUpdateTask {
    # Registers (or repairs) the RR-AutoUpdate scheduled task.
    # Always uses SYSTEM as the principal so the task works regardless of
    # which user account triggered the backup job.
    # Called on every job run so peers that never open the menu still get it.
    $taskName = "RR-AutoUpdate"
    try {
        # Resolve the script file using the same fallback logic as Get-LocalRrVersion
        # so Ensure-AutoUpdateTask works even when $PSScriptRoot is empty.
        $scriptFile = $null
        foreach ($dir in @($script:InstallPath, 'C:\VLABS_ResilienceRing', 'C:\VLABS_resiliencering', 'C:\vlabs_resiliencering') | Where-Object { $_ }) {
            $candidate = Join-Path $dir 'Execute-Backup.ps1'
            if (Test-Path $candidate) { $scriptFile = $candidate; break }
        }
        if (-not $scriptFile) { return }

        # Check whether the existing task is already configured correctly.
        # If it runs as a non-SYSTEM account it will fail when no user is
        # logged in, so we recreate it in that case.
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            $principalId = $existing.Principal.UserId
            if ($principalId -match 'SYSTEM') { return }   # already correct  -  nothing to do
            # Task exists but with wrong principal  -  remove and recreate
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log "Re-registering $taskName with SYSTEM principal (was: $principalId)" -Level INFO
        }

        $action = New-ScheduledTaskAction `
            -Execute "PowerShell.exe" `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptFile`" -UpdateOnly"

        # First run in 1 hour (the current backup run already checked for updates).
        # RepetitionDuration 9999 days ~ forever.
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(1) `
            -RepetitionInterval (New-TimeSpan -Hours 1) `
            -RepetitionDuration (New-TimeSpan -Days 9999)

        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
            -MultipleInstances IgnoreNew

        Register-ScheduledTask -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "VLABS Resilience Ring - hourly auto-update check" `
            -ErrorAction Stop | Out-Null

        Write-Log "Registered scheduled task: $taskName (hourly, SYSTEM, hidden)" -Level INFO
    }
    catch {
        Write-Log "Could not register auto-update task (non-fatal): $_" -Level WARNING
    }
}

function Invoke-RrmUrlMigration {
    # Silently migrate any known old/test RRM URL to the current production server
    $legacyUrls = @(
        'https://rr-api.ait.vlabs.network',
        'https://api-test.mmi.lat/resilience-ring',
        'https://api-test.mmi.lat'
    )
    try {
        $configFile = Join-Path $script:ConfigPath 'ring-config.json'
        if (-not (Test-Path $configFile)) { return }
        $config = Get-Content $configFile -Raw | ConvertFrom-Json
        if ($config.RrmApiUrl -in $legacyUrls) {
            $config.RrmApiUrl = $script:NewRrmUrl
            $config | ConvertTo-Json -Depth 10 | Set-Content $configFile -Encoding UTF8
            Write-Log "Auto-migration: RrmApiUrl updated from $($config.RrmApiUrl) to $script:NewRrmUrl" -Level INFO
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

    if (-not (Test-Path $BasePath)) { return [int64]0 }

    $allFolders = Get-ChildItem -Path $BasePath -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "$AppName-*" } |
                  Sort-Object Name -Descending

    # Separate by type
    $monthlyFolders = $allFolders | Where-Object { $_.Name -match '-monthly$' }
    $weeklyFolders  = $allFolders | Where-Object { $_.Name -match '-weekly$' }
    $recentFolders  = $allFolders | Where-Object { $_.Name -notmatch '-(monthly|weekly)$' }

    # Helper: measure a folder then delete it; returns its byte count.
    $deletedBytes = [int64]0
    $deleteFolder = {
        param($folder)
        $bytes = (Get-ChildItem $folder.FullName -Recurse -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        Remove-Item -Path $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $bytesOut = [int64]0
        if ($bytes) { $bytesOut = [int64]$bytes }
        return $bytesOut
    }

    # Delete excess monthly (0 = delete all monthly)
    if ($monthlyFolders.Count -gt $MonthlyRetention) {
        foreach ($folder in ($monthlyFolders | Select-Object -Skip $MonthlyRetention)) {
            Write-Log "Deleting old monthly backup: $($folder.Name)" -Level INFO
            $deletedBytes += & $deleteFolder $folder
        }
    }

    # Delete excess weekly (0 = delete all weekly)
    if ($weeklyFolders.Count -gt $WeeklyRetention) {
        foreach ($folder in ($weeklyFolders | Select-Object -Skip $WeeklyRetention)) {
            Write-Log "Deleting old weekly backup: $($folder.Name)" -Level INFO
            $deletedBytes += & $deleteFolder $folder
        }
    }

    # Delete excess recent (always >= 1)
    if ($recentFolders.Count -gt $RecentRetention) {
        foreach ($folder in ($recentFolders | Select-Object -Skip $RecentRetention)) {
            Write-Log "Deleting old recent backup: $($folder.Name)" -Level INFO
            $deletedBytes += & $deleteFolder $folder
        }
    }

    Write-Log "Retention cleanup completed -- freed $([math]::Round($deletedBytes/1MB,1)) MB" -Level SUCCESS
    return $deletedBytes
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

function Write-BackupManifest {
    <#
    .SYNOPSIS
        Writes a SHA256 checksum manifest alongside a completed backup folder
    .DESCRIPTION
        Creates _manifest.sha256 inside the backup folder.
        Format: "SHA256HASH  relative\path\to\file" (one line per file).
        Used later by Test-ManifestIntegrity to verify the backup before a restore.
    #>
    param(
        [string]$BackupPath
    )

    $manifestPath = Join-Path $BackupPath "_manifest.sha256"

    try {
        $files = Get-ChildItem -Path $BackupPath -File -Recurse -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -ne '_manifest.sha256' } |
                 Sort-Object FullName

        $lines = @(foreach ($file in $files) {
            $hash = (Get-FileHash -Path $file.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
            if ($hash) {
                $relativePath = $file.FullName.Substring($BackupPath.Length).TrimStart('\')
                "$hash  $relativePath"
            }
        })

        $lines | Set-Content -Path $manifestPath -Encoding UTF8 -ErrorAction Stop
        Write-Log "Manifest written: $($lines.Count) file(s)  -  $(Split-Path $BackupPath -Leaf)" -Level INFO
    }
    catch {
        Write-Log "Could not write manifest for $(Split-Path $BackupPath -Leaf): $_" -Level WARNING
    }
}

function Test-ManifestIntegrity {
    <#
    .SYNOPSIS
        Verifies a backup folder's contents against its _manifest.sha256 file
    .OUTPUTS
        $true   -  all files present and checksums match
        $false  -  one or more files missing or corrupt
        $null   -  no manifest exists (backup predates the manifest feature)
    #>
    param([string]$BackupPath)

    $manifestPath = Join-Path $BackupPath "_manifest.sha256"

    if (-not (Test-Path $manifestPath -PathType Leaf)) {
        return $null
    }

    $entries = @(Get-Content $manifestPath -ErrorAction SilentlyContinue |
                 Where-Object { $_ -match '^[0-9A-Fa-f]{64}\s+\S' })

    if ($entries.Count -eq 0) {
        Write-Log "Manifest is empty or unreadable: $manifestPath" -Level WARNING
        return $null
    }

    $failures = 0

    foreach ($line in $entries) {
        $parts    = $line -split '\s+', 2
        $expected = $parts[0].ToUpper()
        $relPath  = $parts[1]
        $filePath = Join-Path $BackupPath $relPath

        if (-not (Test-Path $filePath -PathType Leaf)) {
            Write-Log "MISSING: $relPath" -Level ERROR
            $failures++
            continue
        }

        $actual = (Get-FileHash -Path $filePath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        if ($actual -ne $expected) {
            Write-Log "CORRUPT: $relPath (expected $expected, got $actual)" -Level ERROR
            $failures++
        }
    }

    $folderLabel = Split-Path $BackupPath -Leaf
    if ($failures -eq 0) {
        Write-Log "Manifest OK: $($entries.Count) file(s) verified  -  $folderLabel" -Level SUCCESS
        return $true
    }
    else {
        Write-Log "Manifest FAILED: $failures/$($entries.Count) file(s) corrupt or missing  -  $folderLabel" -Level ERROR
        return $false
    }
}

function Get-RobocopyExitDescription {
    <#
    .SYNOPSIS
        Returns a human-readable description for a robocopy exit code.
        Codes 0-7 are success (bit flags); 8+ indicate errors.
    #>
    param([int]$ExitCode)
    if ($ExitCode -ge 16) { return "FATAL ERROR  -  robocopy terminated abnormally" }
    if ($ExitCode -ge 8)  { return "FAILURE  -  some files/directories could not be copied" }
    if ($ExitCode -eq 0)  { return "No change  -  destination already up to date" }
    $flags = @()
    if ($ExitCode -band 1) { $flags += "new/changed files copied" }
    if ($ExitCode -band 2) { $flags += "extra files/dirs found in destination" }
    if ($ExitCode -band 4) { $flags += "mismatched files/dirs" }
    return ($flags -join '; ')
}

function Read-RobocopyLogSummary {
    <#
    .SYNOPSIS
        Parses the summary footer of a robocopy /LOG: file and returns
        structured stats (files copied, bytes, speed, elapsed time).
    #>
    param([string]$LogPath)
    if (-not (Test-Path $LogPath -PathType Leaf)) { return $null }
    try {
        # Only read the last 30 lines  -  the summary is always at the end
        $lines = Get-Content $LogPath -Tail 30 -ErrorAction SilentlyContinue
        $result = @{}
        foreach ($line in $lines) {
            if ($line -match '^\s*Files\s*:\s*([\d,]+)\s+([\d,]+)') {
                $result.TotalFiles  = ($Matches[1] -replace ',','')
                $result.CopiedFiles = ($Matches[2] -replace ',','')
            }
            if ($line -match '^\s*Bytes\s*:\s*(\S+)\s+(\S+)') {
                $result.TotalBytes  = $Matches[1]
                $result.CopiedBytes = $Matches[2]
            }
            if ($line -match '^\s*Times\s*:\s*(\S+)') {
                $result.Elapsed = $Matches[1]
            }
            if ($line -match '^\s*Speed\s*:\s*([\d,]+)\s+Bytes/sec') {
                $speedBps          = [long]($Matches[1] -replace ',','')
                $result.SpeedMBps  = [math]::Round($speedBps / 1MB, 1)
            }
        }
        if ($result.TotalFiles -ne $null) { return [PSCustomObject]$result }
        return $null
    }
    catch { return $null }
}

#endregion

#region Tailscale Session

function Invoke-TailscaleViaSystem {
    <#
    .SYNOPSIS
        Runs a tailscale command via a one-shot SYSTEM scheduled task.
        Fallback for when direct invocation fails with 401 (daemon runs as a
        different local user account and rejects connections from this process).
    #>
    param(
        [string]$TailscaleExe,
        [string]$Arguments,
        [int]$TimeoutSeconds = 20
    )
    $tempTaskName = "RR-TailscaleOp-Temp"
    try {
        $action    = New-ScheduledTaskAction -Execute $TailscaleExe -Argument $Arguments
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
        Register-ScheduledTask -TaskName $tempTaskName -Action $action `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $tempTaskName -ErrorAction Stop
        $waited = 0
        while ($waited -lt $TimeoutSeconds) {
            Start-Sleep -Seconds 1
            $waited++
            $info = Get-ScheduledTaskInfo -TaskName $tempTaskName -ErrorAction SilentlyContinue
            if ($info -and $info.LastTaskResult -ne 267009) { break }
        }
        return $true
    }
    catch {
        Write-Log "Invoke-TailscaleViaSystem ('$Arguments') failed: $_" -Level WARNING
        return $false
    }
    finally {
        Unregister-ScheduledTask -TaskName $tempTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

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
        Write-Log "Tailscale is already connected" -Level INFO
        $result.Ready = $true
        if ($result.Mode -eq 'PerJob') {
            $result.StartedByJob = $true
        }
        return $result
    }

    Write-Log "Tailscale is disconnected -- bringing it up for this backup job..." -Level INFO
    $upTimeoutMs = 30000
    $upExitCode  = -1
    $upOutput    = ""
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $tailscaleExe
        $psi.Arguments              = "up"
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true

        $upProc = [System.Diagnostics.Process]::Start($psi)
        if (-not $upProc) { throw "failed to start tailscale up process" }

        $stdoutTask = $upProc.StandardOutput.ReadToEndAsync()
        $stderrTask = $upProc.StandardError.ReadToEndAsync()

        if (-not $upProc.WaitForExit($upTimeoutMs)) {
            try { $upProc.Kill() } catch {}
            $upProc.Dispose()
            Write-Log "tailscale up timed out after 30s -- node may need re-authentication" -Level ERROR
            $result.Reason = "tailscale up timed out (re-auth required?)"
            return $result
        }

        $upExitCode = $upProc.ExitCode
        $upOutput   = ($stdoutTask.Result + " " + $stderrTask.Result).Trim()
        $upProc.Dispose()
    }
    catch {
        Write-Log "tailscale up exception: $_" -Level ERROR
        $result.Reason = "tailscale up exception: $_"
        return $result
    }

    if ($upOutput) { Write-Log "tailscale up output: $upOutput" -Level INFO }

    if ($upExitCode -ne 0) {
        Write-Log "tailscale up failed with exit code: $upExitCode" -Level ERROR
        # 401 means the daemon is running as a different local user -- retry via SYSTEM task
        if ($upOutput -match '401') {
            Write-Log "Detected 401 (daemon user mismatch) -- retrying tailscale up via SYSTEM scheduled task..." -Level INFO
            $sysOk = Invoke-TailscaleViaSystem -TailscaleExe $tailscaleExe -Arguments "up" -TimeoutSeconds 20
            if (-not $sysOk) {
                $result.Reason = "tailscale up failed (exit $upExitCode); SYSTEM task fallback also failed"
                return $result
            }
            # Fall through to connection-state poll below
        } else {
            $result.Reason = "tailscale up failed (exit $upExitCode)"
            return $result
        }
    }

    Write-Log "Waiting for Tailscale to reach connected state..." -Level INFO
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        Start-Sleep -Seconds 1
        $tsStatus = Test-TailscaleInstalled
        if ($tsStatus.Connected) {
            Write-Log "Tailscale connected successfully -- waiting 3s for route propagation..." -Level INFO
            Start-Sleep -Seconds 3
            $result.Ready = $true
            $result.StartedByJob = $true
            return $result
        }
    }

    Write-Log "Tailscale did not reach connected state after 10 seconds" -Level ERROR
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
    
    Write-Log "Disconnecting Tailscale after backup job completion..." -Level INFO
    $downOut = (& $tailscaleExe down 2>&1) -join " "
    if ($downOut -match '401') {
        Write-Log "tailscale down got 401 -- retrying via SYSTEM scheduled task..." -Level INFO
        Invoke-TailscaleViaSystem -TailscaleExe $tailscaleExe -Arguments "down" -TimeoutSeconds 15 | Out-Null
    }
    Write-Log "Tailscale disconnected" -Level INFO
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
    if ($existing) {
        Write-Log "SMB share already connected: $sharePath" -Level INFO
        return $true
    }

    Write-Log "Connecting to SMB share: $sharePath" -Level INFO

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
        Write-Log "SMB connection timed out after ${TimeoutSeconds}s: $sharePath" -Level ERROR
        return $false
    }

    $exitCode = Receive-Job -Job $connectJob
    Remove-Job -Job $connectJob -Force -ErrorAction SilentlyContinue
    if ($exitCode -eq 0) {
        Write-Log "SMB share connected: $sharePath" -Level INFO
    } else {
        Write-Log "SMB connection failed (net use exit $exitCode): $sharePath" -Level ERROR
    }
    return ($exitCode -eq 0)
}

function Disconnect-FromPeer {
    param([string]$TailscaleIP)
    
    $sharePath = "\\$TailscaleIP\RR_Backups"
    net use $sharePath /delete 2>$null | Out-Null
}

#endregion

#region Usage Cache
# A single file ".rr-usage" at the share root stores the last known total bytes.
# Reading it is instant (one network file read) vs. scanning the whole share.
# The cache is written after every backup with an incremental delta so it never
# needs a full rescan after the first time.

function Get-ShareUsageCachePath {
    param([string]$TailscaleIP)
    return "\\$TailscaleIP\$(Get-RRShareName)\.rr-usage"
}

function Read-PeerUsageCache {
    param([string]$TailscaleIP)
    $path = Get-ShareUsageCachePath -TailscaleIP $TailscaleIP
    try {
        if (Test-Path $path -ErrorAction SilentlyContinue) {
            $val = (Get-Content $path -Raw -ErrorAction Stop).Trim()
            if ($val -match '^\d+$') { return [int64]$val }
        }
    } catch {}
    return $null
}

function Write-PeerUsageCache {
    param([string]$TailscaleIP, [int64]$Bytes)
    $path = Get-ShareUsageCachePath -TailscaleIP $TailscaleIP
    try {
        [string]$Bytes | Set-Content $path -Force -ErrorAction SilentlyContinue
    } catch {}
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
        [string]$CustomerCode,
        [int]$TimeoutSeconds = 60
    )

    $sharePath = "\\$TailscaleIP\$(Get-RRShareName)"

    try {
        $connected = Connect-ToPeer -TailscaleIP $TailscaleIP -CustomerCode $CustomerCode
        if (-not $connected) { return $null }

        # Fast path: read cached value written by the last backup (single file, instant).
        $cached = Read-PeerUsageCache -TailscaleIP $TailscaleIP
        if ($null -ne $cached) {
            Write-Log "Peer ${TailscaleIP}: quota usage from cache -- $([math]::Round($cached/1GB,2)) GB" -Level INFO
            return $cached
        }

        # No cache yet: full recursive scan (slow, runs only the very first time).
        # Result is written to .rr-usage so future runs use the fast path.
        Write-Log "Peer ${TailscaleIP}: no usage cache found -- running initial full scan (one-time)" -Level INFO

        if (-not (Test-Path $sharePath)) { return [int64]0 }

        $scanJob = Start-Job -ScriptBlock {
            param($path)
            (Get-ChildItem $path -Recurse -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        } -ArgumentList $sharePath

        $finished = Wait-Job -Job $scanJob -Timeout $TimeoutSeconds
        if (-not $finished) {
            Stop-Job  -Job $scanJob -ErrorAction SilentlyContinue
            Remove-Job -Job $scanJob -Force -ErrorAction SilentlyContinue
            Write-Log "Initial usage scan timed out for peer $TailscaleIP after ${TimeoutSeconds}s -- quota check skipped" -Level WARNING
            return $null
        }

        $usedBytes = Receive-Job -Job $scanJob
        Remove-Job -Job $scanJob -Force -ErrorAction SilentlyContinue
        $result = [int64](if ($usedBytes) { $usedBytes } else { 0 })

        Write-PeerUsageCache -TailscaleIP $TailscaleIP -Bytes $result
        Write-Log "Peer ${TailscaleIP}: initial usage scan complete -- $([math]::Round($result/1GB,2)) GB, cache written" -Level INFO
        return $result
    }
    catch { return $null }
    finally { Disconnect-FromPeer -TailscaleIP $TailscaleIP }
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
    
    $appName = $Job.JobName
    if ($Job.AppName) { $appName = $Job.AppName }
    if ($Job.AppNameClean) { $appName = $Job.AppNameClean }
    $location = (Get-RingConfig).Location
    if ($Job.SourceLocation) { $location = $Job.SourceLocation }
    $customerCode = (Get-RingConfig).CustomerCode
    if ($Job.CustomerCode) { $customerCode = $Job.CustomerCode }
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
        Write-Log "Could not determine current usage for peer $($Peer.Hostname); allowing backup without quota check." -Level WARNING
        return [PSCustomObject]@{
            Allowed = $true
            Descriptor = (New-PeerExecutionDescriptor -Peer $Peer -Job $Job -QuotaGB $quotaGB)
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
    
    $availablePeers = try { @(Get-AvailableStoragePeers) } catch { @() }
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
    $basePath = $Peer.SharePath
    if ($Peer.BasePath) { $basePath = $Peer.BasePath }
    # Fallback chain for app name: AppNameClean -> AppName -> JobName
    $appName = $Job.JobName
    if ($Job.AppName) { $appName = $Job.AppName }
    if ($Job.AppNameClean) { $appName = $Job.AppNameClean }
    # CustomerCode from job, or fall back to ring-config
    $customerCode = (Get-RingConfig).CustomerCode
    if ($Job.CustomerCode) { $customerCode = $Job.CustomerCode }

    $peerLabel = $peerIP
    if ($Peer.Hostname) { $peerLabel = $Peer.Hostname }
    if ($Peer.Location) { $peerLabel = $Peer.Location }
    Write-Log "--- Peer: $peerLabel ($peerIP) | Type: $RetentionType ---" -Level INFO

    Write-Log "Verifying Tailscale connectivity to $peerLabel ($peerIP)..." -Level INFO
    if (-not (Test-TailscalePeerReachable -TailscaleIP $peerIP)) {
        Write-Log "Tailscale cannot reach peer $peerLabel ($peerIP) -- backup skipped" -Level ERROR
        return $false
    }
    Write-Log "Tailscale ping OK: $peerLabel ($peerIP)" -Level INFO

    if (-not (Connect-ToPeer -TailscaleIP $peerIP -CustomerCode $customerCode)) {
        Write-Log "Failed to connect to SMB share on peer: $peerLabel ($peerIP)" -Level ERROR
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
    
    # -- Source size -------------------------------------------------------------
    try {
        if ($Job.BackupType -eq 'F') {
            $srcItem      = Get-Item $Job.BackupObject -ErrorAction SilentlyContinue
            $srcCount     = if ($srcItem) { 1 } else { 0 }
            $srcBytes     = if ($srcItem) { $srcItem.Length } else { 0 }
        }
        else {
            $srcItems = @(Get-ChildItem $Job.BackupObject -Recurse -File -ErrorAction SilentlyContinue)
            $srcCount = $srcItems.Count
            $srcBytes = ($srcItems | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if (-not $srcBytes) { $srcBytes = 0 }
        }
        $srcSizeGB   = [math]::Round($srcBytes / 1GB, 2)
        $srcSizeMB   = [math]::Round($srcBytes / 1MB, 1)
        $sizeDisplay = if ($srcSizeGB -ge 1) { "$srcSizeGB GB" } else { "$srcSizeMB MB" }
        Write-Log "Source: $($Job.BackupObject)  -  $srcCount file(s), $sizeDisplay" -Level INFO
    }
    catch {
        Write-Log "Could not measure source size: $_" -Level WARNING
    }

    # -- Robocopy -----------------------------------------------------------------
    Write-Log "Running robocopy: $($Job.BackupObject) -> $destPath" -Level INFO
    $peerStartTime = Get-Date
    $exitCode      = -1

    try {
        # Use ProcessStartInfo with UseShellExecute=$false so the OS process handle
        # stays open until we explicitly read ExitCode.  Start-Process -NoNewWindow
        # can silently close the handle before ExitCode is populated on some PS 5.1
        # builds, leaving proc.ExitCode as $null even after WaitForExit returns.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = "robocopy"
        $psi.Arguments       = $robocopyArgs -join ' '
        $psi.UseShellExecute = $false   # keep handle open; do not go through shell
        $psi.CreateNoWindow  = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) { throw "robocopy process failed to start" }

        while (-not $proc.WaitForExit(60000)) {
            $elapsed = [int]((Get-Date) - $peerStartTime).TotalMinutes
            Write-Log "Robocopy running  -  ${elapsed} min elapsed ($peerLabel)" -Level INFO
        }
        $exitCode = $proc.ExitCode
        $proc.Dispose()
        if ($null -eq $exitCode) {
            Write-Log "Warning: proc.ExitCode is still null - defaulting to -1" -Level WARNING
            $exitCode = -1
        }
    }
    catch {
        Write-Log "Robocopy exception: $_" -Level ERROR
        return $false
    }

    $peerDuration = [int]((Get-Date) - $peerStartTime).TotalSeconds
    $exitDesc     = Get-RobocopyExitDescription -ExitCode $exitCode
    Write-Log "Robocopy finished in ${peerDuration}s  -  exit code $exitCode ($exitDesc)" -Level INFO

    # Parse robocopy log for detailed transfer stats
    $summary = Read-RobocopyLogSummary -LogPath $robocopyLog
    if ($summary) {
        $parts = @()
        if ($summary.CopiedFiles -ne $null) { $parts += "files: $($summary.CopiedFiles)/$($summary.TotalFiles) copied" }
        if ($summary.CopiedBytes)           { $parts += "bytes: $($summary.CopiedBytes)/$($summary.TotalBytes)" }
        if ($summary.SpeedMBps -ne $null)   { $parts += "speed: $($summary.SpeedMBps) MB/s" }
        if ($summary.Elapsed)               { $parts += "elapsed: $($summary.Elapsed)" }
        if ($parts.Count -gt 0) {
            Write-Log "Robocopy stats: $($parts -join ' | ')" -Level INFO
        }
    }

    $success = ($exitCode -ge 0 -and $exitCode -le 7)
    
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

            # Write SHA256 manifest so integrity can be re-verified at restore time
            Write-BackupManifest -BackupPath $destPath

            # Apply retention cleanup ONLY after successful AND verified backup.
            # Capture bytes freed so we can update the usage cache accurately.
            $retentionFreedBytes = Invoke-RetentionCleanup -BasePath $basePath -AppName $appName `
                -MonthlyRetention $Job.RetentionMonthly `
                -WeeklyRetention $Job.RetentionWeekly `
                -RecentRetention $Job.RetentionRecent

            # Update .rr-usage cache: old + bytes_written - bytes_freed_by_retention.
            # srcBytes is the source size (= what was just written to destPath).
            # Using cached old value avoids a full rescan of the share.
            $oldCache = Read-PeerUsageCache -TailscaleIP $peerIP
            if ($null -ne $oldCache) {
                $writtenBytes  = if ($srcBytes) { [int64]$srcBytes } else { [int64]0 }
                $newCache      = [math]::Max(0, $oldCache + $writtenBytes - $retentionFreedBytes)
                Write-PeerUsageCache -TailscaleIP $peerIP -Bytes $newCache
                Write-Log "Usage cache updated: $([math]::Round($oldCache/1GB,2)) GB + $([math]::Round($writtenBytes/1MB,1)) MB written - $([math]::Round($retentionFreedBytes/1MB,1)) MB freed = $([math]::Round($newCache/1GB,2)) GB" -Level INFO
            }
        }
    }
    else {
        Write-Log "Robocopy failed with exit code: $exitCode" -Level ERROR
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
        $peerLabel = $peer.TailscaleIP
        if ($peer.Hostname) { $peerLabel = $peer.Hostname }
        if ($peer.Location) { $peerLabel = $peer.Location }
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

    # StoragePath may be a UNC path (\\peer\share\...) - always report the local
    # system drive for disk stats. UNC paths have no drive letter so Get-PSDrive
    # would fail. BackupFolderBytes is only populated when StoragePath is local.
    $storagePath = if ($config -and $config.StoragePath) { $config.StoragePath } else { $null }
    $isUncStorage = $storagePath -and $storagePath.StartsWith('\\')

    # Always measure the local system drive
    $localDrive = $env:SystemDrive.TrimEnd(':')   # e.g. "C"

    try {
        $drive = Get-PSDrive -Name $localDrive -ErrorAction Stop
        $freeBytes   = [long]$drive.Free
        $usedBytes   = [long]$drive.Used
        $totalBytes  = $freeBytes + $usedBytes
        $freePercent = if ($totalBytes -gt 0) { [math]::Round(($freeBytes / $totalBytes) * 100, 1) } else { 0 }

        if ($freePercent -lt 10) {
            Write-Log "WARNING: Disk space critically low ($freePercent% free on ${localDrive}:)" -Level WARNING
        }

        # Backup folder size - only when StoragePath is a local path and exists
        $folderBytes = 0L
        if ($storagePath -and -not $isUncStorage -and (Test-Path $storagePath)) {
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
    $rrmUrl = if ($config.RrmApiUrl) { $config.RrmApiUrl } else { 'https://mercury.velociraptor-hoki.ts.net' }

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
        $localQuotaGB = (Get-RingConfig).QuotaGB
        $diskPayload = @{
            totalBytes        = $DiskInfo.TotalBytes
            freeBytes         = $DiskInfo.FreeBytes
            freePercent       = $DiskInfo.FreePercent
            backupFolderBytes = $DiskInfo.BackupFolderBytes
            quotaBytes        = if ($localQuotaGB -gt 0) { [int64]($localQuotaGB * 1GB) } else { $null }
        }
    }

    $tsMode = Get-EffectiveTailscaleMode -Config $config

    $payload = @{
        hostname      = $config.Hostname
        rrVersion     = (Get-LocalRrVersion)
        tailscaleMode = $tsMode
        disk          = $diskPayload
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

        $diskTag = if ($diskPayload) { "disk=yes" } else { "disk=no" }
        Write-Log "RRM heartbeat OK  -  job='$JobName' status='$Status' rrVersion='$(Get-LocalRrVersion)' $diskTag" -Level INFO
    }
    catch {
        # Non-fatal: peer keeps working even if the API is unreachable
        Write-Log "RRM heartbeat failed (non-fatal): $_" -Level WARNING
    }
}

function Invoke-ManualHeartbeat {
    <#
    .SYNOPSIS
        Sends a heartbeat to the RRM API for every job that has run at least once.
        Updates peer info (version, disk, tailscale mode) and job definitions in the
        web app without running a backup.  Jobs currently in Running state are skipped.
    #>
    Write-Log "Manual heartbeat started" -Level INFO

    $jobs = @(Get-Jobs)
    if (-not $jobs -or $jobs.Count -eq 0) {
        Write-Log "Manual heartbeat: no jobs configured" -Level INFO
        return
    }

    $statusTable = Get-JobsStatus
    $diskInfo    = Get-DiskSpaceInfo
    $sentCount   = 0
    $firstJob    = $true

    foreach ($job in $jobs) {
        $status = $statusTable[$job.JobName]

        if (-not $status -or -not $status.LastRun) {
            Write-Log "Manual heartbeat: skipping '$($job.JobName)' - never run" -Level INFO
            continue
        }

        $diskArg = $null
        if ($firstJob) {
            $diskArg  = $diskInfo
            $firstJob = $false
        }

        $sendStatus = $status.LastStatus
        $dur = [int]0
        $sz  = [long]0
        if ($null -ne $status.LastDurationSeconds) { $dur = [int]$status.LastDurationSeconds }
        if ($null -ne $status.LastSizeBytes)        { $sz  = [long]$status.LastSizeBytes }

        try {
            Send-RrmHeartbeat `
                -JobName         $job.JobName `
                -Status          $sendStatus `
                -RanAt           (Get-Date).ToString('o') `
                -DurationSeconds $dur `
                -SizeBytes       $sz `
                -DiskInfo        $diskArg
            Write-Log "Manual heartbeat OK: '$($job.JobName)' [$sendStatus]" -Level INFO
            $sentCount++
        }
        catch {
            Write-Log "Manual heartbeat failed for '$($job.JobName)': $_" -Level WARNING
        }
    }

    Write-Log "Manual heartbeat complete: $sentCount job(s) sent" -Level INFO
}

#endregion

#region Main

function Invoke-MissedJobCheck {
    <#
    .SYNOPSIS
        Launches any enabled job that has exceeded its expected run interval.
    .DESCRIPTION
        Called from -UpdateOnly mode after the auto-update check. For each enabled
        job, computes the threshold as (Frequency + 2 hours). If LastRun is older
        than the threshold -- or the job has never run -- and the job is not already
        Running, it launches Execute-Backup.ps1 -JobName as a fully independent
        process (Start-Process -WindowStyle Hidden), exactly like a manual launch.

        The -UpdateOnly task exits immediately after this call; the catch-up jobs
        run in separate processes and do not block or affect the hourly task.
    #>
    $scriptFile = Join-Path $script:InstallPath 'Execute-Backup.ps1'
    if (-not (Test-Path $scriptFile)) { return }

    $jobs = Get-Jobs
    if (-not $jobs -or $jobs.Count -eq 0) { return }

    $statusTable = Get-JobsStatus
    $now = Get-Date

    # In PerJob mode each catch-up job connects and disconnects Tailscale.
    # Running two PerJob jobs in parallel causes a race: the first to finish
    # calls tailscale down while the second is still backing up, breaking SMB
    # and DNS for the running job. Fix: launch at most one catch-up per
    # invocation in PerJob mode. The next hourly check handles remaining jobs.
    $config = Get-RingConfig
    $tailscaleMode = Get-EffectiveTailscaleMode -Config $config
    $isPerJob = ($tailscaleMode -eq 'PerJob')
    $launchedCount = 0

    # Sort jobs by most overdue first: never-run jobs go first (LastRun = $null),
    # then by oldest LastRun. This ensures the most urgent job runs next in PerJob mode.
    $jobs = $jobs | Sort-Object -Property {
        $s = $statusTable[$_.JobName]
        if (-not $s -or -not $s.LastRun) { return [datetime]::MinValue }
        try { return [datetime]$s.LastRun } catch { return [datetime]::MinValue }
    }

    foreach ($job in $jobs) {
        if ($job.Enabled -eq $false) { continue }

        $jobName   = $job.JobName
        $freqHours = 24
        if ($job.Frequency) { $freqHours = [int]$job.Frequency }
        $thresholdHours = $freqHours + 2

        $status    = $statusTable[$jobName]
        $hoursAgo  = $null
        $isOverdue = $false

        # Skip if already running -- avoids launching a second instance of the same job
        if ($status -and $status.LastStatus -eq 'Running') {
            Write-Log "MissedJobCheck: $jobName is currently Running -- skipping" -Level INFO
            if ($isPerJob) { return }   # another PerJob backup is active; stop here
            continue
        }

        if (-not $status -or -not $status.LastRun) {
            $isOverdue = $true
        } else {
            try {
                $lastRun  = [datetime]$status.LastRun
                $hoursAgo = ($now - $lastRun).TotalHours
                $isOverdue = ($hoursAgo -gt $thresholdHours)
            } catch {
                $isOverdue = $true
            }
        }

        if ($isOverdue) {
            $sinceMsg = "never"
            if ($null -ne $hoursAgo) { $sinceMsg = "$([math]::Round($hoursAgo, 1))h ago" }
            Write-Log "MissedJobCheck: $jobName last ran $sinceMsg (threshold ${thresholdHours}h) -- launching catch-up job" -Level INFO
            $psArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptFile`" -JobName `"$jobName`""
            Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -WindowStyle Hidden
            $launchedCount++
            # In PerJob mode stop after one launch -- next hourly check handles the rest
            if ($isPerJob) { return }
        }
    }
}

function Invoke-BackupJob {
    param([string]$JobName)

    $startTime = Get-Date
    Write-Log "=== Backup Job Started: $JobName ===" -Level INFO

    Write-Log "Checking Tailscale status..." -Level INFO
    $tailscaleSession = Ensure-TailscaleForBackup
    if (-not $tailscaleSession.Ready) {
        Write-Log "Cannot start backup because Tailscale is unavailable: $($tailscaleSession.Reason)" -Level ERROR
        Update-JobStatus -JobName $JobName -Status "Failed" -DurationSeconds 0 -SizeBytes 0
        try {
            Send-RrmHeartbeat -JobName $JobName -Status "Failed" `
                -RanAt (Get-Date).ToString('o') -DurationSeconds 0 -SizeBytes 0 `
                -ErrorMessage "Tailscale unavailable: $($tailscaleSession.Reason)"
        } catch {}
        return $false
    }

    # Declared here so the finally block can always read them regardless of where
    # execution was interrupted (normal exit, exception, or process kill).
    $finalStatus     = 'Failed'
    $durationSeconds = 0
    $sizeBytes       = 0
    $success         = $false
    $errorMsg        = $null

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

        # Notify API that the job is starting so the dashboard shows Running immediately.
        try {
            Send-RrmHeartbeat -JobName $JobName -Status 'Running' -RanAt $startTime.ToString('o')
        } catch {}

        # Pre-flight: ping every destination peer via Tailscale before starting.
        # Ensures Tailscale is actually routing traffic, not just locally connected.
        # If ALL peers are unreachable the job fails early with a clear message.
        # If SOME are unreachable a warning is logged and the job continues with the
        # reachable peers (the per-destination check in Invoke-BackupToPeer handles them).
        if ($job.PeerDestinations -and $job.PeerDestinations.Count -gt 0) {
            Write-Log "Pre-flight check: pinging $($job.PeerDestinations.Count) destination peer(s)..." -Level INFO
            $preOkCount   = 0
            $preFailNames = @()
            foreach ($dest in @($job.PeerDestinations)) {
                $destLabel = $dest.TailscaleIP
                if ($dest.Hostname) { $destLabel = $dest.Hostname }
                if ($dest.Location) { $destLabel = $dest.Location }
                $peerOk = $dest.TailscaleIP -and (Test-TailscalePeerReachable -TailscaleIP $dest.TailscaleIP)
                if (-not $peerOk) {
                    # Retry once -- node map may not have synced right after tailscale up
                    Write-Log "Pre-flight: $destLabel not responding, retrying in 5s..." -Level INFO
                    Start-Sleep -Seconds 5
                    $peerOk = $dest.TailscaleIP -and (Test-TailscalePeerReachable -TailscaleIP $dest.TailscaleIP)
                }
                if ($peerOk) {
                    Write-Log "Pre-flight OK: $destLabel ($($dest.TailscaleIP))" -Level INFO
                    $preOkCount++
                } else {
                    Write-Log "Pre-flight FAIL: $destLabel ($($dest.TailscaleIP)) did not respond" -Level WARNING
                    $preFailNames += $destLabel
                }
            }
            if ($preFailNames.Count -gt 0) {
                Write-Log "Pre-flight: $($preFailNames.Count) peer(s) not reachable via Tailscale: $($preFailNames -join ', ')" -Level WARNING
            }
            if ($preOkCount -eq 0) {
                $errorMsg = "Tailscale unreachable: no destination peers responded to ping ($($preFailNames -join ', '))"
                Write-Log "Pre-flight failed -- $errorMsg" -Level ERROR
                return $false  # finally block sends heartbeat + updates status
            }
            Write-Log "Pre-flight passed: $preOkCount/$($job.PeerDestinations.Count) peer(s) reachable" -Level INFO
        }

        Write-Log "Starting backup execution..." -Level INFO
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
        $errorMsg        = if (-not $success) {
                               if ($script:LastBackupError) { $script:LastBackupError }
                               else { "Backup failed - check log for details" }
                           } else { $null }

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
        $errorMsg        = if ($script:LastBackupError) { $script:LastBackupError } else { "$_" }
        Write-Log "Unhandled error in backup job '$JobName': $_" -Level ERROR
    }
    finally {
        # Always write final status and send heartbeat  -  even on exception or soft-kill.
        # (Hard kills by the OS scheduler will still interrupt this, but normal failures
        #  and PowerShell exceptions are guaranteed to report here.)
        Update-JobStatus -JobName $JobName -Status $finalStatus -DurationSeconds $durationSeconds -SizeBytes $sizeBytes
        Write-Log "=== Backup Job Completed: $JobName - $finalStatus (${durationSeconds}s) ===" -Level $(if ($finalStatus -eq 'Success') { 'SUCCESS' } else { 'ERROR' })
        try {
            Send-RrmHeartbeat `
                -JobName         $JobName `
                -Status          $finalStatus `
                -RanAt           $startTime.ToString('o') `
                -DurationSeconds $durationSeconds `
                -SizeBytes       $sizeBytes `
                -ErrorMessage    $errorMsg `
                -DiskInfo        (Get-DiskSpaceInfo)
        }
        catch {
            Write-Log "Could not send RRM heartbeat: $_" -Level WARNING
        }
        if ($tailscaleSession -and $tailscaleSession.StartedByJob -and $tailscaleSession.Mode -eq 'PerJob') {
            Write-Log "Restoring Tailscale state (PerJob mode)..." -Level INFO
        }
        Restore-TailscaleAfterBackup -Session $tailscaleSession
    }
}

# Main entry point
try {
    if (-not (Test-Path $LogPath)) {
        New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
    }

    # Self-healing: re-encode any UTF-8 .ps1 files to UTF-16 LE.
    # Fixes peers whose files were downloaded by an older Execute-Backup.ps1
    # that lacked the UTF-16 conversion -- runs silently on every execution.
    Repair-Ps1Encodings

    # -UpdateOnly mode: just check/apply update and exit  -  no backup
    if ($UpdateOnly) {
        if (-not $SkipUpdateCheck) {
            Invoke-AutoUpdate
        }
        # Also ensure the scheduled task exists (this is where it gets installed
        # on peers that updated but haven't run a job yet)
        Ensure-AutoUpdateTask
        Invoke-MissedJobCheck
        Write-Log "UpdateOnly: already on latest version $(Get-LocalRrVersion)" -Level INFO
        exit 0
    }

    # -HeartbeatOnly mode: push current peer/job state to API and exit  -  no backup
    if ($HeartbeatOnly) {
        Invoke-ManualHeartbeat
        exit 0
    }

    # Normal mode: require -JobName
    if (-not $JobName) {
        Write-Error "JobName is required unless -UpdateOnly or -HeartbeatOnly is specified."
        exit 1
    }

    # Auto-updates are handled exclusively by the RR-AutoUpdate scheduled task
    # (hourly). We no longer check for updates before each backup job to avoid
    # slow downloads or hangs blocking the actual backup.

    # Ensure the hourly auto-update task exists (registers silently if missing)
    Ensure-AutoUpdateTask

    # Migrate old RRM URL to new server if needed
    Invoke-RrmUrlMigration

    $result = Invoke-BackupJob -JobName $JobName
    exit $(if ($result) { 0 } else { 1 })
}
catch {
    Write-Log "Fatal error: $_" -Level ERROR
    # If a fatal error occurred before Invoke-BackupJob ran its own finally block,
    # we must update the status here so the job doesn't stay stuck as "Running".
    if ($JobName) {
        try { Update-JobStatus -JobName $JobName -Status "Failed" -DurationSeconds 0 -SizeBytes 0 } catch {}
        try {
            Send-RrmHeartbeat -JobName $JobName -Status "Failed" `
                -RanAt (Get-Date).ToString('o') -DurationSeconds 0 -SizeBytes 0 `
                -ErrorMessage "Fatal startup error: $_"
        } catch {}
    }
    exit 1
}
