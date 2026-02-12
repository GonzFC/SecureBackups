#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Peer Management Module for VLABS Resilience Ring
    
.DESCRIPTION
    Manages Storage Peers in the distributed backup mesh.
    - Tailscale installation & configuration
    - Peer discovery via `tailscale status --json` filtered by tag
    - SMB share management (RR_Backups)
    - Peer health monitoring
    
.NOTES
    Share naming convention: RR_Backups
    Config stored in: C:\VLABS_ResilienceRing\ring-config.json
    Peer list stored in: C:\VLABS_ResilienceRing\storage-peers.json
#>

# Paths
$script:BaseDataPath = "C:\VLABS_ResilienceRing"
$script:ConfigFile = Join-Path $script:BaseDataPath "ring-config.json"
$script:StoragePeersFile = Join-Path $script:BaseDataPath "storage-peers.json"
$script:ShareName = "RR_Backups"
$script:ServiceUser = "RR_Service"

# Ensure base data path exists
if (-not (Test-Path $script:BaseDataPath)) {
    New-Item -Path $script:BaseDataPath -ItemType Directory -Force | Out-Null
}

#region Service Account Functions

function Get-RingServicePassword {
    <#
    .SYNOPSIS
        Generates a deterministic password based on CustomerCode
        All nodes in the same ring will have the same password
    #>
    param([string]$CustomerCode)
    
    # Create deterministic password from CustomerCode + salt
    $salt = "ResilienceRing2026!"
    $combined = "$CustomerCode$salt"
    
    # Use SHA256 to create a hash, then take first 16 chars + special chars for complexity
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
    $hash = $sha256.ComputeHash($bytes)
    $hashString = [BitConverter]::ToString($hash) -replace '-', ''
    
    # Take first 12 chars + add complexity requirements
    $password = $hashString.Substring(0, 12) + "Rr1!"
    
    return $password
}

