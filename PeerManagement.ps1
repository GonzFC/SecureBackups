#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Peer Management Module for VLABS Resilience Ring
    
.DESCRIPTION
    Manages Storage Peers in the distributed backup mesh.
    - Tailscale installation & configuration
    - Peer discovery via `tailscale status`
    - Peer health monitoring & scoring
    - Automatic peer selection for destinations
#>

# Paths
$script:BaseDataPath = "C:\VLABS_ResilienceRing"
$script:PeersFile = Join-Path $PSScriptRoot "peers.json"  # Local tailscale peers cache
$script:ConfigFile = Join-Path $script:BaseDataPath "ring-config.json"

# Ensure base data path exists
if (-not (Test-Path $script:BaseDataPath)) {
    New-Item -Path $script:BaseDataPath -ItemType Directory -Force | Out-Null
}

function Get-RingDataPath {
    <#
    .SYNOPSIS
        Gets the path for ring data storage for a specific customer code
    #>
    param([string]$CustomerCode)
    
    $path = Join-Path $script:BaseDataPath "ring-data\$CustomerCode"
    if (-not (Test-Path $path)) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }
    return $path
}

function Get-StoragePeersFile {
    <#
    .SYNOPSIS
        Gets the path to the storage peers list for the current customer
    #>
    $code = Get-LocalCustomerCode
    if (-not $code) { return $null }
    
    $ringPath = Get-RingDataPath -CustomerCode $code
    return Join-Path $ringPath "storage-peers.json"
}

function Save-StoragePeersList {
    <#
    .SYNOPSIS
        Saves the storage peers list locally and to the shared storage for replication
    #>
    param([array]$Peers)
    
    $code = Get-LocalCustomerCode
    if (-not $code) { return }
    
    $peerData = @{
        CustomerCode = $code
        LastUpdated = (Get-Date).ToString('o')
        UpdatedBy = $env:COMPUTERNAME
        Peers = $Peers
    }
    
    # Save locally
    $localFile = Get-StoragePeersFile
    if ($localFile) {
        $peerData | ConvertTo-Json -Depth 10 | Set-Content $localFile -Force
    }
    
    # Also save to our shared storage for other peers to read
    $config = Get-Content $script:ConfigFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($config -and $config.StoragePath) {
        $sharedRingPath = Join-Path $config.StoragePath "ring-data\$code"
        if (-not (Test-Path $sharedRingPath)) {
            New-Item -Path $sharedRingPath -ItemType Directory -Force | Out-Null
        }
        $sharedFile = Join-Path $sharedRingPath "storage-peers.json"
        $peerData | ConvertTo-Json -Depth 10 | Set-Content $sharedFile -Force
    }
}

