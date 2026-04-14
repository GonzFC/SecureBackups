#Requires -RunAsAdministrator

<#
.SYNOPSIS
    VLABS Resilience Ring Manager - Multi-ring monitoring and management

.DESCRIPTION
    Connects to multiple Resilience Rings via Tailscale tags to:
    - Monitor backup jobs and peer health across all rings
    - Generate statistics for monthly invoicing
    - Alert on problems with peers or backup jobs

    "I inform promptly of any problem with any peer or backup job,
     so we, the managers can fix fast in order to invoice and collect
     every month for every ring."

.NOTES
    Part of VLABS Infrastructure Tools
    Install: iex (irm https://raw.githubusercontent.com/GonzFC/SecureBackups/main/install-rrm.ps1)
#>

[CmdletBinding()]
param(
    [switch]$SkipUpdateCheck
)

# Version and repository information
# Read version from rrm-version.txt (single source of truth)
$versionFile = Join-Path $PSScriptRoot "rrm-version.txt"
if (Test-Path $versionFile) {
    $script:AppVersion = (Get-Content $versionFile -Raw).Trim()
} else {
    $script:AppVersion = '0.0.0'
}
$script:AppName = 'VLABS Resilience Ring Manager'
$script:RepoOwner = 'GonzFC'
$script:RepoName = 'SecureBackups'
$script:RepoBranch = 'main'

# Paths
$script:InstallPath = $PSScriptRoot
$script:DataPath = 'C:\ProgramData\VLABS_RRM'
$script:RingsFile = Join-Path $DataPath 'rings.json'
$script:LogPath = Join-Path $DataPath 'Logs'

# Current working ring (selected at startup)
$script:ActiveRing = $null
$script:ActiveRingData = $null

#region Logging

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARNING','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )

    try {
        if (-not (Test-Path $script:LogPath)) {
            New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logFile = Join-Path $script:LogPath "RRM_$(Get-Date -Format 'yyyyMMdd').log"
        Add-Content -Path $logFile -Value "[$timestamp] [$Level] $Message" -ErrorAction Stop
    }
    catch { }
}

#endregion

#region Update Management

function Get-LatestRRMVersion {
    # Try GitHub Contents API first (no CDN caching).
    # Fall back to raw.githubusercontent.com in case the API is firewalled.
    try {
        $apiUrl      = "https://api.github.com/repos/$script:RepoOwner/$script:RepoName/contents/rrm-version.txt?ref=$script:RepoBranch"
        $apiResponse = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -TimeoutSec 10 `
                           -Headers @{ 'Accept' = 'application/vnd.github.v3+json'; 'User-Agent' = 'RRM-UpdateCheck' }
        return [System.Text.Encoding]::UTF8.GetString(
                   [System.Convert]::FromBase64String(
                       ($apiResponse.content -replace "`n","" -replace "`r","")
                   )).Trim()
    }
    catch {}

    try {
        $rawUrl = "https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/rrm-version.txt"
        return (Invoke-RestMethod -Uri $rawUrl -UseBasicParsing -TimeoutSec 10).Trim()
    }
    catch {
        return $null
    }
}

function Test-RRMUpdateAvailable {
    param([switch]$Silent)

    if (-not $Silent) {
        Write-Host "Checking for updates..." -ForegroundColor Gray -NoNewline
    }

    $latestVersion = Get-LatestRRMVersion

    if ($null -eq $latestVersion) {
        if (-not $Silent) { Write-Host " [OFFLINE]" -ForegroundColor Yellow }
        return @{ Available = $false; Reason = "Could not reach GitHub" }
    }

    try {
        $current = [Version]$script:AppVersion
        $latest = [Version]$latestVersion

        if ($latest -gt $current) {
            if (-not $Silent) { Write-Host " [UPDATE AVAILABLE: v$latestVersion]" -ForegroundColor Cyan }
            return @{ Available = $true; CurrentVersion = $script:AppVersion; LatestVersion = $latestVersion }
        }
        else {
            if (-not $Silent) { Write-Host " [UP TO DATE]" -ForegroundColor Green }
            return @{ Available = $false; CurrentVersion = $script:AppVersion; LatestVersion = $latestVersion }
        }
    }
    catch {
        if (-not $Silent) { Write-Host " [ERROR]" -ForegroundColor Red }
        return @{ Available = $false; Reason = "Version comparison failed" }
    }
}

function Invoke-RRMUpdate {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "     RRM - UPDATE" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    $updateCheck = Test-RRMUpdateAvailable

    if (-not $updateCheck.Available) {
        Write-Host "You are running the latest version ($script:AppVersion)" -ForegroundColor Green
        Read-Host "`nPress Enter to continue"
        return
    }

    Write-Host "Current version: $($updateCheck.CurrentVersion)" -ForegroundColor Yellow
    Write-Host "Latest version:  $($updateCheck.LatestVersion)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Update now? [Y/n]: " -NoNewline -ForegroundColor Yellow
    $response = Read-Host

    if ($response -ne '' -and $response -notmatch '^[Yy]') {
        Write-Host "Update cancelled." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }

    Write-Host "`nUpdating..." -ForegroundColor Cyan

    $gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
    $gitRepo = Test-Path (Join-Path $script:InstallPath '.git')

    if ($gitAvailable -and $gitRepo) {
        try {
            Push-Location $script:InstallPath
            git fetch origin $script:RepoBranch 2>&1 | Out-Null
            git reset --hard "origin/$script:RepoBranch" 2>&1 | Out-Null
            Pop-Location

            Get-ChildItem -Path $script:InstallPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

            Write-Host "`nUpdate successful! Please restart RRM." -ForegroundColor Green
            Read-Host "Press Enter to exit"
            exit 0
        }
        catch {
            Pop-Location -ErrorAction SilentlyContinue
            Write-Host "Update failed: $_" -ForegroundColor Red
        }
    }
    else {
        Write-Host "Git not available. Please reinstall using:" -ForegroundColor Yellow
        Write-Host "iex (irm https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/install-rrm.ps1)" -ForegroundColor White
    }

    Read-Host "`nPress Enter to continue"
}

#endregion

#region Tailscale Functions

function Test-TailscaleReady {
    $tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $tailscale) {
        return @{ Ready = $false; Reason = "Tailscale not installed" }
    }

    try {
        $status = tailscale status --json 2>$null | ConvertFrom-Json
        if ($status.BackendState -eq 'Running') {
            return @{ Ready = $true; Self = $status.Self }
        }
        else {
            return @{ Ready = $false; Reason = "Tailscale not connected (state: $($status.BackendState))" }
        }
    }
    catch {
        return @{ Ready = $false; Reason = "Failed to get Tailscale status" }
    }
}

function Get-TailscalePeersByTag {
    param([string]$Tag)

    try {
        $status = tailscale status --json 2>$null | ConvertFrom-Json
        $peers = @()

        # Normalize tag format
        $tagWithPrefix = if ($Tag.StartsWith("tag:")) { $Tag } else { "tag:$Tag" }
        $tagWithoutPrefix = $Tag -replace '^tag:', ''

        # Check Self (local machine) first - it might have the tag too!
        if ($status.Self.Tags) {
            $selfHasTag = $status.Self.Tags | Where-Object { $_ -eq $tagWithPrefix -or $_ -eq $tagWithoutPrefix }
            if ($selfHasTag) {
                # Extract Tailscale hostname from DNSName (remove .tail*****.ts.net suffix)
                $tsHostname = $status.Self.DNSName -replace '\..*$', ''
                $peers += [PSCustomObject]@{
                    ID = $status.Self.ID
                    HostName = $tsHostname
                    DNSName = $status.Self.DNSName
                    TailscaleIP = $status.Self.TailscaleIPs[0]
                    OS = $status.Self.OS
                    Online = $true  # Self is always online
                    LastSeen = (Get-Date).ToString('o')
                    Tags = $status.Self.Tags
                    IsSelf = $true
                }
            }
        }

        # Check remote peers
        foreach ($peerProp in $status.Peer.PSObject.Properties) {
            $peer = $peerProp.Value

            # Check if peer has the tag
            if ($peer.Tags) {
                $peerHasTag = $peer.Tags | Where-Object { $_ -eq $tagWithPrefix -or $_ -eq $tagWithoutPrefix }
                if ($peerHasTag) {
                    # Extract Tailscale hostname from DNSName
                    $tsHostname = $peer.DNSName -replace '\..*$', ''
                    $peers += [PSCustomObject]@{
                        ID = $peerProp.Name
                        HostName = $tsHostname
                        DNSName = $peer.DNSName
                        TailscaleIP = $peer.TailscaleIPs[0]
                        OS = $peer.OS
                        Online = $peer.Online
                        LastSeen = $peer.LastSeen
                        Tags = $peer.Tags
                        IsSelf = $false
                    }
                }
            }
        }

        return $peers
    }
    catch {
        Write-Log "Failed to get peers by tag: $_" -Level ERROR
        return @()
    }
}