function New-RingServiceAccount {
    <#
    .SYNOPSIS
        Creates the RR_Service local user account for SMB access
    #>
    param([string]$CustomerCode)
    
    $password = Get-RingServicePassword -CustomerCode $CustomerCode
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    
    # Check if user already exists
    $existingUser = Get-LocalUser -Name $script:ServiceUser -ErrorAction SilentlyContinue
    
    if ($existingUser) {
        # Update password to ensure it matches current CustomerCode
        try {
            $existingUser | Set-LocalUser -Password $securePassword
            Write-Host "[OK] Service account '$script:ServiceUser' password updated" -ForegroundColor Green
        }
        catch {
            Write-Host "[WARN] Could not update service account password: $_" -ForegroundColor Yellow
        }
    }
    else {
        # Create new user
        try {
            New-LocalUser -Name $script:ServiceUser `
                -Password $securePassword `
                -Description "VLABS Resilience Ring Service Account" `
                -PasswordNeverExpires `
                -UserMayNotChangePassword `
                -AccountNeverExpires | Out-Null
            
            # Disable interactive login (optional security measure)
            # The account can still be used for SMB access
            
            Write-Host "[OK] Service account '$script:ServiceUser' created" -ForegroundColor Green
        }
        catch {
            Write-Host "[ERROR] Could not create service account: $_" -ForegroundColor Red
            return $false
        }
    }
    
    return $true
}

function Connect-RingShare {
    <#
    .SYNOPSIS
        Connects to a remote RR_Backups share using the service account credentials
    #>
    param(
        [string]$TailscaleHostname,
        [string]$TailscaleIP,
        [string]$CustomerCode
    )
    
    $password = Get-RingServicePassword -CustomerCode $CustomerCode
    $sharePath = "\\$TailscaleIP\$script:ShareName"
    
    # Remove any existing connection to this share
    net use $sharePath /delete 2>$null | Out-Null
    
    # Connect with credentials
    $result = net use $sharePath /user:$script:ServiceUser $password 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    else {
        return $false
    }
}

function Disconnect-RingShare {
    <#
    .SYNOPSIS
        Disconnects from a remote RR_Backups share
    #>
    param([string]$TailscaleIP)
    
    $sharePath = "\\$TailscaleIP\$script:ShareName"
    net use $sharePath /delete 2>$null | Out-Null
}

#endregion

#region Configuration Functions

function Get-RingConfig {
    <#
    .SYNOPSIS
        Gets the local ring configuration
    #>
    if (Test-Path $script:ConfigFile) {
        return Get-Content $script:ConfigFile -Raw | ConvertFrom-Json
    }
    return $null
}

function Save-RingConfig {
    <#
    .SYNOPSIS
        Saves the ring configuration
    #>
    param([hashtable]$Config)
    
    $Config | ConvertTo-Json -Depth 10 | Set-Content $script:ConfigFile -Force
}

function Get-LocalCustomerCode {
    <#
    .SYNOPSIS
        Gets the CustomerCode from local configuration
    #>
    $config = Get-RingConfig
    if ($config) { return $config.CustomerCode }
    return $null
}

function Get-LocalTailscaleTag {
    <#
    .SYNOPSIS
        Gets the TailscaleTag from local configuration
    #>
    $config = Get-RingConfig
    if ($config) { return $config.TailscaleTag }
    return $null
}

#endregion

#region Storage Peers List Management

function Get-StoragePeersList {
    <#
    .SYNOPSIS
        Gets the local storage peers list
    #>
    if (Test-Path $script:StoragePeersFile) {
        $data = Get-Content $script:StoragePeersFile -Raw | ConvertFrom-Json
        return @($data.Peers)
    }
    return @()
}

function Save-StoragePeersList {
    <#
    .SYNOPSIS
        Saves the storage peers list locally
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
    
    $peerData | ConvertTo-Json -Depth 10 | Set-Content $script:StoragePeersFile -Force
}

function Add-PeerToList {
    <#
    .SYNOPSIS
        Adds or updates a peer in the local storage peers list
    #>
    param([PSCustomObject]$Peer)
    
    $peers = @(Get-StoragePeersList)
    
    # Remove existing entry for this IP (if any)
    $peers = @($peers | Where-Object { $_.TailscaleIP -ne $Peer.TailscaleIP })
    
    # Add the new/updated peer
    $peers += $Peer
    
    Save-StoragePeersList -Peers $peers
}

#endregion

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
            Status = $status
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
        
        Start-Sleep -Seconds 5
        
        $tailscaleExe = Get-TailscaleExePath
        if (-not $tailscaleExe) {
            throw "Tailscale installed but tailscale.exe not found"
        }
        
        Write-Host "Authenticating with Tailscale..." -ForegroundColor Gray
        & $tailscaleExe up --authkey=$AuthKey --unattended --accept-dns=false
        
        if ($LASTEXITCODE -ne 0) {
            throw "Tailscale authentication failed"
        }
        
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

function Get-TailscalePeersByTag {
    <#
    .SYNOPSIS
        Gets Tailscale peers filtered by a specific tag
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Tag
    )
    
    try {
        $tailscaleExe = Get-TailscaleExePath
        if (-not $tailscaleExe) { return @() }
        
        $statusJson = & $tailscaleExe status --json 2>$null
        if (-not $statusJson) { return @() }
        
        $status = $statusJson | ConvertFrom-Json
        $peers = @()
        
        # Normalize tag (ensure it starts with "tag:")
        $tagFilter = if ($Tag -like "tag:*") { $Tag } else { "tag:$Tag" }
        
        foreach ($peerKey in $status.Peer.PSObject.Properties.Name) {
            $peer = $status.Peer.$peerKey
            
            # Check if peer has the required tag
            $hasTailscaleTags = $peer.Tags -and $peer.Tags.Count -gt 0
            $matchesTag = $hasTailscaleTags -and ($peer.Tags -contains $tagFilter)
            
            if ($matchesTag -and $peer.Online) {
                $ip = if ($peer.TailscaleIPs) { $peer.TailscaleIPs[0] } else { $null }
                
                if ($ip) {
                    $peers += [PSCustomObject]@{
                        NodeKey = $peerKey
                        HostName = $peer.HostName
                        DNSName = $peer.DNSName
                        TailscaleIP = $ip
                        OS = $peer.OS
                        Online = $peer.Online
                        Tags = $peer.Tags
                    }
                }
            }
        }
        
        return $peers
    }
    catch {
        Write-Host "[ERROR] Failed to get Tailscale peers: $_" -ForegroundColor Red
        return @()
    }
}

#endregion

#region Connectivity Tests

function Test-PeerPing {
    <#
    .SYNOPSIS
        Tests ping connectivity to a peer (2 attempts)
        Compatible with PowerShell 5.1 and 7+
    #>
    param([string]$TailscaleIP)
    
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            # Use .NET Ping for consistent behavior across PowerShell versions
            $pinger = New-Object System.Net.NetworkInformation.Ping
            $result = $pinger.Send($TailscaleIP, 2000)  # 2 second timeout
            
            if ($result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                return @{ Success = $true; PingMs = $result.RoundtripTime }
            }
            
            if ($attempt -eq 2) {
                return @{ Success = $false; PingMs = -1 }
            }
            Start-Sleep -Milliseconds 500
        }
        catch {
            if ($attempt -eq 2) {
                return @{ Success = $false; PingMs = -1 }
            }
            Start-Sleep -Milliseconds 500
        }
    }
    
    return @{ Success = $false; PingMs = -1 }
}

function Test-PeerSmbShare {
    <#
    .SYNOPSIS
        Tests if the RR_Backups share is accessible on a peer
        Uses service account credentials for authentication
    #>
    param([string]$TailscaleIP)
    
    $config = Get-RingConfig
    if (-not $config -or -not $config.CustomerCode) {
        return $false
    }
    
    # Try to connect with service account credentials
    $connected = Connect-RingShare -TailscaleIP $TailscaleIP -CustomerCode $config.CustomerCode
    
    if ($connected) {
        $sharePath = "\\$TailscaleIP\$script:ShareName"
        
        try {
            $job = Start-Job -ScriptBlock {
                param($path)
                Test-Path $path
            } -ArgumentList $sharePath
            
            $completed = Wait-Job $job -Timeout 3
            
            if ($completed) {
                $result = Receive-Job $job
                Remove-Job $job -Force
                return $result -eq $true
            }
            else {
                Stop-Job $job
                Remove-Job $job -Force
                return $false
            }
        }
        catch {
            return $false
        }
    }
    
    return $false
}

function Get-PeerInfo {
    <#
    .SYNOPSIS
        Reads peer-info.json from a peer's RR_Backups share
        Assumes connection already established via Connect-RingShare
    #>
    param([string]$TailscaleIP)
    
    $remotePath = "\\$TailscaleIP\$script:ShareName\peer-info.json"
    
    try {
        $job = Start-Job -ScriptBlock {
            param($path)
            if (Test-Path $path) {
                Get-Content $path -Raw | ConvertFrom-Json
            }
        } -ArgumentList $remotePath
        
        $completed = Wait-Job $job -Timeout 5
        
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
        return $null
    }
}

#endregion

#region Add Storage Peer (P)

function Add-StoragePeer {
    <#
    .SYNOPSIS
        Configures this machine as a Storage Peer in the Resilience Ring
        Creates the RR_Backups share and registers in the peer list
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
        Write-Host "[OK] Tailscale is connected" -ForegroundColor Green
        Write-Host "  IP: $($tsStatus.Self.TailscaleIPs[0])" -ForegroundColor Gray
        Write-Host "  Hostname: $($tsStatus.Self.HostName)" -ForegroundColor Gray
        
        # Show current tags
        if ($tsStatus.Self.Tags -and $tsStatus.Self.Tags.Count -gt 0) {
            Write-Host "  Tags: $($tsStatus.Self.Tags -join ', ')" -ForegroundColor Gray
        }
        else {
            Write-Host "  Tags: (none)" -ForegroundColor DarkGray
        }
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
    Write-Host "Examples: vlabs, mmi, msk, acme"
    Write-Host "`nCodename: " -NoNewline -ForegroundColor White
    $codename = (Read-Host).ToLower().Trim()
    
    if ($codename.Length -lt 2 -or $codename.Length -gt 6 -or $codename -notmatch '^[a-z0-9]+$') {
        Write-Host "[ERROR] Codename must be 2-6 lowercase letters/numbers only" -ForegroundColor Red
        Read-Host "`nPress Enter to return"
        return
    }
    
    Write-Host ""
    
    # Step 3: Tailscale Tag
    Write-Host "STEP 3: Tailscale Tag" -ForegroundColor Yellow
    Write-Host "----------------------" -ForegroundColor Yellow
    Write-Host "Enter the Tailscale ACL tag for this customer's machines."
    Write-Host "This tag is used to filter peers during discovery."
    Write-Host "Format: tag:rr-<codename> (e.g., tag:rr-acme)"
    Write-Host ""
    Write-Host "IMPORTANT: This tag must be configured in your Tailscale ACL."
    Write-Host "           All machines for this customer must have this tag."
    Write-Host ""
    
    $defaultTag = "tag:rr-$codename"
    Write-Host "Tailscale Tag [$defaultTag]: " -NoNewline -ForegroundColor White
    $inputTag = Read-Host
    $tailscaleTag = if ($inputTag) { $inputTag.Trim() } else { $defaultTag }
    
    # Ensure tag starts with "tag:"
    if ($tailscaleTag -notlike "tag:*") {
        $tailscaleTag = "tag:$tailscaleTag"
    }
    
    Write-Host ""
    
    # Step 4: Storage Path
    Write-Host "STEP 4: Storage Location" -ForegroundColor Yellow
    Write-Host "-------------------------" -ForegroundColor Yellow
    
    # Show available drives with free space
    Write-Host "Available drives:" -ForegroundColor Gray
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 0 }
    foreach ($drive in $drives) {
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        $usedGB = [math]::Round($drive.Used / 1GB, 1)
        $totalGB = $freeGB + $usedGB
        $pctFree = if ($totalGB -gt 0) { [math]::Round(($freeGB / $totalGB) * 100, 0) } else { 0 }
        Write-Host "  $($drive.Name):\ - $freeGB GB free of $totalGB GB ($pctFree% free)" -ForegroundColor Gray
    }
    
    Write-Host "`nBase storage path (e.g., D:\Backups): " -NoNewline -ForegroundColor White
    $storagePath = Read-Host
    
    if (-not $storagePath) {
        Write-Host "[ERROR] Storage path is required" -ForegroundColor Red
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
    
    # Step 5: Quota
    Write-Host "STEP 5: Storage Quota" -ForegroundColor Yellow
    Write-Host "----------------------" -ForegroundColor Yellow
    
    $driveLetter = (Split-Path $storagePath -Qualifier).TrimEnd(':')
    $driveInfo = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
    $availableGB = if ($driveInfo) { [math]::Round($driveInfo.Free / 1GB, 0) } else { 100 }
    
    Write-Host "Available space on drive: $availableGB GB"
    Write-Host "Recommended: Leave at least 20% free for system operations"
    Write-Host "`nMaximum quota for backups (GB): " -NoNewline -ForegroundColor White
    $quotaInput = Read-Host
    $quotaGB = [int]$quotaInput
    
    if ($quotaGB -le 0 -or $quotaGB -gt $availableGB) {
        Write-Host "[ERROR] Invalid quota. Must be between 1 and $availableGB GB" -ForegroundColor Red
        Read-Host "`nPress Enter to return"
        return
    }
    
    Write-Host ""
    
    # Step 6: Create Service Account
    Write-Host "STEP 6: Creating Service Account" -ForegroundColor Yellow
    Write-Host "---------------------------------" -ForegroundColor Yellow
    
    if (-not (New-RingServiceAccount -CustomerCode $codename)) {
        Write-Host "[ERROR] Failed to create service account" -ForegroundColor Red
        Read-Host "`nPress Enter to return"
        return
    }
    
    Write-Host ""
    
    # Step 7: Create SMB Share with proper permissions
    Write-Host "STEP 7: Creating SMB Share" -ForegroundColor Yellow
    Write-Host "---------------------------" -ForegroundColor Yellow
    
    $existingShare = Get-SmbShare -Name $script:ShareName -ErrorAction SilentlyContinue
    if ($existingShare) {
        Write-Host "[INFO] Share '$script:ShareName' already exists" -ForegroundColor Yellow
        Write-Host "  Current path: $($existingShare.Path)" -ForegroundColor Gray
        
        if ($existingShare.Path -ne $storagePath) {
            Write-Host ""
            Write-Host "The share points to a different path. Update it? [Y/n]: " -NoNewline -ForegroundColor Yellow
            $updateShare = Read-Host
            
            if ($updateShare -eq '' -or $updateShare -match '^[Yy]') {
                Remove-SmbShare -Name $script:ShareName -Force -ErrorAction SilentlyContinue
                $existingShare = $null
            }
        }
        else {
            # Update permissions on existing share
            try {
                # Revoke all existing permissions and set new ones
                Revoke-SmbShareAccess -Name $script:ShareName -AccountName "Everyone" -Force -ErrorAction SilentlyContinue
                Grant-SmbShareAccess -Name $script:ShareName -AccountName $script:ServiceUser -AccessRight Full -Force | Out-Null
                Write-Host "[OK] Updated share permissions for '$script:ServiceUser'" -ForegroundColor Green
            }
            catch {
                Write-Host "[WARN] Could not update share permissions: $_" -ForegroundColor Yellow
            }
        }
    }
    
    if (-not $existingShare) {
        try {
            # Create share with RR_Service having full access
            New-SmbShare -Name $script:ShareName -Path $storagePath -FullAccess $script:ServiceUser -Description "VLABS Resilience Ring Storage" | Out-Null
            Write-Host "[OK] Created network share with service account access" -ForegroundColor Green
        }
        catch {
            Write-Host "[ERROR] Could not create SMB share: $_" -ForegroundColor Red
            Write-Host "Please manually share '$storagePath' as '$script:ShareName'" -ForegroundColor Yellow
            Read-Host "`nPress Enter to return"
            return
        }
    }
    
    # Also set NTFS permissions on the folder
    try {
        $acl = Get-Acl $storagePath
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $script:ServiceUser, 
            "FullControl", 
            "ContainerInherit,ObjectInherit", 
            "None", 
            "Allow"
        )
        $acl.AddAccessRule($rule)
        Set-Acl $storagePath $acl
        Write-Host "[OK] Set NTFS permissions for '$script:ServiceUser'" -ForegroundColor Green
    }
    catch {
        Write-Host "[WARN] Could not set NTFS permissions: $_" -ForegroundColor Yellow
    }
    
    # Get Tailscale hostname for display
    $tailscaleHostname = $tsStatus.Self.DNSName -replace '\..*$', ''  # Get just the hostname part
    if (-not $tailscaleHostname) { $tailscaleHostname = $tsStatus.Self.HostName }
    
    Write-Host "[OK] Share accessible at: \\$tailscaleHostname\$script:ShareName" -ForegroundColor Green
    
    Write-Host ""
    
    # Step 8: Save Configuration
    Write-Host "STEP 8: Saving Configuration" -ForegroundColor Yellow
    Write-Host "-----------------------------" -ForegroundColor Yellow
    
    # Get Tailscale hostname (the one Tailscale uses, not Windows hostname)
    $tailscaleHostname = $tsStatus.Self.DNSName -replace '\..*$', ''  # Get just the hostname part
    if (-not $tailscaleHostname) { $tailscaleHostname = $tsStatus.Self.HostName }
    
    $config = @{
        IsStoragePeer = $true
        Hostname = $tailscaleHostname
        WindowsHostname = $env:COMPUTERNAME
        TailscaleIP = $tsStatus.Self.TailscaleIPs[0]
        CustomerCode = $codename
        TailscaleTag = $tailscaleTag
        StoragePath = $storagePath
        QuotaGB = $quotaGB
        CreatedAt = (Get-Date).ToString('o')
    }
    
    # Save local config
    Save-RingConfig -Config $config
    Write-Host "[OK] Ring configuration saved" -ForegroundColor Green
    
    # Create peer-info.json inside the share for discovery
    $peerInfoPath = Join-Path $storagePath "peer-info.json"
    $peerInfo = @{
        CustomerCode = $codename
        TailscaleTag = $tailscaleTag
        Hostname = $tailscaleHostname
        WindowsHostname = $env:COMPUTERNAME
        TailscaleIP = $tsStatus.Self.TailscaleIPs[0]
        QuotaGB = $quotaGB
        Since = (Get-Date).ToString('o')
        Version = "1.5"
    }
    $peerInfo | ConvertTo-Json | Set-Content $peerInfoPath -Force
    Write-Host "[OK] Peer info file created" -ForegroundColor Green
    
    # Register this peer in the storage peers list
    $thisPeer = [PSCustomObject]@{
        Hostname = $tailscaleHostname
        TailscaleIP = $tsStatus.Self.TailscaleIPs[0]
        CustomerCode = $codename
        AddedAt = (Get-Date).ToString('o')
        QuotaGB = $quotaGB
    }
    
    Add-PeerToList -Peer $thisPeer
    Write-Host "[OK] Added to storage peers list" -ForegroundColor Green
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "    STORAGE PEER CONFIGURED!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host "  Tailscale Name: $tailscaleHostname" -ForegroundColor White
    Write-Host "  Tailscale IP:   $($config.TailscaleIP)" -ForegroundColor White
    Write-Host "  Customer:       $($config.CustomerCode)" -ForegroundColor White
    Write-Host "  Tailscale Tag:  $($config.TailscaleTag)" -ForegroundColor White
    Write-Host "  Storage:        $($config.StoragePath)" -ForegroundColor White
    Write-Host "  Share:          \\$tailscaleHostname\$script:ShareName" -ForegroundColor White
    Write-Host "  Quota:          $($config.QuotaGB) GB" -ForegroundColor White
    Write-Host "  Service User:   $script:ServiceUser" -ForegroundColor White
    Write-Host ""
    Write-Host "This machine is now part of the Resilience Ring!" -ForegroundColor Yellow
    Write-Host "Other peers can discover it using 'Discover & Update' (D)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "IMPORTANT:" -ForegroundColor Cyan
    Write-Host "  1. Make sure this machine has the Tailscale tag '$tailscaleTag'" -ForegroundColor White
    Write-Host "     in your Tailscale admin console: https://login.tailscale.com/admin/machines" -ForegroundColor Gray
    Write-Host "  2. Run 'Add Storage Peer' (P) on other machines with the SAME" -ForegroundColor White
    Write-Host "     Customer Code '$codename' to join this ring." -ForegroundColor Gray
    
    Read-Host "`nPress Enter to continue"
}

#endregion

#region Show Available Storage Peers (S)

function Show-StoragePeers {
    <#
    .SYNOPSIS
        Shows available storage peers from the local list
        Tests connectivity via ping (2 attempts) and SMB share access
    #>
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "    AVAILABLE STORAGE PEERS" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    # Check if we have a local configuration
    $config = Get-RingConfig
    if (-not $config -or -not $config.CustomerCode) {
        Write-Host "This machine is not configured." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Please run 'Add Storage Peer' (P) first to:" -ForegroundColor White
        Write-Host "  1. Set your customer code and Tailscale tag" -ForegroundColor Gray
        Write-Host "  2. Configure storage location" -ForegroundColor Gray
        Write-Host "  3. Join the resilience ring" -ForegroundColor Gray
        Write-Host ""
        Read-Host "Press Enter to continue"
        return
    }
    
    Write-Host "Customer:      $($config.CustomerCode)" -ForegroundColor Cyan
    Write-Host "Tailscale Tag: $($config.TailscaleTag)" -ForegroundColor Cyan
    Write-Host ""
    
    # Get local peer list
    $peers = Get-StoragePeersList
    
    if ($peers.Count -eq 0) {
        Write-Host "No storage peers in local list." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Use 'Discover & Update Peer List' (D) to find peers." -ForegroundColor Gray
        Write-Host ""
        Read-Host "Press Enter to continue"
        return
    }
    
    Write-Host "Checking $($peers.Count) peers..." -ForegroundColor Gray
    Write-Host ""
    
    $availablePeers = @()
    $unavailablePeers = @()
    
    foreach ($peer in $peers) {
        Write-Host "  Testing $($peer.Hostname)..." -NoNewline -ForegroundColor Gray
        
        # Test 1: Ping (2 attempts)
        $pingResult = Test-PeerPing -TailscaleIP $peer.TailscaleIP
        
        if (-not $pingResult.Success) {
            Write-Host " [PING FAILED]" -ForegroundColor Red
            $unavailablePeers += [PSCustomObject]@{
                Hostname = $peer.Hostname
                TailscaleIP = $peer.TailscaleIP
                Reason = "Ping failed"
            }
            continue
        }
        
        # Test 2: SMB Share access
        $shareOk = Test-PeerSmbShare -TailscaleIP $peer.TailscaleIP
        
        if (-not $shareOk) {
            Write-Host " [SHARE NOT ACCESSIBLE]" -ForegroundColor Yellow
            $unavailablePeers += [PSCustomObject]@{
                Hostname = $peer.Hostname
                TailscaleIP = $peer.TailscaleIP
                Reason = "Share not accessible"
                PingMs = $pingResult.PingMs
            }
            continue
        }
        
        Write-Host " [OK - $($pingResult.PingMs)ms]" -ForegroundColor Green
        
        $availablePeers += [PSCustomObject]@{
            Hostname = $peer.Hostname
            TailscaleIP = $peer.TailscaleIP
            PingMs = $pingResult.PingMs
            QuotaGB = $peer.QuotaGB
        }
    }
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    
    if ($availablePeers.Count -gt 0) {
        Write-Host ""
        Write-Host " AVAILABLE ($($availablePeers.Count)):" -ForegroundColor Green
        Write-Host "  #  | Ping   | Hostname           | Tailscale IP    | Quota" -ForegroundColor Gray
        Write-Host " ----|--------|--------------------|-----------------|---------" -ForegroundColor Gray
        
        $index = 1
        foreach ($peer in ($availablePeers | Sort-Object PingMs)) {
            $pingColor = if ($peer.PingMs -lt 50) { 'Green' } elseif ($peer.PingMs -lt 100) { 'Yellow' } else { 'Red' }
            $quotaStr = if ($peer.QuotaGB) { "$($peer.QuotaGB) GB" } else { "N/A" }
            
            Write-Host (" {0,2} |" -f $index) -NoNewline
            Write-Host (" {0,5}ms" -f $peer.PingMs) -ForegroundColor $pingColor -NoNewline
            Write-Host (" | {0,-18} | {1,-15} | {2}" -f $peer.Hostname, $peer.TailscaleIP, $quotaStr)
            
            $index++
        }
    }
    
    if ($unavailablePeers.Count -gt 0) {
        Write-Host ""
        Write-Host " UNAVAILABLE ($($unavailablePeers.Count)):" -ForegroundColor Red
        foreach ($peer in $unavailablePeers) {
            Write-Host "  - $($peer.Hostname) ($($peer.TailscaleIP)): $($peer.Reason)" -ForegroundColor DarkGray
        }
    }
    
    Write-Host ""
    Read-Host "Press Enter to continue"
}

#endregion

#region Discover & Update Peer List (D)

function Update-PeerList {
    <#
    .SYNOPSIS
        Discovers storage peers by scanning Tailscale network filtered by tag
        Reads peer-info.json from each peer's RR_Backups share
        Merges discovered peers into local list
    #>
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "    DISCOVER & UPDATE PEER LIST" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    # Check if we have a local configuration
    $config = Get-RingConfig
    if (-not $config -or -not $config.CustomerCode -or -not $config.TailscaleTag) {
        Write-Host "This machine is not configured." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Please run 'Add Storage Peer' (P) first." -ForegroundColor White
        Write-Host ""
        return
    }
    
    Write-Host "Customer:      $($config.CustomerCode)" -ForegroundColor Cyan
    Write-Host "Tailscale Tag: $($config.TailscaleTag)" -ForegroundColor Cyan
    Write-Host ""
    
    # Step 1: Query Tailscale for peers with matching tag
    Write-Host "Step 1: Querying Tailscale for tagged peers..." -ForegroundColor Yellow
    
    $taggedPeers = Get-TailscalePeersByTag -Tag $config.TailscaleTag
    
    if ($taggedPeers.Count -eq 0) {
        Write-Host ""
        Write-Host "[WARN] No peers found with tag '$($config.TailscaleTag)'" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Possible reasons:" -ForegroundColor Gray
        Write-Host "  1. No other machines have this tag yet" -ForegroundColor Gray
        Write-Host "  2. Other machines are offline" -ForegroundColor Gray
        Write-Host "  3. The tag is not configured in Tailscale ACL" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Note: Make sure to add the tag to machines in the Tailscale admin console" -ForegroundColor Cyan
        Write-Host "      https://login.tailscale.com/admin/machines" -ForegroundColor Cyan
        Write-Host ""
        return
    }
    
    Write-Host "[OK] Found $($taggedPeers.Count) peer(s) with tag" -ForegroundColor Green
    Write-Host ""
    
    # Step 2: For each peer, check RR_Backups share and read peer-info.json
    Write-Host "Step 2: Scanning peers for storage configuration..." -ForegroundColor Yellow
    Write-Host ""
    
    $discoveredPeers = @()
    $skippedPeers = @()
    
    foreach ($peer in $taggedPeers) {
        Write-Host "  Checking $($peer.HostName) ($($peer.TailscaleIP))..." -NoNewline -ForegroundColor Gray
        
        # Skip self
        if ($peer.TailscaleIP -eq $config.TailscaleIP) {
            Write-Host " [SELF]" -ForegroundColor DarkGray
            continue
        }
        
        # Test ping
        $pingResult = Test-PeerPing -TailscaleIP $peer.TailscaleIP
        if (-not $pingResult.Success) {
            Write-Host " [PING FAILED]" -ForegroundColor Red
            $skippedPeers += @{ Hostname = $peer.HostName; Reason = "Ping failed" }
            continue
        }
        
        # Connect with service account credentials
        $connected = Connect-RingShare -TailscaleIP $peer.TailscaleIP -CustomerCode $config.CustomerCode
        if (-not $connected) {
            Write-Host " [AUTH FAILED]" -ForegroundColor Yellow
            $skippedPeers += @{ Hostname = $peer.HostName; Reason = "SMB authentication failed" }
            continue
        }
        
        # Test SMB share access
        $sharePath = "\\$($peer.TailscaleIP)\$script:ShareName"
        $shareExists = Test-Path $sharePath -ErrorAction SilentlyContinue
        if (-not $shareExists) {
            Write-Host " [NO SHARE]" -ForegroundColor Yellow
            $skippedPeers += @{ Hostname = $peer.HostName; Reason = "RR_Backups share not found" }
            Disconnect-RingShare -TailscaleIP $peer.TailscaleIP
            continue
        }
        
        # Read peer-info.json
        $peerInfo = Get-PeerInfo -TailscaleIP $peer.TailscaleIP
        if (-not $peerInfo) {
            Write-Host " [NO INFO]" -ForegroundColor Yellow
            $skippedPeers += @{ Hostname = $peer.HostName; Reason = "peer-info.json not found" }
            Disconnect-RingShare -TailscaleIP $peer.TailscaleIP
            continue
        }
        
        # Verify codename matches
        if ($peerInfo.CustomerCode -ne $config.CustomerCode) {
            Write-Host " [CODENAME MISMATCH]" -ForegroundColor Yellow
            $skippedPeers += @{ Hostname = $peer.HostName; Reason = "Different customer code: $($peerInfo.CustomerCode)" }
            Disconnect-RingShare -TailscaleIP $peer.TailscaleIP
            continue
        }
        
        Write-Host " [OK - $($pingResult.PingMs)ms]" -ForegroundColor Green
        
        # Use Tailscale hostname from peer-info if available, otherwise from Tailscale status
        $peerHostname = if ($peerInfo.Hostname) { $peerInfo.Hostname } else { $peer.HostName }
        
        $discoveredPeers += [PSCustomObject]@{
            Hostname = $peerHostname
            TailscaleIP = $peer.TailscaleIP
            CustomerCode = $peerInfo.CustomerCode
            AddedAt = (Get-Date).ToString('o')
            QuotaGB = $peerInfo.QuotaGB
        }
        
        # Disconnect after reading info
        Disconnect-RingShare -TailscaleIP $peer.TailscaleIP
    }
    
    Write-Host ""
    
    # Step 3: Merge into local list
    if ($discoveredPeers.Count -gt 0) {
        Write-Host "Step 3: Updating local peer list..." -ForegroundColor Yellow
        
        foreach ($peer in $discoveredPeers) {
            Add-PeerToList -Peer $peer
        }
        
        Write-Host "[OK] Added/updated $($discoveredPeers.Count) peer(s)" -ForegroundColor Green
    }
    else {
        Write-Host "No new storage peers discovered." -ForegroundColor Yellow
    }
    
    # Summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " DISCOVERY SUMMARY" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Peers scanned:    $($taggedPeers.Count)" -ForegroundColor White
    Write-Host "  Peers discovered: $($discoveredPeers.Count)" -ForegroundColor Green
    Write-Host "  Peers skipped:    $($skippedPeers.Count)" -ForegroundColor $(if ($skippedPeers.Count -gt 0) { 'Yellow' } else { 'White' })
    
    if ($skippedPeers.Count -gt 0) {
        Write-Host ""
        Write-Host "  Skipped details:" -ForegroundColor Gray
        foreach ($skip in $skippedPeers) {
            Write-Host "    - $($skip.Hostname): $($skip.Reason)" -ForegroundColor DarkGray
        }
    }
    
    # Show current peer list
    $currentPeers = Get-StoragePeersList
    Write-Host ""
    Write-Host "  Total peers in list: $($currentPeers.Count)" -ForegroundColor Cyan
    
    Write-Host ""
}

#endregion

# Functions are available when dot-sourced