function Sync-StoragePeersList {
    <#
    .SYNOPSIS
        Syncs the storage peers list from all known peers, merging into a master list
    #>
    $code = Get-LocalCustomerCode
    if (-not $code) { return @() }
    
    $allPeers = @{}  # Use hashtable to dedupe by TailscaleIP
    
    # Load local list first
    $localFile = Get-StoragePeersFile
    if ($localFile -and (Test-Path $localFile)) {
        $localData = Get-Content $localFile -Raw | ConvertFrom-Json
        foreach ($peer in $localData.Peers) {
            $allPeers[$peer.TailscaleIP] = $peer
        }
    }
    
    # Try to read from each known peer's shared storage
    $tailscalePeers = Get-Content $script:PeersFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    
    foreach ($tsPeer in $tailscalePeers) {
        $remotePath = "\\$($tsPeer.TailscaleIP)\Backups\ring-data\$code\storage-peers.json"
        
        try {
            $job = Start-Job -ScriptBlock {
                param($path)
                if (Test-Path $path) { Get-Content $path -Raw }
            } -ArgumentList $remotePath
            
            $completed = Wait-Job $job -Timeout 2
            if ($completed) {
                $content = Receive-Job $job
                if ($content) {
                    $remoteData = $content | ConvertFrom-Json
                    foreach ($peer in $remoteData.Peers) {
                        # Merge: keep the most recent info
                        if (-not $allPeers.ContainsKey($peer.TailscaleIP) -or 
                            $peer.LastSeen -gt $allPeers[$peer.TailscaleIP].LastSeen) {
                            $allPeers[$peer.TailscaleIP] = $peer
                        }
                    }
                }
            }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
        catch {
            # Continue on error
        }
    }
    
    return @($allPeers.Values)
}

#region Tailscale Functions

function Get-TailscaleExePath {
    <#
    .SYNOPSIS
        Finds the tailscale.exe path (MSI doesn't add to PATH)
    #>
    $candidates = @(
        'C:\Program Files\Tailscale\tailscale.exe',
        'C:\Program Files (x86)\Tailscale\tailscale.exe',
        'C:\Program Files\Tailscale IPN\tailscale.exe'
    )
    
    # Also check PATH
    $inPath = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    
    return $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Test-TailscaleInstalled {
    <#
    .SYNOPSIS
        Checks if Tailscale is installed and running
    #>
    $tailscaleExe = Get-TailscaleExePath
    if (-not $tailscaleExe) {
        return @{ Installed = $false; Running = $false; Connected = $false }
    }
    
    try {
        $status = & $tailscaleExe status --json 2>$null | ConvertFrom-Json
        $isConnected = $null -ne $status.Self.TailscaleIPs
        return @{ 
            Installed = $true
            Running = $true
            Connected = $isConnected
            Self = $status.Self
            Peers = $status.Peer
        }
    }
    catch {
        return @{ Installed = $true; Running = $false; Connected = $false }
    }
}

function Install-Tailscale {
    <#
    .SYNOPSIS
        Installs Tailscale using the auth key provided
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$AuthKey
    )
    
    Write-Host "`nInstalling Tailscale..." -ForegroundColor Cyan
    
    # Check if already installed
    $tsStatus = Test-TailscaleInstalled
    if ($tsStatus.Connected) {
        Write-Host "Tailscale already installed and connected!" -ForegroundColor Green
        Write-Host "  IP: $($tsStatus.Self.TailscaleIPs[0])" -ForegroundColor Gray
        Write-Host "  Hostname: $($tsStatus.Self.HostName)" -ForegroundColor Gray
        return $true
    }
    
    # Download and run installer from WinSrvManagementScripts logic
    try {
        Write-Host "Downloading Tailscale installer..." -ForegroundColor Gray
        
        # Get architecture
        $arch = switch ($env:PROCESSOR_ARCHITECTURE.ToLower()) {
            'amd64' { 'amd64' }
            'arm64' { 'arm64' }
            'x86'   { 'x86' }
            default { 'amd64' }
        }
        
        # Get latest MSI URL
        $indexUrl = 'https://pkgs.tailscale.com/stable/'
        $resp = Invoke-WebRequest -Uri $indexUrl -UseBasicParsing
        $msiRegex = [regex]"tailscale-setup-(?<ver>\d+\.\d+\.\d+)-$([regex]::Escape($arch))\.msi"
        $matches = $msiRegex.Matches($resp.Content) | Sort-Object { [version]$_.Groups['ver'].Value } -Descending
        
        if ($matches.Count -eq 0) {
            throw "No MSI found for architecture $arch"
        }
        
        $latestFile = $matches[0].Value
        $msiUrl = $indexUrl.TrimEnd('/') + '/' + $latestFile
        $msiPath = Join-Path $env:TEMP $latestFile
        
        Write-Host "Downloading: $latestFile" -ForegroundColor Gray
        Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
        
        Write-Host "Installing MSI (silent)..." -ForegroundColor Gray
        $proc = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "MSI installation failed with code $($proc.ExitCode)"
        }
        
        # Wait for service
        Start-Sleep -Seconds 5
        
        # Find tailscale.exe (MSI doesn't add to PATH immediately)
        $tailscaleExe = @(
            'C:\Program Files\Tailscale\tailscale.exe',
            'C:\Program Files (x86)\Tailscale\tailscale.exe'
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        
        if (-not $tailscaleExe) {
            throw "Tailscale installed but tailscale.exe not found"
        }
        
        Write-Host "Found: $tailscaleExe" -ForegroundColor Gray
        
        # Start Tailscale with auth key
        Write-Host "Authenticating with Tailscale..." -ForegroundColor Gray
        & $tailscaleExe up --authkey=$AuthKey --unattended --accept-dns=false
        
        if ($LASTEXITCODE -ne 0) {
            throw "Tailscale authentication failed (exit code: $LASTEXITCODE)"
        }
        
        # Verify connection
        Start-Sleep -Seconds 2
        $tsStatus = Test-TailscaleInstalled
        
        if ($tsStatus.Connected) {
            Write-Host "`n[OK] Tailscale installed and connected!" -ForegroundColor Green
            Write-Host "  IP: $($tsStatus.Self.TailscaleIPs[0])" -ForegroundColor Cyan
            Write-Host "  Hostname: $($tsStatus.Self.HostName)" -ForegroundColor Cyan
            return $true
        }
        else {
            throw "Tailscale installed but not connected"
        }
    }
    catch {
        Write-Host "`n[ERROR] Tailscale installation failed: $_" -ForegroundColor Red
        return $false
    }
}

#endregion

#region Peer Discovery

function Get-TailscalePeers {
    <#
    .SYNOPSIS
        Gets all visible Tailscale peers with their status
    #>
    try {
        $tailscaleExe = Get-TailscaleExePath
        if (-not $tailscaleExe) { return @() }
        
        $statusJson = & $tailscaleExe status --json 2>$null
        if (-not $statusJson) { return @() }
        
        $status = $statusJson | ConvertFrom-Json
        $peers = @()
        
        foreach ($peerKey in $status.Peer.PSObject.Properties.Name) {
            $peer = $status.Peer.$peerKey
            
            # Get first IP (usually the 100.x.x.x Tailscale IP)
            $ip = if ($peer.TailscaleIPs) { $peer.TailscaleIPs[0] } else { $null }
            
            $peers += [PSCustomObject]@{
                NodeKey = $peerKey
                HostName = $peer.HostName
                DNSName = $peer.DNSName
                TailscaleIP = $ip
                OS = $peer.OS
                Online = $peer.Online
                LastSeen = $peer.LastSeen
                Active = $peer.Active
            }
        }
        
        return $peers
    }
    catch {
        Write-Host "[ERROR] Failed to get Tailscale peers: $_" -ForegroundColor Red
        return @()
    }
}

function Test-PeerConnectivity {
    <#
    .SYNOPSIS
        Tests connectivity to a peer and returns ping time (with timeout)
    #>
    param(
        [string]$TailscaleIP
    )
    
    try {
        # Use single ping with short timeout
        $ping = Test-Connection -ComputerName $TailscaleIP -Count 1 -TimeoutSeconds 2 -ErrorAction Stop
        $avgMs = [math]::Round($ping.ResponseTime, 1)
        return @{ Success = $true; PingMs = $avgMs }
    }
    catch {
        return @{ Success = $false; PingMs = -1 }
    }
}

function Update-PeerList {
    <#
    .SYNOPSIS
        Scans for all Tailscale peers and updates the local peer list
    .PARAMETER Verbose
        If true, shows detailed progress (for admin use only)
    #>
    param(
        [switch]$ShowDetails
    )
    
    Write-Host "`nScanning network..." -ForegroundColor Cyan -NoNewline
    
    $allPeers = Get-TailscalePeers
    $onlinePeers = $allPeers | Where-Object { $_.Online -eq $true }
    
    $peerList = @()
    $reachableCount = 0
    $totalCount = $onlinePeers.Count
    
    foreach ($peer in $onlinePeers) {
        # Show progress dots (not hostnames)
        Write-Host "." -NoNewline -ForegroundColor Gray
        
        $pingResult = Test-PeerConnectivity -TailscaleIP $peer.TailscaleIP
        
        if ($pingResult.Success) {
            $reachableCount++
            
            $peerList += [PSCustomObject]@{
                NodeKey = $peer.NodeKey
                HostName = $peer.HostName
                TailscaleIP = $peer.TailscaleIP
                OS = $peer.OS
                PingMs = $pingResult.PingMs
                LastSeen = (Get-Date).ToString('o')
                IsStoragePeer = $false
                StorageConfig = $null
            }
        }
    }
    
    Write-Host "" # New line after dots
    
    # Save to file
    $peerList | ConvertTo-Json -Depth 5 | Set-Content $script:PeersFile -Force
    
    Write-Host "[OK] Found $reachableCount available storage nodes" -ForegroundColor Green
    
    return $peerList
}

#endregion

#region Storage Peer Configuration

function Add-StoragePeer {
    <#
    .SYNOPSIS
        Configures this machine as a Storage Peer in the Resilience Ring
    #>
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "    ADD STORAGE PEER" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    # Step 1: Check/Install Tailscale
    Write-Host "STEP 1: Tailscale Setup" -ForegroundColor Yellow
    Write-Host "------------------------" -ForegroundColor Yellow
    
    $tsStatus = Test-TailscaleInstalled
    
    if ($tsStatus.Connected) {
        Write-Host "[OK] Tailscale is already connected" -ForegroundColor Green
        Write-Host "  IP: $($tsStatus.Self.TailscaleIPs[0])" -ForegroundColor Gray
        Write-Host "  Hostname: $($tsStatus.Self.HostName)" -ForegroundColor Gray
    }
    else {
        Write-Host "Tailscale is not configured on this machine." -ForegroundColor Yellow
        Write-Host "`nTo join the Resilience Ring, you need a Tailscale Auth Key."
        Write-Host "Get one from: https://login.tailscale.com/admin/settings/keys"
        Write-Host "`nAuth Key (tskey-auth-...): " -NoNewline -ForegroundColor White
        $authKey = Read-Host
        
        if (-not $authKey -or $authKey -notmatch '^tskey-') {
            Write-Host "[ERROR] Invalid auth key format" -ForegroundColor Red
            Read-Host "`nPress Enter to return"
            return
        }
        
        if (-not (Install-Tailscale -AuthKey $authKey)) {
            Read-Host "`nPress Enter to return"
            return
        }
        
        $tsStatus = Test-TailscaleInstalled
    }
    
    Write-Host ""
    
    # Step 2: Customer Codename
    Write-Host "STEP 2: Customer Codename" -ForegroundColor Yellow
    Write-Host "--------------------------" -ForegroundColor Yellow
    Write-Host "Enter a 2-6 character code to identify this customer/organization."
    Write-Host "Example: vlabs, mmi, msk, gf"
    Write-Host "`nCodename: " -NoNewline -ForegroundColor White
    $codename = (Read-Host).ToLower().Trim()
    
    if ($codename.Length -lt 2 -or $codename.Length -gt 6 -or $codename -notmatch '^[a-z]+$') {
        Write-Host "[ERROR] Codename must be 2-6 lowercase letters only" -ForegroundColor Red
        Read-Host "`nPress Enter to return"
        return
    }
    
    Write-Host ""
    
    # Step 3: Storage Path
    Write-Host "STEP 3: Storage Location" -ForegroundColor Yellow
    Write-Host "-------------------------" -ForegroundColor Yellow
    
    # Show available drives with free space
    Write-Host "Available drives:" -ForegroundColor Gray
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 }
    foreach ($drive in $drives) {
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        $usedGB = [math]::Round($drive.Used / 1GB, 1)
        $totalGB = $freeGB + $usedGB
        $pctFree = [math]::Round(($freeGB / $totalGB) * 100, 0)
        Write-Host "  $($drive.Name):\ - $freeGB GB free of $totalGB GB ($pctFree% free)" -ForegroundColor Gray
    }
    
    Write-Host "`nBase storage path (e.g., D:\Backups): " -NoNewline -ForegroundColor White
    $storagePath = Read-Host
    
    if (-not $storagePath -or -not (Test-Path (Split-Path $storagePath -Qualifier))) {
        Write-Host "[ERROR] Invalid path or drive not found" -ForegroundColor Red
        Read-Host "`nPress Enter to return"
        return
    }
    
    # Create path if needed
    if (-not (Test-Path $storagePath)) {
        try {
            New-Item -Path $storagePath -ItemType Directory -Force | Out-Null
            Write-Host "[OK] Created directory: $storagePath" -ForegroundColor Green
        }
        catch {
            Write-Host "[ERROR] Could not create directory: $_" -ForegroundColor Red
            Read-Host "`nPress Enter to return"
            return
        }
    }
    
    Write-Host ""
    
    # Step 4: Quota
    Write-Host "STEP 4: Storage Quota" -ForegroundColor Yellow
    Write-Host "----------------------" -ForegroundColor Yellow
    
    $driveLetter = (Split-Path $storagePath -Qualifier).TrimEnd(':')
    $driveInfo = Get-PSDrive -Name $driveLetter
    $availableGB = [math]::Round($driveInfo.Free / 1GB, 0)
    
    Write-Host "Available space on drive: $availableGB GB"
    Write-Host "Recommended: Leave at least 20% free for system operations"
    Write-Host "`nMaximum quota for backups (GB): " -NoNewline -ForegroundColor White
    $quotaGB = [int](Read-Host)
    
    if ($quotaGB -le 0 -or $quotaGB -gt $availableGB) {
        Write-Host "[ERROR] Invalid quota. Must be between 1 and $availableGB GB" -ForegroundColor Red
        Read-Host "`nPress Enter to return"
        return
    }
    
    Write-Host ""
    
    # Step 5: Save Configuration
    Write-Host "STEP 5: Saving Configuration" -ForegroundColor Yellow
    Write-Host "-----------------------------" -ForegroundColor Yellow
    
    $config = @{
        IsStoragePeer = $true
        PeerId = $tsStatus.Self.HostName
        TailscaleIP = $tsStatus.Self.TailscaleIPs[0]
        CustomerCode = $codename
        StoragePath = $storagePath
        QuotaGB = $quotaGB
        CreatedAt = (Get-Date).ToString('o')
        JobsHosted = 0
        UsedGB = 0
    }
    
    # Save local config
    $config | ConvertTo-Json -Depth 5 | Set-Content $script:ConfigFile -Force
    
    # Create customer directory structure
    $customerPath = Join-Path $storagePath $codename
    if (-not (Test-Path $customerPath)) {
        New-Item -Path $customerPath -ItemType Directory -Force | Out-Null
    }
    
    # Create ring-data folder structure in storage
    $ringDataPath = Join-Path $storagePath "ring-data\$codename"
    if (-not (Test-Path $ringDataPath)) {
        New-Item -Path $ringDataPath -ItemType Directory -Force | Out-Null
    }
    
    # Create a peer-info file in the storage path for discovery
    $peerInfoPath = Join-Path $storagePath "peer-info.json"
    $peerInfo = @{
        CustomerCode = $codename
        TailscaleIP = $tsStatus.Self.TailscaleIPs[0]
        StoragePath = $storagePath
        QuotaGB = $quotaGB
        Version = "1.3"
    }
    $peerInfo | ConvertTo-Json | Set-Content $peerInfoPath -Force
    
    # Create SMB share for the storage path (if not exists)
    $shareName = "Backups"
    $existingShare = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
    if (-not $existingShare) {
        try {
            New-SmbShare -Name $shareName -Path $storagePath -FullAccess "Everyone" -Description "VLABS Resilience Ring Storage" | Out-Null
            Write-Host "[OK] Created network share: \\$($env:COMPUTERNAME)\$shareName" -ForegroundColor Green
        }
        catch {
            Write-Host "[WARN] Could not create SMB share automatically: $_" -ForegroundColor Yellow
            Write-Host "Please manually share '$storagePath' as '$shareName'" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "[OK] Network share already exists: \\$($env:COMPUTERNAME)\$shareName" -ForegroundColor Green
    }
    
    # Register this peer in the storage peers list
    $thisPeer = [PSCustomObject]@{
        HostName = $tsStatus.Self.HostName
        TailscaleIP = $tsStatus.Self.TailscaleIPs[0]
        CustomerCode = $codename
        PingMs = 0
        LastSeen = (Get-Date).ToString('o')
        Online = $true
        FreePct = 100
        JobsHosted = 0
        QuotaGB = $quotaGB
    }
    
    # Load existing peers and add this one
    $existingPeers = @()
    $peersFile = Join-Path $ringDataPath "storage-peers.json"
    if (Test-Path $peersFile) {
        $data = Get-Content $peersFile -Raw | ConvertFrom-Json
        $existingPeers = @($data.Peers | Where-Object { $_.TailscaleIP -ne $thisPeer.TailscaleIP })
    }
    $existingPeers += $thisPeer
    
    # Save the updated list
    Save-StoragePeersList -Peers $existingPeers
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "    STORAGE PEER CONFIGURED!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Peer ID:      $($config.PeerId)" -ForegroundColor White
    Write-Host "  Tailscale IP: $($config.TailscaleIP)" -ForegroundColor White
    Write-Host "  Customer:     $($config.CustomerCode)" -ForegroundColor White
    Write-Host "  Storage:      $($config.StoragePath)" -ForegroundColor White
    Write-Host "  Quota:        $($config.QuotaGB) GB" -ForegroundColor White
    Write-Host ""
    Write-Host "This machine is now part of the Resilience Ring!" -ForegroundColor Yellow
    Write-Host "Other peers can now select this server as a backup destination." -ForegroundColor Yellow
    
    # Update peer list to include this as a storage peer
    Update-PeerList | Out-Null
    
    Read-Host "`nPress Enter to continue"
}

function Get-LocalCustomerCode {
    <#
    .SYNOPSIS
        Gets the CustomerCode from local configuration
    #>
    if (Test-Path $script:ConfigFile) {
        $config = Get-Content $script:ConfigFile -Raw | ConvertFrom-Json
        return $config.CustomerCode
    }
    return $null
}

function Get-PeerConfig {
    <#
    .SYNOPSIS
        Attempts to read peer configuration from remote storage share (with timeout)
    #>
    param([string]$TailscaleIP)
    
    # Try to read peer-info.json from the Backups share
    $remotePath = "\\$TailscaleIP\Backups\peer-info.json"
    
    try {
        # Use a job with timeout to prevent hanging on unreachable shares
        $job = Start-Job -ScriptBlock {
            param($path)
            if (Test-Path $path) {
                Get-Content $path -Raw | ConvertFrom-Json
            }
        } -ArgumentList $remotePath
        
        # Wait max 3 seconds
        $completed = Wait-Job $job -Timeout 3
        
        if ($completed) {
            $result = Receive-Job $job
            Remove-Job $job -Force
            return $result
        }
        else {
            Stop-Job $job
            Remove-Job $job -Force
            return $null
        }
    }
    catch {
        # Silently fail - peer may not be a storage peer
        return $null
    }
}

function Get-StoragePeers {
    <#
    .SYNOPSIS
        Gets all configured storage peers with their current status and scores
        Only returns peers belonging to the same CustomerCode
        Uses replicated peer list for faster discovery
    #>
    param(
        [switch]$ForceRefresh,
        [switch]$ShowProgress
    )
    
    # Get our local CustomerCode
    $localCode = Get-LocalCustomerCode
    if (-not $localCode) {
        return @()
    }
    
    # First, try to use the replicated peer list (fast)
    $knownPeers = Sync-StoragePeersList
    
    # If no known peers or force refresh, scan the network
    if ($knownPeers.Count -eq 0 -or $ForceRefresh) {
        if (-not (Test-Path $script:PeersFile)) {
            Update-PeerList | Out-Null
        }
        
        $tailscalePeers = Get-Content $script:PeersFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        if (-not $tailscalePeers) { $tailscalePeers = @() }
        
        $discoveredPeers = @()
        $total = @($tailscalePeers).Count
        $current = 0
        
        foreach ($peer in $tailscalePeers) {
            $current++
            if ($ShowProgress) {
                Write-Host "." -NoNewline -ForegroundColor Gray
            }
            
            $pingResult = Test-PeerConnectivity -TailscaleIP $peer.TailscaleIP
            
            if ($pingResult.Success) {
                $peerConfig = Get-PeerConfig -TailscaleIP $peer.TailscaleIP
                
                if ($peerConfig -and $peerConfig.CustomerCode -eq $localCode) {
                    $freePct = 50
                    $jobsHosted = 0
                    
                    if ($peerConfig.QuotaGB -and $peerConfig.UsedGB) {
                        $freePct = [math]::Round((1 - ($peerConfig.UsedGB / $peerConfig.QuotaGB)) * 100, 0)
                    }
                    
                    $discoveredPeers += [PSCustomObject]@{
                        HostName = $peer.HostName
                        TailscaleIP = $peer.TailscaleIP
                        CustomerCode = $peerConfig.CustomerCode
                        PingMs = $pingResult.PingMs
                        LastSeen = (Get-Date).ToString('o')
                        Online = $true
                        FreePct = $freePct
                        JobsHosted = $jobsHosted
                        QuotaGB = $peerConfig.QuotaGB
                    }
                }
            }
        }
        
        if ($ShowProgress) { Write-Host "" }
        
        # Save discovered peers to replicated list
        if ($discoveredPeers.Count -gt 0) {
            Save-StoragePeersList -Peers $discoveredPeers
        }
        
        $knownPeers = $discoveredPeers
    }
    
    # Calculate scores and check online status for known peers
    $storagePeers = @()
    
    foreach ($peer in $knownPeers) {
        # Quick ping check
        $pingResult = Test-PeerConnectivity -TailscaleIP $peer.TailscaleIP
        
        if ($pingResult.Success) {
            $score = Get-PeerScore -PingMs $pingResult.PingMs -FreePct $peer.FreePct -JobsHosted $peer.JobsHosted
            
            $storagePeers += [PSCustomObject]@{
                HostName = $peer.HostName
                TailscaleIP = $peer.TailscaleIP
                CustomerCode = $peer.CustomerCode
                PingMs = $pingResult.PingMs
                Score = $score
                Online = $true
                FreePct = $peer.FreePct
                JobsHosted = $peer.JobsHosted
                QuotaGB = $peer.QuotaGB
            }
        }
    }
    
    return $storagePeers | Sort-Object -Property Score -Descending
}

function Get-PeerScore {
    <#
    .SYNOPSIS
        Calculates peer suitability score (0-100)
    #>
    param(
        [int]$PingMs,
        [int]$FreePct,
        [int]$JobsHosted
    )
    
    # Proximity score (40% weight)
    $proximityScore = switch ($true) {
        ($PingMs -lt 20)  { 100 }
        ($PingMs -lt 50)  { 80 }
        ($PingMs -lt 100) { 60 }
        default           { 40 }
    }
    
    # Capacity score (35% weight)
    $capacityScore = switch ($true) {
        ($FreePct -gt 50)  { 100 }
        ($FreePct -gt 30)  { 70 }
        ($FreePct -gt 10)  { 40 }
        default            { 0 }
    }
    
    # Load score (25% weight)
    $loadScore = switch ($true) {
        ($JobsHosted -le 5)  { 100 }
        ($JobsHosted -le 15) { 70 }
        ($JobsHosted -le 30) { 40 }
        default              { 20 }
    }
    
    $totalScore = ($proximityScore * 0.4) + ($capacityScore * 0.35) + ($loadScore * 0.25)
    
    return [math]::Round($totalScore, 0)
}

function Show-StoragePeers {
    <#
    .SYNOPSIS
        Displays all available storage peers with their scores
    #>
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "    AVAILABLE STORAGE NODES" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    # Check if we have a local CustomerCode
    $localCode = Get-LocalCustomerCode
    if (-not $localCode) {
        Write-Host "This machine is not configured as a storage node." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Please run 'Add Storage Peer' (P) first to:" -ForegroundColor White
        Write-Host "  1. Set your customer code" -ForegroundColor Gray
        Write-Host "  2. Configure storage location" -ForegroundColor Gray
        Write-Host "  3. Join the resilience ring" -ForegroundColor Gray
        Write-Host ""
        Read-Host "Press Enter to continue"
        return
    }
    
    Write-Host "Customer: $localCode" -ForegroundColor Cyan
    Write-Host "Checking storage nodes" -ForegroundColor Gray -NoNewline
    $peers = Get-StoragePeers -ShowProgress
    
    if ($peers.Count -eq 0) {
        Write-Host "`nNo storage nodes found for customer '$localCode'." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "This could mean:" -ForegroundColor Gray
        Write-Host "  - Other machines haven't been configured yet" -ForegroundColor Gray
        Write-Host "  - Other machines are offline" -ForegroundColor Gray
        Write-Host "  - Network share 'Backups' is not accessible on peers" -ForegroundColor Gray
    }
    else {
        Write-Host "`n  #  | Score | Ping   | Node ID    | Free  | Jobs" -ForegroundColor Gray
        Write-Host "  ---|-------|--------|------------|-------|-----" -ForegroundColor Gray
        
        $index = 1
        foreach ($peer in $peers) {
            $pingColor = if ($peer.PingMs -lt 50) { 'Green' } elseif ($peer.PingMs -lt 100) { 'Yellow' } else { 'Red' }
            $scoreColor = if ($peer.Score -ge 70) { 'Green' } elseif ($peer.Score -ge 50) { 'Yellow' } else { 'Red' }
            
            # Generate anonymous node ID from IP last octet
            $lastOctet = ($peer.TailscaleIP -split '\.')[-1]
            $nodeId = "Node-$lastOctet"
            
            Write-Host ("  {0,-2} |" -f $index) -NoNewline
            Write-Host (" {0,5} " -f $peer.Score) -ForegroundColor $scoreColor -NoNewline
            Write-Host "|" -NoNewline
            Write-Host (" {0,5}ms " -f $peer.PingMs) -ForegroundColor $pingColor -NoNewline
            Write-Host ("| {0,-10} | {1,4}% | {2,3}" -f $nodeId, $peer.FreePct, $peer.JobsHosted)
            
            $index++
        }
    }
    
    Write-Host ""
    Read-Host "Press Enter to continue"
}

#endregion

# Functions are available when dot-sourced