#endregion

#region Ring Data Functions

function Get-SavedRings {
    if (-not (Test-Path $script:RingsFile)) {
        return @()
    }

    try {
        $content = Get-Content $script:RingsFile -Raw | ConvertFrom-Json
        # Ensure it's an array
        if ($content -is [Array]) { return $content }
        if ($content) { return @($content) }
        return @()
    }
    catch {
        return @()
    }
}

function Save-Rings {
    param($Rings)

    if (-not (Test-Path $script:DataPath)) {
        New-Item -Path $script:DataPath -ItemType Directory -Force | Out-Null
    }

    $Rings | ConvertTo-Json -Depth 10 | Set-Content $script:RingsFile -Force
}

function Get-PeerData {
    <#
    .SYNOPSIS
        Connects to a peer and retrieves its ring data
    #>
    param(
        [string]$TailscaleIP,
        [string]$CustomerCode
    )

    $sharePath = "\\$TailscaleIP\RR_Backups"
    $result = @{
        Connected = $false
        Jobs = @()
        StorageUsedGB = 0
        ConfigFound = $false
        PeerConfig = $null
    }

    try {
        # Try to connect without credentials first (for discovery)
        # We need to know the customer code to generate the password

        if ([string]::IsNullOrEmpty($CustomerCode)) {
            # Try to access the share to see if it exists
            $testPath = Test-Path $sharePath -ErrorAction SilentlyContinue
            if (-not $testPath) {
                return $result
            }
        }
        else {
            # Generate service account password from customer code
            $password = Get-RRMServicePassword -CustomerCode $CustomerCode

            # Try to connect - capture all output
            try {
                $netResult = cmd /c "net use `"$sharePath`" /user:RR_Service `"$password`" 2>&1"
                $exitCode = $LASTEXITCODE
            }
            catch {
                $result.Error = "Exception: $_"
                return $result
            }

            if ($exitCode -ne 0) {
                # Store error for debugging
                $result.Error = "$netResult"
                Write-Log "Failed to connect to $TailscaleIP : $netResult" -Level WARNING
                return $result
            }
        }

        $result.Connected = $true

        # Find customer folder
        $customerPath = $null
        if ($CustomerCode) {
            $customerPath = Join-Path $sharePath $CustomerCode.ToUpper()
        }
        else {
            # Try to find any customer folder
            $folders = Get-ChildItem $sharePath -Directory -ErrorAction SilentlyContinue
            if ($folders.Count -gt 0) {
                $customerPath = $folders[0].FullName
            }
        }

        if ($customerPath -and (Test-Path $customerPath)) {
            # Calculate REPOSITORY storage (data stored ON this peer for the ring)
            $size = (Get-ChildItem $customerPath -Recurse -File -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            $result.StorageUsedGB = [math]::Round(($size / 1GB), 2)
            
            # Count locations (subdirectories under customer code = locations)
            $locationFolders = Get-ChildItem $customerPath -Directory -ErrorAction SilentlyContinue
            $result.LocationCount = $locationFolders.Count
            $result.Locations = @($locationFolders | ForEach-Object { $_.Name })
        }

        # Read jobs-status.json from _nodeinfo
        $statusFile = Join-Path $sharePath "_nodeinfo\jobs-status.json"
        if (Test-Path $statusFile) {
            try {
                $jobsStatus = Get-Content $statusFile -Raw | ConvertFrom-Json
                $result.JobsStatus = $jobsStatus
                $result.Jobs = @($jobsStatus.Jobs)
                
                # Count successful jobs
                $result.SuccessfulJobs = @($jobsStatus.Jobs | Where-Object { $_.LastStatus -eq 'Success' }).Count
                $result.TotalJobs = $jobsStatus.Jobs.Count
                $result.NodeLocation = $jobsStatus.Location
            }
            catch { }
        }

    }
    catch {
        $result.Error = "$_"
        Write-Log "Error getting peer data from $TailscaleIP : $_" -Level ERROR
    }
    finally {
        # Disconnect (only if we connected)
        if ($result.Connected) {
            try { net use $sharePath /delete 2>&1 | Out-Null } catch { }
        }
    }

    return $result
}

function Get-RRMServicePassword {
    <#
    .SYNOPSIS
        Generates deterministic service account password from customer code
        (MUST match Get-RingServicePassword in PeerManagement.ps1)
    #>
    param([string]$CustomerCode)

    # Same algorithm as Resilience Ring client
    $salt = "ResilienceRing2026!"
    $combined = "$CustomerCode$salt"

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
    $hash = $sha256.ComputeHash($bytes)
    $hashString = [BitConverter]::ToString($hash) -replace '-', ''

    # Take first 12 chars + add complexity requirements
    $password = $hashString.Substring(0, 12) + "Rr1!"
    return $password
}

function Get-RingStatistics {
    <#
    .SYNOPSIS
        Scans all peers in a ring and aggregates statistics
    #>
    param(
        [string]$Tag,
        [string]$CustomerCode
    )

    Write-Host "Scanning ring: $Tag" -ForegroundColor Cyan
    Write-Host ""

    # Get all peers with this tag
    $peers = Get-TailscalePeersByTag -Tag $Tag

    if ($peers.Count -eq 0) {
        Write-Host "No peers found with tag: $Tag" -ForegroundColor Yellow
        return $null
    }

    Write-Host "Found $($peers.Count) peer(s)" -ForegroundColor Green

    $stats = @{
        Tag = $Tag
        CustomerCode = $CustomerCode
        ScanTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        TotalPeers = $peers.Count
        OnlinePeers = 0
        OfflinePeers = 0
        TotalStorageGB = 0
        TotalUsedGB = 0
        TotalJobs = 0
        TotalCopies = 0
        Peers = @()
        Problems = @()
    }

    foreach ($peer in $peers) {
        Write-Host "  Checking $($peer.HostName)..." -ForegroundColor Gray -NoNewline

        $peerStats = @{
            Hostname = $peer.HostName
            TailscaleIP = $peer.TailscaleIP
            Online = $peer.Online
            LastSeen = $peer.LastSeen
            StorageUsedGB = 0
            Jobs = @()
            SuccessfulJobs = 0
            TotalJobs = 0
            LocationCount = 0
            Locations = @()
            NodeLocation = ""
            Status = "Unknown"
            IsSelf = $peer.IsSelf
        }

        if ($peer.Online -or $peer.IsSelf) {
            $stats.OnlinePeers++

            # Handle self differently - read local data
            if ($peer.IsSelf) {
                Write-Host " (self)" -ForegroundColor Gray -NoNewline
                
                # Read local jobs directly
                try {
                    $localJobsFile = "C:\ProgramData\VLABS_ResilienceRing\jobs.json"
                    $localConfigFile = "C:\ProgramData\VLABS_ResilienceRing\ring-config.json"
                    
                    if (Test-Path $localJobsFile) {
                        $localJobs = @(Get-Content $localJobsFile -Raw | ConvertFrom-Json)
                        $peerStats.Jobs = $localJobs
                        $peerStats.TotalJobs = $localJobs.Count
                        $peerStats.SuccessfulJobs = @($localJobs | Where-Object { $_.LastStatus -eq 'Success' }).Count
                    }
                    
                    if (Test-Path $localConfigFile) {
                        $localConfig = Get-Content $localConfigFile -Raw | ConvertFrom-Json
                        $peerStats.NodeLocation = $localConfig.Location
                        
                        # Calculate repository storage (what's stored locally)
                        if ($localConfig.StoragePath -and (Test-Path $localConfig.StoragePath)) {
                            $repoSize = (Get-ChildItem $localConfig.StoragePath -Recurse -File -ErrorAction SilentlyContinue |
                                        Measure-Object -Property Length -Sum).Sum
                            $peerStats.StorageUsedGB = [math]::Round(($repoSize / 1GB), 2)
                            
                            # Count locations
                            $custPath = Join-Path $localConfig.StoragePath $CustomerCode.ToUpper()
                            if (Test-Path $custPath) {
                                $locFolders = Get-ChildItem $custPath -Directory -ErrorAction SilentlyContinue
                                $peerStats.LocationCount = $locFolders.Count
                                $peerStats.Locations = @($locFolders | ForEach-Object { $_.Name })
                            }
                        }
                    }
                    
                    $peerStats.Status = "OK"
                    $stats.TotalUsedGB += $peerStats.StorageUsedGB
                    Write-Host " OK ($($peerStats.SuccessfulJobs)/$($peerStats.TotalJobs) jobs, $($peerStats.StorageUsedGB) GB)" -ForegroundColor Green
                }
                catch {
                    $peerStats.Status = "Error"
                    Write-Host " ERROR: $_" -ForegroundColor Red
                }
            }
            else {
                # Get peer data via network
                $peerData = Get-PeerData -TailscaleIP $peer.TailscaleIP -CustomerCode $CustomerCode

                if ($peerData.Connected) {
                    $peerStats.StorageUsedGB = $peerData.StorageUsedGB
                    $peerStats.Jobs = $peerData.Jobs
                    $peerStats.SuccessfulJobs = if ($peerData.SuccessfulJobs) { $peerData.SuccessfulJobs } else { 0 }
                    $peerStats.TotalJobs = if ($peerData.TotalJobs) { $peerData.TotalJobs } else { 0 }
                    $peerStats.LocationCount = if ($peerData.LocationCount) { $peerData.LocationCount } else { 0 }
                    $peerStats.Locations = if ($peerData.Locations) { $peerData.Locations } else { @() }
                    $peerStats.NodeLocation = if ($peerData.NodeLocation) { $peerData.NodeLocation } else { "" }
                    $peerStats.Status = "OK"
                    $stats.TotalUsedGB += $peerData.StorageUsedGB
                    Write-Host " OK ($($peerStats.SuccessfulJobs)/$($peerStats.TotalJobs) jobs, $($peerData.StorageUsedGB) GB)" -ForegroundColor Green
                }
                else {
                    $peerStats.Status = "Connection Failed"
                    $errorDetail = if ($peerData.Error) { $peerData.Error } else { "Unknown error" }
                    $stats.Problems += "Cannot connect to $($peer.HostName): $errorDetail"
                    Write-Host " CONN FAILED" -ForegroundColor Red
                }
            }
        }
        else {
            $stats.OfflinePeers++
            $peerStats.Status = "Offline"
            $stats.Problems += "$($peer.HostName) is offline (last seen: $($peer.LastSeen))"
            Write-Host " OFFLINE" -ForegroundColor Red
        }

        $stats.Peers += $peerStats
    }

    return $stats
}

#endregion

#region Ring Management

function Connect-ToNewRing {
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "     CONNECT TO NEW RING" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    # Check Tailscale
    $tsStatus = Test-TailscaleReady
    if (-not $tsStatus.Ready) {
        Write-Host "ERROR: $($tsStatus.Reason)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please ensure Tailscale is installed and connected." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    Write-Host "[OK] Tailscale connected" -ForegroundColor Green
    Write-Host ""

    # Get ring tag
    Write-Host "Enter the Tailscale tag for this ring." -ForegroundColor White
    Write-Host "Example: rr-acme, rr-mesker, rr-storage" -ForegroundColor Gray
    Write-Host "(Do not include 'tag:' prefix)" -ForegroundColor Gray
    Write-Host ""
    $tagInput = Read-Host "Ring Tag"

    if ([string]::IsNullOrWhiteSpace($tagInput)) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    # Normalize tag
    $tag = $tagInput.Trim().ToLower()
    if ($tag.StartsWith("tag:")) { $tag = $tag.Substring(4) }
    $fullTag = "tag:$tag"

    # Check if already added
    $rings = Get-SavedRings
    if ($rings | Where-Object { $_.Tag -eq $fullTag }) {
        Write-Host "`nThis ring is already added!" -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    Write-Host ""

    # Scan for peers
    $peers = Get-TailscalePeersByTag -Tag $fullTag

    if ($peers.Count -eq 0) {
        Write-Host "No peers found with tag: $fullTag" -ForegroundColor Red
        Write-Host ""
        Write-Host "Make sure:" -ForegroundColor Yellow
        Write-Host "  1. The tag exists in your Tailscale ACLs" -ForegroundColor Gray
        Write-Host "  2. At least one peer has this tag" -ForegroundColor Gray
        Write-Host "  3. Your machine can see peers with this tag" -ForegroundColor Gray
        Read-Host "`nPress Enter to continue"
        return
    }

    Write-Host "Found $($peers.Count) peer(s) with tag: $fullTag" -ForegroundColor Green
    Write-Host ""

    foreach ($peer in $peers) {
        $status = if ($peer.Online) { "[ONLINE]" } else { "[OFFLINE]" }
        $statusColor = if ($peer.Online) { "Green" } else { "Red" }
        Write-Host "  $($peer.HostName) ($($peer.TailscaleIP)) " -NoNewline
        Write-Host $status -ForegroundColor $statusColor
    }

    Write-Host ""

    # Get customer code
    Write-Host "Enter the Customer Code for this ring." -ForegroundColor White
    Write-Host "This is used to connect to peer shares." -ForegroundColor Gray
    Write-Host "Example: ACME, MESKER, MMI" -ForegroundColor Gray
    Write-Host ""
    $customerCode = Read-Host "Customer Code"

    if ([string]::IsNullOrWhiteSpace($customerCode)) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    $customerCode = $customerCode.Trim().ToLower()  # MUST match PeerManagement.ps1 which uses lowercase
    $customerCodeDisplay = $customerCode.ToUpper()  # For display only

    # Get friendly name
    Write-Host ""
    Write-Host "Enter a friendly name for this ring (or press Enter to use '$customerCodeDisplay')" -ForegroundColor White
    $ringName = Read-Host "Ring Name"
    if ([string]::IsNullOrWhiteSpace($ringName)) { $ringName = $customerCodeDisplay }

    # Save the ring
    $newRing = @{
        Name = $ringName
        Tag = $fullTag
        CustomerCode = $customerCode
        AddedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        LastScan = $null
        PeerCount = $peers.Count
    }

    $rings += $newRing
    Save-Rings -Rings $rings

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  RING ADDED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Name:     $ringName" -ForegroundColor White
    Write-Host "  Tag:      $fullTag" -ForegroundColor White
    Write-Host "  Customer: $customerCode" -ForegroundColor White
    Write-Host "  Peers:    $($peers.Count)" -ForegroundColor White
    Write-Host ""

    Write-Log "Added new ring: $ringName ($fullTag)" -Level SUCCESS

    Read-Host "Press Enter to continue"
}

function Show-AllRings {
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "     ALL CONNECTED RINGS" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    $rings = Get-SavedRings

    if ($rings.Count -eq 0) {
        Write-Host "No rings configured yet." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Use 'C' from the main menu to connect to a ring." -ForegroundColor Gray
        Read-Host "`nPress Enter to continue"
        return
    }

    Write-Host "  # | Name                | Tag                    | Peers | Last Scan" -ForegroundColor White
    Write-Host "  --|---------------------|------------------------|-------|-------------------" -ForegroundColor Gray

    $i = 1
    foreach ($ring in $rings) {
        $lastScan = if ($ring.LastScan) { $ring.LastScan } else { "Never" }
        Write-Host ("  {0} | {1,-19} | {2,-22} | {3,5} | {4}" -f $i,
            $ring.Name.Substring(0, [Math]::Min(19, $ring.Name.Length)),
            $ring.Tag.Substring(0, [Math]::Min(22, $ring.Tag.Length)),
            $ring.PeerCount,
            $lastScan)
        $i++
    }

    Write-Host ""
    Read-Host "Press Enter to continue"
}

#endregion

#region Ring Data Display

function Show-RingStatistics {
    if (-not $script:ActiveRing) {
        Write-Host "No ring selected!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "     RING STATISTICS" -ForegroundColor Cyan
    Write-Host "     $($script:ActiveRing.Name)" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    # Get fresh statistics
    $stats = Get-RingStatistics -Tag $script:ActiveRing.Tag -CustomerCode $script:ActiveRing.CustomerCode

    if (-not $stats) {
        Read-Host "`nPress Enter to continue"
        return
    }

    $script:ActiveRingData = $stats

    # Update last scan time
    [array]$rings = @(Get-SavedRings)
    for ($i = 0; $i -lt $rings.Count; $i++) {
        if ($rings[$i].Tag -eq $script:ActiveRing.Tag) {
            $rings[$i].LastScan = $stats.ScanTime
            $rings[$i].PeerCount = $stats.TotalPeers
            Save-Rings -Rings $rings
            break
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor White
    Write-Host "  SUMMARY" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor White
    Write-Host ""
    Write-Host "  Ring:           $($script:ActiveRing.Name)" -ForegroundColor White
    Write-Host "  Tag:            $($stats.Tag)" -ForegroundColor White
    Write-Host "  Scan Time:      $($stats.ScanTime)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Total Peers:    $($stats.TotalPeers)" -ForegroundColor Cyan
    Write-Host "  Online:         $($stats.OnlinePeers)" -ForegroundColor Green
    Write-Host "  Offline:        $($stats.OfflinePeers)" -ForegroundColor $(if ($stats.OfflinePeers -gt 0) { "Red" } else { "Green" })
    Write-Host ""
    Write-Host "  Storage Used:   $($stats.TotalUsedGB) GB" -ForegroundColor White
    Write-Host ""

    # Peer details
    Write-Host "========================================" -ForegroundColor White
    Write-Host "  PEER DETAILS" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor White
    Write-Host ""
    Write-Host "  Hostname              | IP               | Good Backups | Locations | Status    | Repository" -ForegroundColor Gray
    Write-Host "  ----------------------|------------------|--------------|-----------|-----------|----------" -ForegroundColor Gray

    foreach ($peer in $stats.Peers) {
        $statusColor = switch ($peer.Status) {
            "OK" { "Green" }
            "Offline" { "Red" }
            default { "Yellow" }
        }
        
        # Good Backups: successful/total jobs on this peer
        $goodBackups = "$($peer.SuccessfulJobs)/$($peer.TotalJobs)"
        $goodBackupsColor = if ($peer.TotalJobs -eq 0) { "Gray" } 
                           elseif ($peer.SuccessfulJobs -eq $peer.TotalJobs) { "Green" } 
                           else { "Yellow" }
        
        # Locations: count of locations with backups stored ON this peer (as repository)
        # This shows how many different locations' data this peer is holding
        $locationsDisplay = "$($peer.LocationCount)"
        $locationsColor = if ($peer.LocationCount -gt 0) { "Cyan" } else { "Gray" }

        Write-Host ("  {0,-21} | {1,-16} | " -f
            $peer.Hostname.Substring(0, [Math]::Min(21, $peer.Hostname.Length)),
            $peer.TailscaleIP) -NoNewline
        Write-Host ("{0,-12}" -f $goodBackups) -ForegroundColor $goodBackupsColor -NoNewline
        Write-Host " | " -NoNewline
        Write-Host ("{0,-9}" -f $locationsDisplay) -ForegroundColor $locationsColor -NoNewline
        Write-Host " | " -NoNewline
        Write-Host ("{0,-9}" -f $peer.Status) -ForegroundColor $statusColor -NoNewline
        Write-Host " | $($peer.StorageUsedGB) GB"
    }

    # Problems
    if ($stats.Problems.Count -gt 0) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor White
        Write-Host "  PROBLEMS DETECTED" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor White
        Write-Host ""
        foreach ($problem in $stats.Problems) {
            Write-Host "  ! $problem" -ForegroundColor Red
        }
    }

    Write-Host ""

    # Invoicing info
    Write-Host "========================================" -ForegroundColor White
    Write-Host "  INVOICING (Active Peers)" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor White
    Write-Host ""
    Write-Host "  Billable Peers: $($stats.OnlinePeers)" -ForegroundColor Cyan
    Write-Host ""

    Read-Host "Press Enter to continue"
}

function Get-PeerJobStatus {
    <#
    .SYNOPSIS
        Reads job status from a peer's _nodeinfo/jobs-status.json
    #>
    param(
        [string]$TailscaleIP,
        [string]$CustomerCode
    )
    
    $sharePath = "\\$TailscaleIP\RR_Backups"
    $result = $null
    
    try {
        # Connect
        $password = Get-RRMServicePassword -CustomerCode $CustomerCode
        $netResult = cmd /c "net use `"$sharePath`" /user:RR_Service `"$password`" 2>&1"
        if ($LASTEXITCODE -ne 0) { return $null }
        
        # Read status file
        $statusFile = Join-Path $sharePath "_nodeinfo\jobs-status.json"
        if (Test-Path $statusFile) {
            $result = Get-Content $statusFile -Raw | ConvertFrom-Json
        }
    }
    catch { }
    finally {
        try { net use $sharePath /delete 2>&1 | Out-Null } catch { }
    }
    
    return $result
}

function Format-Duration {
    param([int]$Seconds)
    if ($Seconds -lt 60) { return "${Seconds}s" }
    if ($Seconds -lt 3600) { return "$([math]::Floor($Seconds/60))m $($Seconds%60)s" }
    return "$([math]::Floor($Seconds/3600))h $([math]::Floor(($Seconds%3600)/60))m"
}

function Format-Size {
    param([long]$Bytes)
    if (-not $Bytes -or $Bytes -eq 0) { return "-" }
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return "$([math]::Round($Bytes/1KB, 1)) KB" }
    if ($Bytes -lt 1GB) { return "$([math]::Round($Bytes/1MB, 1)) MB" }
    return "$([math]::Round($Bytes/1GB, 2)) GB"
}

function Show-AllBackupJobs {
    if (-not $script:ActiveRing) {
        Write-Host "No ring selected!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "     ALL BACKUP JOBS" -ForegroundColor Cyan
    Write-Host "     $($script:ActiveRing.Name)" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    # Get all peers
    $peers = Get-TailscalePeersByTag -Tag $script:ActiveRing.Tag
    
    if ($peers.Count -eq 0) {
        Write-Host "No peers found!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }
    
    Write-Host "Scanning $($peers.Count) peer(s) for backup jobs..." -ForegroundColor Gray
    Write-Host ""
    
    # Collect all jobs from all peers
    $allJobs = @()
    $locations = @{}
    $applications = @{}
    
    foreach ($peer in $peers) {
        Write-Host "  $($peer.HostName)..." -ForegroundColor Gray -NoNewline
        
        if (-not $peer.Online -and -not $peer.IsSelf) {
            Write-Host " OFFLINE" -ForegroundColor Red
            continue
        }
        
        # Skip self for now (can't connect to own share easily)
        if ($peer.IsSelf) {
            Write-Host " (self - reading local)" -ForegroundColor Gray
            # Read local jobs directly
            try {
                $localJobsFile = "C:\ProgramData\VLABS_ResilienceRing\jobs.json"
                if (Test-Path $localJobsFile) {
                    $localJobs = Get-Content $localJobsFile -Raw | ConvertFrom-Json
                    $config = $null
                    $configFile = "C:\ProgramData\VLABS_ResilienceRing\ring-config.json"
                    if (Test-Path $configFile) {
                        $config = Get-Content $configFile -Raw | ConvertFrom-Json
                    }
                    
                    foreach ($job in $localJobs) {
                        $location = if ($job.SourceLocation) { $job.SourceLocation } elseif ($config) { $config.Location } else { $peer.HostName }
                        $allJobs += [PSCustomObject]@{
                            Location = $location
                            AppName = $job.AppName
                            ObjectName = Split-Path $job.BackupObject -Leaf
                            BackupObject = $job.BackupObject
                            Duration = if ($job.LastDurationSeconds) { Format-Duration $job.LastDurationSeconds } else { "-" }
                            DurationSeconds = if ($job.LastDurationSeconds) { $job.LastDurationSeconds } else { 0 }
                            Size = Format-Size $job.LastSizeBytes
                            SizeBytes = if ($job.LastSizeBytes) { $job.LastSizeBytes } else { 0 }
                            Status = if ($job.LastStatus) { $job.LastStatus } else { "Never Run" }
                            LastRun = $job.LastRun
                            Enabled = $job.Enabled
                            PeerHostname = $peer.HostName
                        }
                        $locations[$location] = $true
                        $applications[$job.AppName] = $true
                    }
                }
            }
            catch { Write-Host " ERROR" -ForegroundColor Red }
            continue
        }
        
        $peerStatus = Get-PeerJobStatus -TailscaleIP $peer.TailscaleIP -CustomerCode $script:ActiveRing.CustomerCode
        
        if ($peerStatus -and $peerStatus.Jobs) {
            Write-Host " $($peerStatus.Jobs.Count) job(s)" -ForegroundColor Green
            
            foreach ($job in $peerStatus.Jobs) {
                $location = if ($job.SourceLocation) { $job.SourceLocation } else { $peerStatus.Location }
                $allJobs += [PSCustomObject]@{
                    Location = $location
                    AppName = $job.AppName
                    ObjectName = Split-Path $job.BackupObject -Leaf
                    BackupObject = $job.BackupObject
                    Duration = if ($job.LastDurationSeconds) { Format-Duration $job.LastDurationSeconds } else { "-" }
                    DurationSeconds = if ($job.LastDurationSeconds) { $job.LastDurationSeconds } else { 0 }
                    Size = Format-Size $job.LastSizeBytes
                    SizeBytes = if ($job.LastSizeBytes) { $job.LastSizeBytes } else { 0 }
                    Status = if ($job.LastStatus) { $job.LastStatus } else { "Never Run" }
                    LastRun = $job.LastRun
                    Enabled = $job.Enabled
                    PeerHostname = $peerStatus.NodeHostname
                }
                $locations[$location] = $true
                $applications[$job.AppName] = $true
            }
        }
        else {
            Write-Host " no data" -ForegroundColor Yellow
        }
    }
    
    Write-Host ""
    
    if ($allJobs.Count -eq 0) {
        Write-Host "No backup jobs found in this ring." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Jobs will appear here after peers run their first backup." -ForegroundColor Gray
        Read-Host "`nPress Enter to continue"
        return
    }
    
    # Filter options
    $filterLocation = $null
    $filterApp = $null
    
    Write-Host "Found $($allJobs.Count) backup job(s)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Filter options:" -ForegroundColor Yellow
    Write-Host "  L = Filter by Location" -ForegroundColor Gray
    Write-Host "  A = Filter by Application" -ForegroundColor Gray
    Write-Host "  Enter = Show all" -ForegroundColor Gray
    Write-Host ""
    $filterChoice = Read-Host "Filter"
    
    if ($filterChoice.ToUpper() -eq 'L' -and $locations.Count -gt 0) {
        Write-Host ""
        Write-Host "Locations:" -ForegroundColor Yellow
        $i = 1
        $locList = @($locations.Keys | Sort-Object)
        foreach ($loc in $locList) {
            Write-Host "  $i. $loc" -ForegroundColor White
            $i++
        }
        $locChoice = Read-Host "Select location (number)"
        $locIndex = 0
        if ([int]::TryParse($locChoice, [ref]$locIndex) -and $locIndex -ge 1 -and $locIndex -le $locList.Count) {
            $filterLocation = $locList[$locIndex - 1]
        }
    }
    elseif ($filterChoice.ToUpper() -eq 'A' -and $applications.Count -gt 0) {
        Write-Host ""
        Write-Host "Applications:" -ForegroundColor Yellow
        $i = 1
        $appList = @($applications.Keys | Sort-Object)
        foreach ($app in $appList) {
            Write-Host "  $i. $app" -ForegroundColor White
            $i++
        }
        $appChoice = Read-Host "Select application (number)"
        $appIndex = 0
        if ([int]::TryParse($appChoice, [ref]$appIndex) -and $appIndex -ge 1 -and $appIndex -le $appList.Count) {
            $filterApp = $appList[$appIndex - 1]
        }
    }
    
    # Apply filters
    $filteredJobs = $allJobs
    if ($filterLocation) {
        $filteredJobs = $filteredJobs | Where-Object { $_.Location -eq $filterLocation }
    }
    if ($filterApp) {
        $filteredJobs = $filteredJobs | Where-Object { $_.AppName -eq $filterApp }
    }
    
    # Display results
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "     ALL BACKUP JOBS" -ForegroundColor Cyan
    Write-Host "     $($script:ActiveRing.Name)" -ForegroundColor Cyan
    if ($filterLocation) { Write-Host "     Location: $filterLocation" -ForegroundColor Gray }
    if ($filterApp) { Write-Host "     Application: $filterApp" -ForegroundColor Gray }
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    # Table header
    Write-Host ("{0,-20} {1,-25} {2,-10} {3,-10} {4,-10}" -f "Location", "Object Name", "Duration", "Size", "Status") -ForegroundColor White
    Write-Host ("{0,-20} {1,-25} {2,-10} {3,-10} {4,-10}" -f "--------------------", "-------------------------", "----------", "----------", "----------") -ForegroundColor Gray
    
    foreach ($job in ($filteredJobs | Sort-Object Location, AppName)) {
        $statusColor = switch ($job.Status) {
            "Success" { "Green" }
            "Failed" { "Red" }
            "Running" { "Yellow" }
            default { "Gray" }
        }
        
        $locDisplay = $job.Location
        if ($locDisplay.Length -gt 20) { $locDisplay = $locDisplay.Substring(0,17) + "..." }
        
        $objDisplay = $job.ObjectName
        if ($objDisplay.Length -gt 25) { $objDisplay = $objDisplay.Substring(0,22) + "..." }
        
        Write-Host ("{0,-20} {1,-25} {2,-10} {3,-10} " -f $locDisplay, $objDisplay, $job.Duration, $job.Size) -NoNewline
        Write-Host ("{0,-10}" -f $job.Status) -ForegroundColor $statusColor
    }
    
    Write-Host ""
    Write-Host "Total: $($filteredJobs.Count) job(s)" -ForegroundColor Cyan
    
    Read-Host "`nPress Enter to continue"
}

function Show-PeerHealth {
    if (-not $script:ActiveRing) {
        Write-Host "No ring selected!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "     PEER HEALTH" -ForegroundColor Cyan
    Write-Host "     $($script:ActiveRing.Name)" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    Write-Host "This feature will show detailed health for each peer." -ForegroundColor Yellow
    Write-Host "Coming in next version!" -ForegroundColor Gray
    Write-Host ""

    Read-Host "Press Enter to continue"
}

function Invoke-RingRescan {
    <#
    .SYNOPSIS
        Rescans the active ring to refresh peer data
    #>
    if (-not $script:ActiveRing) {
        Write-Host "No ring selected!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "     RESCAN RING" -ForegroundColor Cyan
    Write-Host "     $($script:ActiveRing.Name)" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    # Get fresh peer list from Tailscale
    Write-Host "Scanning Tailscale for peers with tag: $($script:ActiveRing.Tag)" -ForegroundColor Gray
    $peers = Get-TailscalePeersByTag -Tag $script:ActiveRing.Tag

    if ($peers.Count -eq 0) {
        Write-Host "`nNo peers found with tag: $($script:ActiveRing.Tag)" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    $onlineCount = ($peers | Where-Object { $_.Online }).Count
    
    Write-Host ""
    Write-Host "Found $($peers.Count) peer(s), $onlineCount online:" -ForegroundColor Green
    Write-Host ""

    foreach ($peer in $peers) {
        $status = if ($peer.Online) { "[ONLINE]" } else { "[OFFLINE]" }
        $statusColor = if ($peer.Online) { "Green" } else { "Red" }
        Write-Host "  $($peer.HostName.PadRight(25)) $($peer.TailscaleIP.PadRight(18)) " -NoNewline
        Write-Host $status -ForegroundColor $statusColor
    }

    # Update saved ring data
    [array]$rings = @(Get-SavedRings)
    for ($i = 0; $i -lt $rings.Count; $i++) {
        if ($rings[$i].Tag -eq $script:ActiveRing.Tag) {
            $rings[$i].PeerCount = $peers.Count
            $rings[$i].LastScan = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $script:ActiveRing = $rings[$i]
            Save-Rings -Rings $rings
            break
        }
    }

    Write-Host ""
    Write-Host "Ring data updated." -ForegroundColor Green
    Write-Log "Rescanned ring $($script:ActiveRing.Name): $($peers.Count) peers, $onlineCount online" -Level INFO

    Read-Host "`nPress Enter to continue"
}

function Show-RingPolicies {
    <#
    .SYNOPSIS
        Manage retention policies for the active ring
    #>
    if (-not $script:ActiveRing) {
        Write-Host "No ring selected!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    while ($true) {
        Clear-Host
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "     RING POLICIES" -ForegroundColor Cyan
        Write-Host "     $($script:ActiveRing.Name)" -ForegroundColor Cyan
        Write-Host "========================================`n" -ForegroundColor Cyan

        # Get current policies (or defaults)
        $policies = Get-RingPolicies -Ring $script:ActiveRing
        
        Write-Host "RETENTION LIMITS" -ForegroundColor Yellow
        Write-Host "These limits apply to all backup jobs in this ring." -ForegroundColor Gray
        Write-Host "Clients auto-correct to these limits after successful backups." -ForegroundColor Gray
        Write-Host ""
        
        Write-Host "Category     Min   Max   Description" -ForegroundColor Cyan
        Write-Host "--------     ---   ---   -----------" -ForegroundColor Gray
        Write-Host "Monthly      $($policies.RetentionMonthlyMin.ToString().PadLeft(3))   $($policies.RetentionMonthlyMax.ToString().PadLeft(3))   End of month copies" -ForegroundColor White
        Write-Host "Weekly       $($policies.RetentionWeeklyMin.ToString().PadLeft(3))   $($policies.RetentionWeeklyMax.ToString().PadLeft(3))   Saturday copies" -ForegroundColor White
        Write-Host "Recent       $($policies.RetentionRecentMin.ToString().PadLeft(3))   $($policies.RetentionRecentMax.ToString().PadLeft(3))   Rolling backups (min always 1)" -ForegroundColor White
        
        Write-Host ""
        Write-Host "OPTIONS" -ForegroundColor Yellow
        Write-Host "  1. Edit Retention Limits" -ForegroundColor White
        Write-Host "  2. Publish Policies to All Peers" -ForegroundColor White
        Write-Host "  0. Back to Main Menu" -ForegroundColor White
        Write-Host ""
        
        $choice = Read-Host "Enter your choice"
        
        switch ($choice) {
            "1" { Edit-RingPolicies }
            "2" { Publish-RingPoliciesToPeers }
            "0" { return }
            default { Write-Host "Invalid choice!" -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

function Get-RingPolicies {
    <#
    .SYNOPSIS
        Gets policies for a ring, or returns defaults
    #>
    param($Ring)
    
    # Default policies
    $defaults = @{
        RetentionMonthlyMin = 0
        RetentionMonthlyMax = 3
        RetentionWeeklyMin = 0
        RetentionWeeklyMax = 4
        RetentionRecentMin = 1   # Always minimum 1
        RetentionRecentMax = 6
    }
    
    # Check if ring has policies stored
    if ($Ring.Policies) {
        # Merge with defaults (in case new policy fields added)
        foreach ($key in $defaults.Keys) {
            if ($null -eq $Ring.Policies.$key) {
                $Ring.Policies | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
            }
        }
        return $Ring.Policies
    }
    
    return [PSCustomObject]$defaults
}

function Edit-RingPolicies {
    <#
    .SYNOPSIS
        Edit retention limits for the active ring
    #>
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "     EDIT RETENTION LIMITS" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    $policies = Get-RingPolicies -Ring $script:ActiveRing
    
    Write-Host "Enter new values (press Enter to keep current value)" -ForegroundColor Gray
    Write-Host ""
    
    # Monthly
    Write-Host "MONTHLY (end of month copies)" -ForegroundColor Yellow
    $newMonthlyMin = Read-Host "  Min [$($policies.RetentionMonthlyMin)]"
    $newMonthlyMax = Read-Host "  Max [$($policies.RetentionMonthlyMax)]"
    
    if ([string]::IsNullOrWhiteSpace($newMonthlyMin)) { $newMonthlyMin = $policies.RetentionMonthlyMin }
    if ([string]::IsNullOrWhiteSpace($newMonthlyMax)) { $newMonthlyMax = $policies.RetentionMonthlyMax }
    
    # Weekly
    Write-Host ""
    Write-Host "WEEKLY (Saturday copies)" -ForegroundColor Yellow
    $newWeeklyMin = Read-Host "  Min [$($policies.RetentionWeeklyMin)]"
    $newWeeklyMax = Read-Host "  Max [$($policies.RetentionWeeklyMax)]"
    
    if ([string]::IsNullOrWhiteSpace($newWeeklyMin)) { $newWeeklyMin = $policies.RetentionWeeklyMin }
    if ([string]::IsNullOrWhiteSpace($newWeeklyMax)) { $newWeeklyMax = $policies.RetentionWeeklyMax }
    
    # Recent
    Write-Host ""
    Write-Host "RECENT (rolling backups, min always 1)" -ForegroundColor Yellow
    $newRecentMin = Read-Host "  Min (1 or higher) [$($policies.RetentionRecentMin)]"
    $newRecentMax = Read-Host "  Max [$($policies.RetentionRecentMax)]"
    
    if ([string]::IsNullOrWhiteSpace($newRecentMin)) { $newRecentMin = $policies.RetentionRecentMin }
    if ([string]::IsNullOrWhiteSpace($newRecentMax)) { $newRecentMax = $policies.RetentionRecentMax }
    
    # Validate
    $valid = $true
    
    if ([int]$newRecentMin -lt 1) {
        Write-Host "`nError: Recent Min must be at least 1!" -ForegroundColor Red
        $valid = $false
    }
    
    if ([int]$newMonthlyMin -gt [int]$newMonthlyMax) {
        Write-Host "Error: Monthly Min cannot exceed Max!" -ForegroundColor Red
        $valid = $false
    }
    if ([int]$newWeeklyMin -gt [int]$newWeeklyMax) {
        Write-Host "Error: Weekly Min cannot exceed Max!" -ForegroundColor Red
        $valid = $false
    }
    if ([int]$newRecentMin -gt [int]$newRecentMax) {
        Write-Host "Error: Recent Min cannot exceed Max!" -ForegroundColor Red
        $valid = $false
    }
    
    if (-not $valid) {
        Read-Host "`nPress Enter to try again"
        return
    }
    
    # Save policies
    $newPolicies = @{
        RetentionMonthlyMin = [int]$newMonthlyMin
        RetentionMonthlyMax = [int]$newMonthlyMax
        RetentionWeeklyMin = [int]$newWeeklyMin
        RetentionWeeklyMax = [int]$newWeeklyMax
        RetentionRecentMin = [int]$newRecentMin
        RetentionRecentMax = [int]$newRecentMax
    }
    
    # Update ring in saved rings
    $rings = Get-SavedRings
    for ($i = 0; $i -lt $rings.Count; $i++) {
        if ($rings[$i].Tag -eq $script:ActiveRing.Tag) {
            $rings[$i] | Add-Member -NotePropertyName 'Policies' -NotePropertyValue ([PSCustomObject]$newPolicies) -Force
            $script:ActiveRing = $rings[$i]
            break
        }
    }
    Save-Rings -Rings $rings
    
    Write-Host ""
    Write-Host "Policies saved!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Note: Use 'Publish Policies to All Peers' to push these limits to clients." -ForegroundColor Cyan
    
    Read-Host "`nPress Enter to continue"
}

function Publish-RingPoliciesToPeers {
    <#
    .SYNOPSIS
        Publishes ring policies to all peers' _nodeinfo folders
    #>
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "     PUBLISH RING POLICIES" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    $policies = Get-RingPolicies -Ring $script:ActiveRing
    
    Write-Host "This will write ring-policies.json to all peers in the ring." -ForegroundColor Gray
    Write-Host "Clients will auto-enforce these limits after their next successful backup." -ForegroundColor Gray
    Write-Host ""
    
    $confirm = Read-Host "Continue? [Y/n]"
    if ($confirm -match '^[Nn]') {
        return
    }
    
    Write-Host ""
    Write-Host "Discovering peers..." -ForegroundColor Gray
    
    $peers = Get-TailscalePeersByTag -Tag $script:ActiveRing.Tag
    $successCount = 0
    $failCount = 0
    
    foreach ($peer in $peers) {
        Write-Host "  $($peer.HostName)... " -NoNewline
        
        try {
            # Connect to peer's share
            $sharePath = "\\$($peer.TailscaleIP)\RR_Backups"
            $password = Get-RRMServicePassword -CustomerCode $script:ActiveRing.CustomerCode
            
            # Build credential
            $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential("RR_Service", $securePassword)
            
            # Test/mount share
            $testResult = Test-Path $sharePath -ErrorAction SilentlyContinue
            if (-not $testResult) {
                # Try mounting with credentials
                $netUseResult = net use $sharePath /user:RR_Service $password 2>&1
            }
            
            $nodeInfoPath = Join-Path $sharePath "_nodeinfo"
            if (-not (Test-Path $nodeInfoPath)) {
                New-Item -Path $nodeInfoPath -ItemType Directory -Force | Out-Null
            }
            
            $policyFile = Join-Path $nodeInfoPath "ring-policies.json"
            
            $policyData = @{
                RingName = $script:ActiveRing.Name
                CustomerCode = $script:ActiveRing.CustomerCode
                UpdatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                Policies = $policies
            }
            
            $policyData | ConvertTo-Json -Depth 10 | Set-Content $policyFile -Force
            
            Write-Host "OK" -ForegroundColor Green
            $successCount++
        }
        catch {
            Write-Host "FAILED" -ForegroundColor Red
            $failCount++
        }
        finally {
            # Disconnect share
            net use $sharePath /delete 2>&1 | Out-Null
        }
    }
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Results: $successCount succeeded, $failCount failed" -ForegroundColor $(if($failCount -eq 0){"Green"}else{"Yellow"})
    Write-Host "========================================" -ForegroundColor Cyan
    
    Write-Log "Published ring policies to $successCount/$($peers.Count) peers" -Level INFO
    
    Read-Host "`nPress Enter to continue"
}

function Invoke-BackupVerification {
    <#
    .SYNOPSIS
        Verifies SHA256 manifests for all backup snapshots on a selected peer
    #>
    if (-not $script:ActiveRing) {
        Write-Host "No ring selected!" -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  BACKUP INTEGRITY VERIFICATION" -ForegroundColor Cyan
    Write-Host "  $($script:ActiveRing.Name)" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    $peers = @(Get-TailscalePeersByTag -Tag $script:ActiveRing.Tag | Where-Object { $_.Online -and -not $_.IsSelf })

    if ($peers.Count -eq 0) {
        Write-Host "No online storage peers found." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    Write-Host "Online peers:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $peers.Count; $i++) {
        Write-Host "  $($i+1). $($peers[$i].HostName) ($($peers[$i].TailscaleIP))" -ForegroundColor White
    }
    Write-Host "  A. All peers" -ForegroundColor White
    Write-Host ""
    $peerChoice = Read-Host "Select peer"

    $selected = if ($peerChoice.ToUpper() -eq 'A') {
        $peers
    } elseif ($peerChoice -match '^\d+$') {
        $idx = [int]$peerChoice - 1
        if ($idx -ge 0 -and $idx -lt $peers.Count) { @($peers[$idx]) } else { $null }
    } else { $null }

    if (-not $selected) {
        Write-Host "Invalid selection." -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }

    Write-Host ""
    $totalOk = 0; $totalFail = 0; $totalOld = 0

    foreach ($peer in $selected) {
        Write-Host "Peer: $($peer.HostName)" -ForegroundColor Cyan
        $sharePath = "\\$($peer.TailscaleIP)\RR_Backups"
        $password  = Get-RRMServicePassword -CustomerCode $script:ActiveRing.CustomerCode

        $netResult = cmd /c "net use `"$sharePath`" /user:RR_Service `"$password`" 2>&1"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  Cannot connect: $netResult" -ForegroundColor Red
            continue
        }

        try {
            $customerPath = Join-Path $sharePath $script:ActiveRing.CustomerCode.ToUpper()
            if (-not (Test-Path $customerPath -ErrorAction SilentlyContinue)) {
                Write-Host "  No backups found for this ring." -ForegroundColor Yellow
                continue
            }

            # Walk structure: customerPath\location\appname\type\snapshot
            $snapshots = @()
            foreach ($loc in @(Get-ChildItem $customerPath -Directory -ErrorAction SilentlyContinue)) {
                foreach ($app in @(Get-ChildItem $loc.FullName -Directory -ErrorAction SilentlyContinue)) {
                    foreach ($type in @(Get-ChildItem $app.FullName -Directory -ErrorAction SilentlyContinue)) {
                        $snapshots += @(Get-ChildItem $type.FullName -Directory -ErrorAction SilentlyContinue)
                    }
                }
            }

            if ($snapshots.Count -eq 0) {
                Write-Host "  No backup snapshots found." -ForegroundColor Yellow
                continue
            }

            Write-Host "  Checking $($snapshots.Count) snapshot(s)..." -ForegroundColor Gray

            foreach ($snap in ($snapshots | Sort-Object FullName)) {
                $manifestPath = Join-Path $snap.FullName "_manifest.sha256"
                $label = "$($snap.Parent.Parent.Name)\$($snap.Parent.Name)\$($snap.Name)"

                if (-not (Test-Path $manifestPath -PathType Leaf)) {
                    Write-Host "  [---] $label" -ForegroundColor DarkGray
                    $totalOld++
                    continue
                }

                $entries = @(Get-Content $manifestPath -ErrorAction SilentlyContinue |
                             Where-Object { $_ -match '^[0-9A-Fa-f]{64}\s+\S' })

                $failures = 0
                foreach ($line in $entries) {
                    $parts   = $line -split '\s+', 2
                    $expected = $parts[0].ToUpper()
                    $filePath = Join-Path $snap.FullName $parts[1]

                    if (-not (Test-Path $filePath -PathType Leaf)) {
                        $failures++
                        continue
                    }
                    $actual = (Get-FileHash -Path $filePath -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
                    if ($actual -ne $expected) { $failures++ }
                }

                if ($failures -eq 0) {
                    Write-Host "  [OK]  $label  ($($entries.Count) files)" -ForegroundColor Green
                    $totalOk++
                } else {
                    Write-Host "  [FAIL] $label  — $failures/$($entries.Count) files corrupt/missing" -ForegroundColor Red
                    $totalFail++
                }
            }
        }
        finally {
            net use $sharePath /delete 2>&1 | Out-Null
        }

        Write-Host ""
    }

    Write-Host "----------------------------------------" -ForegroundColor Gray
    $summaryColor = if ($totalFail -gt 0) { 'Red' } elseif ($totalOk -gt 0) { 'Green' } else { 'Gray' }
    Write-Host "  OK: $totalOk   FAILED: $totalFail   No manifest (pre-1.9.63): $totalOld" -ForegroundColor $summaryColor
    Write-Host ""
    Read-Host "Press Enter to continue"
}

#endregion

#region Ring Selector

function Show-RingSelector {
    <#
    .SYNOPSIS
        Shows ring selector at startup and returns selected ring
    #>

    # Force array context to handle single-ring case
    [array]$rings = @(Get-SavedRings)

    if ($rings.Count -eq 0) {
        Write-Host "No rings configured yet." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Would you like to connect to a ring now? [Y/n]: " -NoNewline
        $response = Read-Host

        if ($response -eq '' -or $response -match '^[Yy]') {
            Connect-ToNewRing
            [array]$rings = @(Get-SavedRings)
        }

        if ($rings.Count -eq 0) {
            return $null
        }
    }

    # Quick scan all rings for peer count
    Write-Host "Scanning rings..." -ForegroundColor Gray

    foreach ($ring in $rings) {
        Write-Host "  $($ring.Name)..." -ForegroundColor Gray -NoNewline
        $peers = Get-TailscalePeersByTag -Tag $ring.Tag
        $ring.PeerCount = $peers.Count
        $online = ($peers | Where-Object { $_.Online }).Count
        Write-Host " $online/$($peers.Count) online" -ForegroundColor $(if ($online -eq $peers.Count) { "Green" } else { "Yellow" })
    }

    Save-Rings -Rings $rings

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "     SELECT WORKING RING" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $i = 1
    foreach ($ring in $rings) {
        Write-Host "  $i. $($ring.Name) ($($ring.Tag)) - $($ring.PeerCount) peers" -ForegroundColor White
        $i++
    }

    Write-Host ""
    Write-Host "  4. Connect to new ring" -ForegroundColor Gray
    Write-Host "  0. Exit" -ForegroundColor Gray
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Select ring"

        if ($choice -eq '0') {
            return $null
        }

        if ($choice -eq '4') {
            Connect-ToNewRing
            return Show-RingSelector  # Recurse to show updated list
        }

        $index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $rings.Count) {
            return $rings[$index - 1]
        }

        Write-Host "Invalid choice. Try again." -ForegroundColor Yellow
    }
}

#endregion

#region Main Menu

function Show-MainMenu {
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  VLABS RESILIENCE RING MANAGER" -ForegroundColor Cyan
    Write-Host "            v$script:AppVersion" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    if ($script:ActiveRing) {
        Write-Host ""
        Write-Host "  Working Ring: " -NoNewline -ForegroundColor Gray
        Write-Host "$($script:ActiveRing.Name)" -ForegroundColor Yellow
        Write-Host "  Tag: $($script:ActiveRing.Tag)" -ForegroundColor Gray
    }

    Write-Host "`n----------------------------------------" -ForegroundColor Gray

    Write-Host ""
    Write-Host " RING DATA" -ForegroundColor Yellow
    Write-Host "   1. Show Ring Statistics" -ForegroundColor White
    Write-Host "   2. Show All Backup Jobs" -ForegroundColor White
    Write-Host "   3. Show Peer Health" -ForegroundColor White

    Write-Host ""
    Write-Host " RING MANAGEMENT" -ForegroundColor Yellow
    Write-Host "   4. Connect to New Ring" -ForegroundColor White
    Write-Host "   5. Show All Connected Rings" -ForegroundColor White
    Write-Host "   6. Rescan Ring" -ForegroundColor White
    Write-Host "   7. Ring Policies" -ForegroundColor White

    Write-Host ""
    Write-Host " MAINTENANCE" -ForegroundColor Yellow
    Write-Host "   8. Verify Backup Integrity" -ForegroundColor White

    Write-Host ""
    Write-Host " SYSTEM" -ForegroundColor Yellow
    Write-Host "   U. Check for Updates" -ForegroundColor White
    Write-Host "   0. Exit (to switch ring)" -ForegroundColor White

    Write-Host "`n========================================" -ForegroundColor Cyan
}

function Start-MainLoop {
    while ($true) {
        Show-MainMenu
        $choice = Read-Host "`nEnter your choice"

        switch ($choice.ToUpper()) {
            "1" { Show-RingStatistics }
            "2" { Show-AllBackupJobs }
            "3" { Show-PeerHealth }
            "4" { Connect-ToNewRing }
            "5" { Show-AllRings }
            "6" { Invoke-RingRescan }
            "7" { Show-RingPolicies }
            "8" { Invoke-BackupVerification }
            "U" { Invoke-RRMUpdate }
            "0" {
                Write-Host "`nExiting Ring Manager..." -ForegroundColor Cyan
                Write-Log "Application closed" -Level INFO
                exit 0
            }
            default {
                Write-Host "`nInvalid choice!" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

#endregion

#region Main Entry Point

Clear-Host
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  VLABS RESILIENCE RING MANAGER" -ForegroundColor Cyan
Write-Host "            v$script:AppVersion" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: Must run as Administrator!" -ForegroundColor Red
    Read-Host "`nPress Enter to exit"
    exit 1
}
Write-Host "[OK] Running as Administrator" -ForegroundColor Green

# Initialize data directory
if (-not (Test-Path $script:DataPath)) {
    New-Item -Path $script:DataPath -ItemType Directory -Force | Out-Null
}
Write-Host "[OK] Data directory ready" -ForegroundColor Green

# Check Tailscale
$tsStatus = Test-TailscaleReady
if ($tsStatus.Ready) {
    Write-Host "[OK] Tailscale connected" -ForegroundColor Green
}
else {
    Write-Host "[WARN] $($tsStatus.Reason)" -ForegroundColor Yellow
}

# Check for updates
if (-not $SkipUpdateCheck) {
    $updateInfo = Test-RRMUpdateAvailable
    if ($updateInfo.Available) {
        Write-Host ""
        Write-Host "Update available! Use 'U' from menu to update." -ForegroundColor Yellow
    }
}

Write-Host ""

# Select working ring
$script:ActiveRing = Show-RingSelector

if (-not $script:ActiveRing) {
    Write-Host "No ring selected. Exiting." -ForegroundColor Yellow
    exit 0
}

Write-Log "Selected ring: $($script:ActiveRing.Name)" -Level INFO

# Quick startup rescan
Write-Host ""
Write-Host "Scanning ring peers..." -ForegroundColor Gray
$startupPeers = Get-TailscalePeersByTag -Tag $script:ActiveRing.Tag
$startupOnline = ($startupPeers | Where-Object { $_.Online }).Count
Write-Host "  $($startupPeers.Count) peers found, $startupOnline online" -ForegroundColor $(if ($startupOnline -eq $startupPeers.Count) { "Green" } else { "Yellow" })

# Update ring data
[array]$rings = @(Get-SavedRings)
for ($i = 0; $i -lt $rings.Count; $i++) {
    if ($rings[$i].Tag -eq $script:ActiveRing.Tag) {
        $rings[$i].PeerCount = $startupPeers.Count
        $rings[$i].LastScan = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $script:ActiveRing = $rings[$i]
        Save-Rings -Rings $rings
        break
    }
}

Write-Host ""
Write-Host "Press any key to continue..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

# Start main loop
Start-MainLoop

#endregion
