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
$script:AppVersion = '1.0.3'
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
    try {
        $versionUrl = "https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/rrm-version.txt"
        $latestVersion = (Invoke-RestMethod -Uri $versionUrl -UseBasicParsing -TimeoutSec 10).Trim()
        return $latestVersion
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
        
        foreach ($peerProp in $status.Peer.PSObject.Properties) {
            $peer = $peerProp.Value
            
            # Check if peer has the tag
            if ($peer.Tags -and ($peer.Tags -contains $Tag -or $peer.Tags -contains "tag:$Tag")) {
                $peers += [PSCustomObject]@{
                    ID = $peerProp.Name
                    HostName = $peer.HostName
                    DNSName = $peer.DNSName
                    TailscaleIP = $peer.TailscaleIPs[0]
                    OS = $peer.OS
                    Online = $peer.Online
                    LastSeen = $peer.LastSeen
                    Tags = $peer.Tags
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
            $netResult = net use $sharePath /user:RR_Service $password 2>&1
            if ($LASTEXITCODE -ne 0) {
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
            # Calculate storage used
            $size = (Get-ChildItem $customerPath -Recurse -File -ErrorAction SilentlyContinue | 
                     Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            $result.StorageUsedGB = [math]::Round(($size / 1GB), 2)
        }
        
        # Try to read peer's config from ProgramData share (if accessible)
        # For now, we just calculate storage
        
    }
    catch {
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
            Status = "Unknown"
        }
        
        if ($peer.Online) {
            $stats.OnlinePeers++
            
            # Get peer data
            $peerData = Get-PeerData -TailscaleIP $peer.TailscaleIP -CustomerCode $CustomerCode
            
            if ($peerData.Connected) {
                $peerStats.StorageUsedGB = $peerData.StorageUsedGB
                $peerStats.Status = "OK"
                $stats.TotalUsedGB += $peerData.StorageUsedGB
                Write-Host " OK ($($peerData.StorageUsedGB) GB)" -ForegroundColor Green
            }
            else {
                $peerStats.Status = "Connection Failed"
                $stats.Problems += "Cannot connect to $($peer.HostName)"
                Write-Host " CONN FAILED" -ForegroundColor Red
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
    
    $customerCode = $customerCode.Trim().ToUpper()
    
    # Get friendly name
    Write-Host ""
    Write-Host "Enter a friendly name for this ring (or press Enter to use '$customerCode')" -ForegroundColor White
    $ringName = Read-Host "Ring Name"
    if ([string]::IsNullOrWhiteSpace($ringName)) { $ringName = $customerCode }
    
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
    Write-Host "  Hostname              | IP               | Status    | Storage" -ForegroundColor Gray
    Write-Host "  ----------------------|------------------|-----------|--------" -ForegroundColor Gray
    
    foreach ($peer in $stats.Peers) {
        $statusColor = switch ($peer.Status) {
            "OK" { "Green" }
            "Offline" { "Red" }
            default { "Yellow" }
        }
        
        Write-Host ("  {0,-21} | {1,-16} | " -f 
            $peer.Hostname.Substring(0, [Math]::Min(21, $peer.Hostname.Length)),
            $peer.TailscaleIP) -NoNewline
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
    
    Write-Host "This feature will scan all peers and aggregate backup jobs." -ForegroundColor Yellow
    Write-Host "Coming in next version!" -ForegroundColor Gray
    Write-Host ""
    
    # TODO: Iterate peers, read their jobs.json, aggregate
    
    Read-Host "Press Enter to continue"
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
    Write-Host "  C. Connect to new ring" -ForegroundColor Gray
    Write-Host "  0. Exit" -ForegroundColor Gray
    Write-Host ""
    
    while ($true) {
        $choice = Read-Host "Select ring"
        
        if ($choice -eq '0') {
            return $null
        }
        
        if ($choice.ToUpper() -eq 'C') {
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
    Write-Host "   C. Connect to New Ring" -ForegroundColor White
    Write-Host "   5. Show All Connected Rings" -ForegroundColor White
    
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
            "C" { Connect-ToNewRing }
            "5" { Show-AllRings }
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

# Start main loop
Start-MainLoop

#endregion
