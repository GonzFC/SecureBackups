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
$script:PeersFile = Join-Path $PSScriptRoot "peers.json"
$script:PeerStatsFile = Join-Path $PSScriptRoot "peer-stats.json"
$script:ConfigFile = Join-Path $PSScriptRoot "ring-config.json"

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
        Tests connectivity to a peer and returns ping time
    #>
    param(
        [string]$TailscaleIP
    )
    
    try {
        $ping = Test-Connection -ComputerName $TailscaleIP -Count 3 -ErrorAction Stop
        $avgMs = [math]::Round(($ping | Measure-Object -Property ResponseTime -Average).Average, 1)
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
    #>
    Write-Host "`nScanning for Tailscale peers..." -ForegroundColor Cyan
    
    $allPeers = Get-TailscalePeers
    $onlinePeers = $allPeers | Where-Object { $_.Online -eq $true }
    
    Write-Host "Found $($allPeers.Count) total peers, $($onlinePeers.Count) online" -ForegroundColor Gray
    
    $peerList = @()
    $index = 1
    
    foreach ($peer in $onlinePeers) {
        Write-Host "  [$index/$($onlinePeers.Count)] Testing $($peer.HostName)..." -ForegroundColor Gray -NoNewline
        
        $pingResult = Test-PeerConnectivity -TailscaleIP $peer.TailscaleIP
        
        if ($pingResult.Success) {
            Write-Host " ${pingResult.PingMs}ms" -ForegroundColor Green
            
            $peerList += [PSCustomObject]@{
                NodeKey = $peer.NodeKey
                HostName = $peer.HostName
                TailscaleIP = $peer.TailscaleIP
                OS = $peer.OS
                PingMs = $pingResult.PingMs
                LastSeen = (Get-Date).ToString('o')
                IsStoragePeer = $false  # Will be set when configured as storage
                StorageConfig = $null
            }
        }
        else {
            Write-Host " UNREACHABLE" -ForegroundColor Yellow
        }
        
        $index++
    }
    
    # Save to file
    $peerList | ConvertTo-Json -Depth 5 | Set-Content $script:PeersFile -Force
    
    Write-Host "`n[OK] Peer list updated: $($peerList.Count) reachable peers" -ForegroundColor Green
    
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

function Get-StoragePeers {
    <#
    .SYNOPSIS
        Gets all configured storage peers with their current status and scores
    #>
    
    if (-not (Test-Path $script:PeersFile)) {
        Update-PeerList | Out-Null
    }
    
    $peers = Get-Content $script:PeersFile -Raw | ConvertFrom-Json
    $storagePeers = @()
    
    foreach ($peer in $peers) {
        # Query each peer for its storage config (via shared file or API call)
        # For now, we'll use local knowledge + ping status
        
        $pingResult = Test-PeerConnectivity -TailscaleIP $peer.TailscaleIP
        
        if ($pingResult.Success) {
            # Calculate score
            $score = Get-PeerScore -PingMs $pingResult.PingMs -FreePct 50 -JobsHosted 0
            
            $storagePeers += [PSCustomObject]@{
                HostName = $peer.HostName
                TailscaleIP = $peer.TailscaleIP
                PingMs = $pingResult.PingMs
                Score = $score
                Online = $true
                # These would come from peer config in full implementation
                FreePct = 50
                JobsHosted = 0
            }
        }
    }
    
    # Sort by score descending
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
    Write-Host "    AVAILABLE STORAGE PEERS" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    Write-Host "Scanning peers..." -ForegroundColor Gray
    $peers = Get-StoragePeers
    
    if ($peers.Count -eq 0) {
        Write-Host "No storage peers available." -ForegroundColor Yellow
        Write-Host "Run 'Add Storage Peer' on other machines to add them to the ring." -ForegroundColor Gray
    }
    else {
        Write-Host "`n  #  | Score | Ping   | Host                 | Free  | Jobs" -ForegroundColor Gray
        Write-Host "  ---|-------|--------|----------------------|-------|-----" -ForegroundColor Gray
        
        $index = 1
        foreach ($peer in $peers) {
            $pingColor = if ($peer.PingMs -lt 50) { 'Green' } elseif ($peer.PingMs -lt 100) { 'Yellow' } else { 'Red' }
            $scoreColor = if ($peer.Score -ge 70) { 'Green' } elseif ($peer.Score -ge 50) { 'Yellow' } else { 'Red' }
            
            Write-Host ("  {0,-2} |" -f $index) -NoNewline
            Write-Host (" {0,5} " -f $peer.Score) -ForegroundColor $scoreColor -NoNewline
            Write-Host "|" -NoNewline
            Write-Host (" {0,5}ms " -f $peer.PingMs) -ForegroundColor $pingColor -NoNewline
            Write-Host ("| {0,-20} | {1,4}% | {2,3}" -f $peer.HostName.Substring(0, [Math]::Min(20, $peer.HostName.Length)), $peer.FreePct, $peer.JobsHosted)
            
            $index++
        }
    }
    
    Write-Host ""
    Read-Host "Press Enter to continue"
}

#endregion

#region Exports

# Export functions for use in ResilienceRing.ps1
Export-ModuleMember -Function @(
    'Test-TailscaleInstalled',
    'Install-Tailscale',
    'Get-TailscalePeers',
    'Update-PeerList',
    'Add-StoragePeer',
    'Get-StoragePeers',
    'Get-PeerScore',
    'Show-StoragePeers'
) -ErrorAction SilentlyContinue

#endregion
