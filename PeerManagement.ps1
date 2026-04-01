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
    Config stored in: C:\ProgramData\VLABS_ResilienceRing\ring-config.json
    Peer list stored in: C:\ProgramData\VLABS_ResilienceRing\storage-peers.json
#>

# Constants - DATA goes to ProgramData (separate from git repo install directory)
# This prevents git reset --hard from deleting config files during updates
$global:RR_DataPath = "C:\ProgramData\VLABS_ResilienceRing"
$global:RR_ConfigFile = "C:\ProgramData\VLABS_ResilienceRing\ring-config.json"
$global:RR_PeersFile = "C:\ProgramData\VLABS_ResilienceRing\storage-peers.json"
$global:RR_ShareName = "RR_Backups"
$global:RR_ServiceUser = "RR_Service"

# Helper functions to get paths (more reliable than variables)
function Get-RRDataPath { return "C:\ProgramData\VLABS_ResilienceRing" }
function Get-RRConfigFile { return "C:\ProgramData\VLABS_ResilienceRing\ring-config.json" }
function Get-RRPeersFile { return "C:\ProgramData\VLABS_ResilienceRing\storage-peers.json" }
function Get-RRShareName { return "RR_Backups" }
function Get-RRServiceUser { return "RR_Service" }

# Debug log function
function Write-RRDebug {
    param([string]$Message)
    $logFile = "C:\ProgramData\VLABS_ResilienceRing\debug.log"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp | $Message" | Add-Content -Path $logFile -ErrorAction SilentlyContinue
}

# Ensure base data path exists
$dataPath = Get-RRDataPath
if (-not (Test-Path $dataPath)) {
    New-Item -Path $dataPath -ItemType Directory -Force | Out-Null
}

Write-RRDebug "=== PeerManagement.ps1 loaded ==="
Write-RRDebug "DataPath: $dataPath"
Write-RRDebug "ConfigFile exists: $(Test-Path (Get-RRConfigFile))"

#region Health Check and Migration

function Test-RingHealth {
    <#
    .SYNOPSIS
        Verifies ring configuration is valid and files are in expected locations
    #>
    $issues = @()
    
    # Check base directory exists
    if (-not (Test-Path $(Get-RRDataPath))) {
        $issues += "Base directory missing: $(Get-RRDataPath)"
    }
    
    # Check ring-config.json
    if (Test-Path $(Get-RRConfigFile)) {
        try {
            $config = Get-Content $(Get-RRConfigFile) -Raw | ConvertFrom-Json
            if (-not $config.CustomerCode) {
                $issues += "ring-config.json exists but CustomerCode is empty"
            }
        }
        catch {
            $issues += "ring-config.json is corrupted: $_"
        }
    }
    
    return @{
        IsHealthy = ($issues.Count -eq 0)
        Issues = $issues
        ConfigExists = (Test-Path $(Get-RRConfigFile))
        PeersExists = (Test-Path $(Get-RRPeersFile))
        ConfigPath = $(Get-RRConfigFile)
    }
}

function Invoke-RingMigration {
    <#
    .SYNOPSIS
        Migrates data from old locations to canonical path (ProgramData)
        Only copies if destination doesn't already exist
    #>
    # HARDCODED paths - ProgramData survives git updates
    $dataPath = "C:\ProgramData\VLABS_ResilienceRing"
    $configFile = "C:\ProgramData\VLABS_ResilienceRing\ring-config.json"
    $peersFile = "C:\ProgramData\VLABS_ResilienceRing\storage-peers.json"
    
    # Ensure data directory exists
    if (-not (Test-Path $dataPath)) {
        New-Item -Path $dataPath -ItemType Directory -Force | Out-Null
    }
    
    # Legacy paths include both old config location AND old install directory
    $legacyPaths = @(
        "C:\VLABS_SecureBackups",
        "C:\VLABS_ResilienceRing"  # Old install dir that might have config files
    )
    
    Write-RRDebug "Invoke-RingMigration called"
    Write-RRDebug "  Config exists at target: $(Test-Path $configFile)"
    
    $migrated = $false
    
    foreach ($legacyPath in $legacyPaths) {
        if (-not (Test-Path $legacyPath)) { 
            Write-RRDebug "  Legacy path not found: $legacyPath"
            continue 
        }
        
        Write-RRDebug "  Checking legacy path: $legacyPath"
        
        # Check for ring-config.json in legacy path
        $legacyConfig = Join-Path $legacyPath "ring-config.json"
        $targetConfigExists = Test-Path $configFile
        $legacyConfigExists = Test-Path $legacyConfig
        
        Write-RRDebug "    Legacy config exists: $legacyConfigExists, Target exists: $targetConfigExists"
        
        if ($legacyConfigExists -and -not $targetConfigExists) {
            Copy-Item -Path $legacyConfig -Destination $configFile -Force
            Write-Host "[MIGRATED] ring-config.json" -ForegroundColor Yellow
            Write-RRDebug "    MIGRATED ring-config.json"
            $migrated = $true
        }
        
        # Check for storage-peers.json in legacy path
        $legacyPeers = Join-Path $legacyPath "storage-peers.json"
        if ((Test-Path $legacyPeers) -and -not (Test-Path $peersFile)) {
            Copy-Item -Path $legacyPeers -Destination $peersFile -Force
            Write-Host "[MIGRATED] storage-peers.json" -ForegroundColor Yellow
            Write-RRDebug "    MIGRATED storage-peers.json"
            $migrated = $true
        }
    }
    
    return $migrated
}

# Run migration on module load (only migrates if target doesn't exist)
Invoke-RingMigration | Out-Null

#endregion

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
    $existingUser = Get-LocalUser -Name $(Get-RRServiceUser) -ErrorAction SilentlyContinue
    
    if ($existingUser) {
        # Update password to ensure it matches current CustomerCode
        try {
            $existingUser | Set-LocalUser -Password $securePassword
            Write-Host "[OK] Service account '$(Get-RRServiceUser)' password updated" -ForegroundColor Green
        }
        catch {
            Write-Host "[WARN] Could not update service account password: $_" -ForegroundColor Yellow
        }
    }
    else {
        # Create new user
        try {
            New-LocalUser -Name $(Get-RRServiceUser) `
                -Password $securePassword `
                -Description "VLABS Resilience Ring Service Account" `
                -PasswordNeverExpires `
                -UserMayNotChangePassword `
                -AccountNeverExpires | Out-Null
            
            # Disable interactive login (optional security measure)
            # The account can still be used for SMB access
            
            Write-Host "[OK] Service account '$(Get-RRServiceUser)' created" -ForegroundColor Green
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
    $sharePath = "\\$TailscaleIP\$(Get-RRShareName)"
    
    # Remove any existing connection to this share
    net use $sharePath /delete 2>$null | Out-Null
    
    # Connect with credentials
    $result = net use $sharePath /user:$(Get-RRServiceUser) $password 2>&1
    
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
    
    $sharePath = "\\$TailscaleIP\$(Get-RRShareName)"
    net use $sharePath /delete 2>$null | Out-Null
}

#endregion

#region Configuration Functions

function Get-RingConfig {
    <#
    .SYNOPSIS
        Gets the local ring configuration
    #>
    # HARDCODED path to avoid any variable issues
    $configFile = "C:\ProgramData\VLABS_ResilienceRing\ring-config.json"
    
    Write-RRDebug "Get-RingConfig called"
    Write-RRDebug "  Looking for: $configFile"
    Write-RRDebug "  File exists: $(Test-Path $configFile)"
    
    if (Test-Path $configFile) {
        try {
            $content = Get-Content -Path $configFile -Raw -ErrorAction Stop
            Write-RRDebug "  Content length: $($content.Length) chars"
            
            if ([string]::IsNullOrWhiteSpace($content)) {
                Write-Host "[WARN] Config file exists but is empty: $configFile" -ForegroundColor Yellow
                Write-RRDebug "  WARN: File is empty!"
                return $null
            }
            
            $config = $content | ConvertFrom-Json
            Write-RRDebug "  Loaded CustomerCode: $($config.CustomerCode)"
            return $config
        }
        catch {
            Write-Host "[ERROR] Failed to read ring config: $_" -ForegroundColor Red
            Write-RRDebug "  EXCEPTION: $_"
            return $null
        }
    }
    else {
        Write-RRDebug "  File not found!"
    }
    return $null
}

function Save-RingConfig {
    <#
    .SYNOPSIS
        Saves the ring configuration
    #>
    param($Config)  # Can be hashtable or PSObject
    
    # HARDCODED path - uses ProgramData to survive git updates
    $configFile = "C:\ProgramData\VLABS_ResilienceRing\ring-config.json"
    $dataPath = "C:\ProgramData\VLABS_ResilienceRing"
    
    Write-RRDebug "Save-RingConfig called"
    Write-RRDebug "  Target file: $configFile"
    Write-RRDebug "  Config keys: $($Config.Keys -join ', ')"
    
    # Ensure directory exists
    if (-not (Test-Path $dataPath)) {
        New-Item -Path $dataPath -ItemType Directory -Force | Out-Null
        Write-RRDebug "  Created directory: $dataPath"
    }
    
    try {
        $json = $Config | ConvertTo-Json -Depth 10
        Write-RRDebug "  JSON length: $($json.Length) chars"
        
        # Write using Out-File for more reliable behavior
        $json | Out-File -FilePath $configFile -Encoding UTF8 -Force -ErrorAction Stop
        
        # Verify write was successful
        if (Test-Path $configFile) {
            $size = (Get-Item $configFile).Length
            Write-Host "[OK] Config saved ($size bytes): $configFile" -ForegroundColor Green
            Write-RRDebug "  SUCCESS: File saved, $size bytes"
        }
        else {
            Write-Host "[ERROR] File not created!" -ForegroundColor Red
            Write-RRDebug "  ERROR: File does not exist after write!"
        }
    }
    catch {
        Write-Host "[ERROR] Failed to save config: $_" -ForegroundColor Red
        Write-Host "[ERROR] Path: $configFile" -ForegroundColor Red
        Write-RRDebug "  EXCEPTION: $_"
    }
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

function Get-EffectiveTailscaleMode {
    <#
    .SYNOPSIS
        Returns the effective Tailscale mode for this node
    .DESCRIPTION
        Falls back to AlwaysOn when the value is missing or invalid.
    #>
    param($Config = $null)
    
    if (-not $Config) {
        $Config = Get-RingConfig
    }
    
    if ($Config -and $Config.TailscaleMode -and $Config.TailscaleMode -match '^(?i:PerJob)$') {
        return 'PerJob'
    }
    
    return 'AlwaysOn'
}

function Set-TailscaleMode {
    <#
    .SYNOPSIS
        Interactively changes the TailscaleMode for this peer
    .DESCRIPTION
        AlwaysOn  - Tailscale stays connected at all times (default).
        PerJob    - Tailscale is enabled only while a backup job runs.
                    Use this when Tailscale causes VPN conflicts on the
                    client machine. Note: peer cannot RECEIVE backups in
                    this mode, but can still SEND them.
    #>
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "    CONFIGURE TAILSCALE MODE" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan

    $config = Get-RingConfig
    if (-not $config) {
        Write-Host "ERROR: This machine is not configured yet." -ForegroundColor Red
        Write-Host "Run 'Add Storage Peer' (P) first." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    $currentMode = Get-EffectiveTailscaleMode -Config $config

    Write-Host "Current mode: " -NoNewline
    Write-Host $currentMode -ForegroundColor $(if ($currentMode -eq 'PerJob') { 'Yellow' } else { 'Green' })
    Write-Host ""
    Write-Host "  1. AlwaysOn  - Tailscale runs continuously (default)" -ForegroundColor White
    Write-Host "     Peer can send AND receive backups." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. PerJob    - Tailscale activates only during backup jobs" -ForegroundColor White
    Write-Host "     Use when Tailscale conflicts with client applications." -ForegroundColor Gray
    Write-Host "     WARNING: Peer will NOT receive backups in this mode." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  0. Cancel" -ForegroundColor White
    Write-Host ""

    $choice = Read-Host "Select mode"

    $newMode = switch ($choice) {
        "1" { 'AlwaysOn' }
        "2" { 'PerJob' }
        "0" { $null }
        default { $null }
    }

    if (-not $newMode) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    if ($newMode -eq $currentMode) {
        Write-Host "`nMode is already set to '$currentMode'. No changes made." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }

    $config | Add-Member -NotePropertyName 'TailscaleMode' -NotePropertyValue $newMode -Force
    Save-RingConfig -Config $config

    Write-Host ""
    Write-Host "Tailscale mode set to: " -NoNewline
    Write-Host $newMode -ForegroundColor $(if ($newMode -eq 'PerJob') { 'Yellow' } else { 'Green' })

    if ($newMode -eq 'PerJob') {
        Write-Host ""
        Write-Host "REMINDER: This peer will no longer receive backups from other peers." -ForegroundColor Yellow
        Write-Host "Other peers will be notified on their next discovery scan." -ForegroundColor Gray
    }

    Read-Host "`nPress Enter to continue"
}

function Get-LocalLocation {
    <#
    .SYNOPSIS
        Gets the Location name from local configuration
    #>
    $config = Get-RingConfig
    if ($config) { return $config.Location }
    return $null
}

#endregion

#region Storage Peers List Management

function Get-StoragePeersList {
    <#
    .SYNOPSIS
        Gets the local storage peers list
    #>
    if (Test-Path $(Get-RRPeersFile)) {
        $data = Get-Content $(Get-RRPeersFile) -Raw | ConvertFrom-Json
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
    
    $peerData | ConvertTo-Json -Depth 10 | Set-Content $(Get-RRPeersFile) -Force
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
        $sharePath = "\\$TailscaleIP\$(Get-RRShareName)"
        
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
    
    $remotePath = "\\$TailscaleIP\$(Get-RRShareName)\peer-info.json"
    
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

#region RRM API Integration

function Register-PeerWithRrmApi {
    <#
    .SYNOPSIS
        Registers this peer with the Resilience Ring Monitor API.
        Sends peer info, jobs and destinations. Saves the returned apiKey to ring-config.json.
        Safe to call multiple times  -  the API endpoint is idempotent.
    .NOTES
        Requires ring-config.json to have RrmApiUrl and ProjectId set.
        If either is missing the function exits silently (not an error).
    #>
    param(
        [Parameter(Mandatory=$false)]
        [PSCustomObject]$Config  # pass already-loaded config to avoid re-reading
    )

    $config = if ($Config) { $Config } else { Get-RingConfig }
    if (-not $config) { return }

    # Use defaults for peers that haven't been configured with RRM yet
    $defaultRrmUrl   = 'https://api-test.mmi.lat/resilience-ring'
    $defaultProjectId = 1

    $rrmUrl   = if ($config.RrmApiUrl)  { $config.RrmApiUrl }  else { $defaultRrmUrl }
    $projId   = if ($config.ProjectId -ne $null) { $config.ProjectId | Select-Object -First 1 } else { $defaultProjectId }

    $apiUrl   = $rrmUrl.TrimEnd('/')

    # Map BackupType codes to API strings
    $typeMap = @{ 'F' = 'file'; 'D' = 'directory'; 'SQL' = 'database' }

    # Load jobs from local jobs.json
    $jobsFile = "C:\ProgramData\VLABS_ResilienceRing\jobs.json"
    $localJobs = @()
    if (Test-Path $jobsFile) {
        try { $localJobs = @(Get-Content $jobsFile -Raw | ConvertFrom-Json) } catch {}
    }

    # Build jobs payload
    # PS5.1 fix: use Generic.List so ConvertTo-Json always emits a JSON array
    # (PS5.1 serializes @() as null and single-element @(...) as {} instead of [...])
    $jobsPayload = New-Object System.Collections.Generic.List[object]
    foreach ($job in $localJobs) {
        $destinations = New-Object System.Collections.Generic.List[object]
        foreach ($dest in @($job.PeerDestinations)) {
            if (-not $dest.Hostname) { continue }  # skip incomplete destinations
            $destinations.Add(@{
                hostname    = $dest.Hostname
                tailscaleIp = $dest.TailscaleIP
                location    = $dest.Location
                basePath    = if ($dest.BasePath) { $dest.BasePath } else { '' }
            })
        }

        $jobsPayload.Add(@{
            name             = $job.JobName
            backupType       = if ($typeMap.ContainsKey($job.BackupType)) { $typeMap[$job.BackupType] } else { $job.BackupType }
            backupObject     = if ($job.BackupObject -is [array]) { $job.BackupObject -join '|' } else { [string]$job.BackupObject }
            frequencyHours   = [int]$(if ($job.Frequency -ne $null) { $job.Frequency | Select-Object -First 1 } else { 24 })
            retentionMonthly = [int]$(if ($job.RetentionMonthly -ne $null) { $job.RetentionMonthly | Select-Object -First 1 } else { 3 })
            retentionWeekly  = [int]$(if ($job.RetentionWeekly -ne $null) { $job.RetentionWeekly | Select-Object -First 1 } else { 4 })
            retentionRecent  = [int]$(if ($job.RetentionRecent -ne $null) { $job.RetentionRecent | Select-Object -First 1 } else { 7 })
            enabled          = [bool]$(if ($job.Enabled -ne $null) { $job.Enabled | Select-Object -First 1 } else { $true })
            destinations     = $destinations
        })
    }

    $endpoint = "$apiUrl/api/peers/register"

    # Hostname fallback: ring-config.json from older installs may not have this field
    $hostname = if ($config.Hostname) { $config.Hostname } `
                elseif ($config.WindowsHostname) { $config.WindowsHostname } `
                else { $env:COMPUTERNAME }

    $payload = @{
        hostname    = $hostname
        tailscaleIp = $config.TailscaleIP
        location    = $config.Location
        projectId   = [long]$projId
        jobs        = $jobsPayload
    } | ConvertTo-Json -Depth 10

    Write-RRDebug "RRM register payload: hostname=$hostname projectId=$projId location=$($config.Location) jobs=$($jobsPayload.Count)"
    Write-Host "DEBUG payload: $payload" -ForegroundColor DarkGray

    try {
        $response = Invoke-RestMethod `
            -Uri       $endpoint `
            -Method    POST `
            -Body      $payload `
            -ContentType 'application/json' `
            -TimeoutSec 30 `
            -ErrorAction Stop

        # Persist registration data for use in heartbeats
        if ($response.apiKey) {
            $config | Add-Member -NotePropertyName 'RrmApiKey'   -NotePropertyValue $response.apiKey -Force
            $config | Add-Member -NotePropertyName 'ProjectId'   -NotePropertyValue $projId          -Force

            # Always persist the URL that actually worked so it's explicit in the config.
            # If the API returns a new canonical URL (migration from test→prod), adopt it
            # automatically so next calls go to the right place without manual intervention.
            $canonicalUrl = if ($response.rrmApiUrl) { $response.rrmApiUrl.TrimEnd('/') } else { $apiUrl }
            $config | Add-Member -NotePropertyName 'RrmApiUrl' -NotePropertyValue $canonicalUrl -Force

            if ($response.rrmApiUrl -and $response.rrmApiUrl.TrimEnd('/') -ne $apiUrl) {
                Write-Host "  [RRM] API URL updated: $apiUrl → $canonicalUrl" -ForegroundColor Cyan
            }

            Save-RingConfig -Config $config
            Write-RRDebug "RRM API registration OK  -  peerId=$($response.peerId) url=$canonicalUrl"
        }

        return $response
    }
    catch {
        # Non-fatal  -  peer still works without the API
        # PS5.1: ErrorDetails.Message contains the HTTP response body
        $errMsg = if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $_.ErrorDetails.Message.Trim('"')
        } else {
            $_.Exception.Message
        }
        Write-RRDebug "RRM API registration failed: $errMsg"
        Write-Warning "Could not register with RRM API: $errMsg"
        Write-Warning "  URL: $endpoint | hostname: $hostname | projectId: $projId | location: $($config.Location)"
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
    
    # Step 4: Location Name
    Write-Host "STEP 4: Location Name" -ForegroundColor Yellow
    Write-Host "----------------------" -ForegroundColor Yellow
    Write-Host "Enter a friendly name for this computer's location."
    Write-Host "This is used to organize backups from different sites."
    Write-Host "Examples: San Antonio Villas, Main Office, Warehouse"
    Write-Host "`nLocation Name: " -NoNewline -ForegroundColor White
    $locationName = Read-Host
    
    if ([string]::IsNullOrWhiteSpace($locationName)) {
        Write-Host "[ERROR] Location name is required" -ForegroundColor Red
        Read-Host "`nPress Enter to return"
        return
    }
    
    Write-Host ""
    
    # Step 5: Storage Path
    Write-Host "STEP 5: Storage Path" -ForegroundColor Yellow
    Write-Host "---------------------" -ForegroundColor Yellow
    
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
    
    # Step 6: Quota
    Write-Host "STEP 6: Storage Quota" -ForegroundColor Yellow
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

    # Step 6b: RRM API Configuration (optional)
    Write-Host "STEP 6b: RRM Monitor API (optional)" -ForegroundColor Yellow
    Write-Host "-------------------------------------" -ForegroundColor Yellow
    Write-Host "If you have a Resilience Ring Monitor URL and Project ID," -ForegroundColor Gray
    Write-Host "this peer will register automatically and appear in the dashboard." -ForegroundColor Gray
    Write-Host ""
    $rrmDefaultUrl = 'https://api-test.mmi.lat/resilience-ring'
    Write-Host "RRM API URL [default: $rrmDefaultUrl] (leave blank to skip): " -NoNewline -ForegroundColor White
    $rrmApiUrlInput = (Read-Host).Trim()
    $rrmApiUrl = if ($rrmApiUrlInput) { $rrmApiUrlInput } else { $rrmDefaultUrl }

    $rrmProjectId = $null
    if ($rrmApiUrl) {
        Write-Host "Project ID (numeric): " -NoNewline -ForegroundColor White
        $rrmProjectIdInput = (Read-Host).Trim()
        if ($rrmProjectIdInput -match '^\d+$') {
            $rrmProjectId = [long]$rrmProjectIdInput
        } else {
            Write-Host "[WARN] Invalid Project ID  -  RRM integration skipped." -ForegroundColor Yellow
            $rrmApiUrl = $null
        }
    }

    Write-Host ""

    # Step 7: Create Service Account
    Write-Host "STEP 7: Creating Service Account" -ForegroundColor Yellow
    Write-Host "---------------------------------" -ForegroundColor Yellow
    
    if (-not (New-RingServiceAccount -CustomerCode $codename)) {
        Write-Host "[ERROR] Failed to create service account" -ForegroundColor Red
        Read-Host "`nPress Enter to return"
        return
    }
    
    Write-Host ""
    
    # Step 8: Create SMB Share with proper permissions
    Write-Host "STEP 8: Creating SMB Share" -ForegroundColor Yellow
    Write-Host "---------------------------" -ForegroundColor Yellow
    
    $existingShare = Get-SmbShare -Name $(Get-RRShareName) -ErrorAction SilentlyContinue
    if ($existingShare) {
        Write-Host "[INFO] Share '$(Get-RRShareName)' already exists" -ForegroundColor Yellow
        Write-Host "  Current path: $($existingShare.Path)" -ForegroundColor Gray
        
        if ($existingShare.Path -ne $storagePath) {
            Write-Host ""
            Write-Host "The share points to a different path. Update it? [Y/n]: " -NoNewline -ForegroundColor Yellow
            $updateShare = Read-Host
            
            if ($updateShare -eq '' -or $updateShare -match '^[Yy]') {
                Remove-SmbShare -Name $(Get-RRShareName) -Force -ErrorAction SilentlyContinue
                $existingShare = $null
            }
        }
        else {
            # Update permissions on existing share
            try {
                # Revoke all existing permissions and set new ones
                Revoke-SmbShareAccess -Name $(Get-RRShareName) -AccountName "Everyone" -Force -ErrorAction SilentlyContinue
                Grant-SmbShareAccess -Name $(Get-RRShareName) -AccountName $(Get-RRServiceUser) -AccessRight Full -Force | Out-Null
                Write-Host "[OK] Updated share permissions for '$(Get-RRServiceUser)'" -ForegroundColor Green
            }
            catch {
                Write-Host "[WARN] Could not update share permissions: $_" -ForegroundColor Yellow
            }
        }
    }
    
    if (-not $existingShare) {
        try {
            # Create share with RR_Service having full access
            New-SmbShare -Name $(Get-RRShareName) -Path $storagePath -FullAccess $(Get-RRServiceUser) -Description "VLABS Resilience Ring Storage" | Out-Null
            Write-Host "[OK] Created network share with service account access" -ForegroundColor Green
        }
        catch {
            Write-Host "[ERROR] Could not create SMB share: $_" -ForegroundColor Red
            Write-Host "Please manually share '$storagePath' as '$(Get-RRShareName)'" -ForegroundColor Yellow
            Read-Host "`nPress Enter to return"
            return
        }
    }
    
    # Also set NTFS permissions on the folder
    try {
        $acl = Get-Acl $storagePath
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $(Get-RRServiceUser), 
            "FullControl", 
            "ContainerInherit,ObjectInherit", 
            "None", 
            "Allow"
        )
        $acl.AddAccessRule($rule)
        Set-Acl $storagePath $acl
        Write-Host "[OK] Set NTFS permissions for '$(Get-RRServiceUser)'" -ForegroundColor Green
    }
    catch {
        Write-Host "[WARN] Could not set NTFS permissions: $_" -ForegroundColor Yellow
    }
    
    # Get Tailscale hostname for display
    $tailscaleHostname = $tsStatus.Self.DNSName -replace '\..*$', ''  # Get just the hostname part
    if (-not $tailscaleHostname) { $tailscaleHostname = $tsStatus.Self.HostName }
    
    Write-Host "[OK] Share accessible at: \\$tailscaleHostname\$(Get-RRShareName)" -ForegroundColor Green
    
    Write-Host ""
    
    # Step 9: Save Configuration
    Write-Host "STEP 9: Saving Configuration" -ForegroundColor Yellow
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
        TailscaleMode = 'AlwaysOn'
        Location = $locationName
        StoragePath = $storagePath
        QuotaGB = $quotaGB
        CreatedAt = (Get-Date).ToString('o')
    }

    # Add RRM API config if provided
    if ($rrmApiUrl -and $rrmProjectId) {
        $config['RrmApiUrl']   = $rrmApiUrl
        $config['ProjectId']   = $rrmProjectId
    }
    
    # Save local config
    Save-RingConfig -Config $config
    Write-Host "[OK] Ring configuration saved" -ForegroundColor Green
    
    # Create peer-info.json inside the share for discovery
    $peerInfoPath = Join-Path $storagePath "peer-info.json"
    $peerInfo = @{
        CustomerCode = $codename
        TailscaleTag = $tailscaleTag
        Location = $locationName
        Hostname = $tailscaleHostname
        WindowsHostname = $env:COMPUTERNAME
        TailscaleIP = $tsStatus.Self.TailscaleIPs[0]
        QuotaGB = $quotaGB
        Since = (Get-Date).ToString('o')
        Version = "1.6"
    }
    $peerInfo | ConvertTo-Json | Set-Content $peerInfoPath -Force
    Write-Host "[OK] Peer info file created" -ForegroundColor Green
    
    # Register this peer in the storage peers list
    $thisPeer = [PSCustomObject]@{
        Hostname = $tailscaleHostname
        TailscaleIP = $tsStatus.Self.TailscaleIPs[0]
        CustomerCode = $codename
        Location = $locationName
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
    Write-Host "  Location:       $locationName" -ForegroundColor White
    Write-Host "  Storage:        $($config.StoragePath)" -ForegroundColor White
    Write-Host "  Share:          \\$tailscaleHostname\$(Get-RRShareName)" -ForegroundColor White
    Write-Host "  Quota:          $($config.QuotaGB) GB" -ForegroundColor White
    Write-Host "  Service User:   $(Get-RRServiceUser)" -ForegroundColor White
    Write-Host ""
    Write-Host "This machine is now part of the Resilience Ring!" -ForegroundColor Yellow
    Write-Host "Other peers can discover it using 'Discover & Update' (D)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "IMPORTANT:" -ForegroundColor Cyan
    Write-Host "  1. Make sure this machine has the Tailscale tag '$tailscaleTag'" -ForegroundColor White
    Write-Host "     in your Tailscale admin console: https://login.tailscale.com/admin/machines" -ForegroundColor Gray
    Write-Host "  2. Run 'Add Storage Peer' (P) on other machines with the SAME" -ForegroundColor White
    Write-Host "     Customer Code '$codename' to join this ring." -ForegroundColor Gray

    # Register with RRM API if configured
    Write-Host ""
    if ($config.RrmApiUrl -and $config.ProjectId) {
        Write-Host "STEP 10: Registering with RRM API" -ForegroundColor Yellow
        Write-Host "----------------------------------" -ForegroundColor Yellow
        $apiResult = Register-PeerWithRrmApi -Config $config
        if ($apiResult) {
            Write-Host "[OK] Registered in RRM  -  peer ID: $($apiResult.peerId)" -ForegroundColor Green
        } else {
            Write-Host "[WARN] RRM registration skipped or failed (see log)" -ForegroundColor Yellow
        }
        Write-Host ""
    }

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
        Write-Host "  #  | Ping   | Location             | Tailscale Name     | IP Address" -ForegroundColor Gray
        Write-Host " ----|--------|----------------------|--------------------|-----------------" -ForegroundColor Gray
        
        $index = 1
        foreach ($peer in ($availablePeers | Sort-Object PingMs)) {
            $pingColor = if ($peer.PingMs -lt 50) { 'Green' } elseif ($peer.PingMs -lt 100) { 'Yellow' } else { 'Red' }
            $locationStr = if ($peer.Location) { $peer.Location } else { "N/A" }
            if ($locationStr.Length -gt 20) { $locationStr = $locationStr.Substring(0, 17) + "..." }
            $hostStr = if ($peer.Hostname) { $peer.Hostname } else { "Unknown" }
            if ($hostStr.Length -gt 18) { $hostStr = $hostStr.Substring(0, 15) + "..." }
            
            Write-Host (" {0,2} |" -f $index) -NoNewline
            Write-Host (" {0,5}ms" -f $peer.PingMs) -ForegroundColor $pingColor -NoNewline
            Write-Host (" | {0,-20} | {1,-18} | {2}" -f $locationStr, $hostStr, $peer.TailscaleIP)
            
            $index++
        }
    }
    
    if ($unavailablePeers.Count -gt 0) {
        Write-Host ""
        Write-Host " UNAVAILABLE ($($unavailablePeers.Count)):" -ForegroundColor Red
        foreach ($peer in $unavailablePeers) {
            Write-Host "  - $($peer.Hostname) [$($peer.TailscaleIP)]: $($peer.Reason)" -ForegroundColor DarkGray
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
        $sharePath = "\\$($peer.TailscaleIP)\$(Get-RRShareName)"
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
            Location = $peerInfo.Location
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

#region Destination Helper Functions

function Get-AvailableStoragePeers {
    <#
    .SYNOPSIS
        Returns a list of available storage peers for destination selection
        Excludes self and tests connectivity
    #>
    $config = Get-RingConfig
    if (-not $config -or -not $config.CustomerCode) {
        return @()
    }
    
    $peers = @(Get-StoragePeersList)
    $availablePeers = @()
    
    foreach ($peer in $peers) {
        # Skip self
        if ($peer.TailscaleIP -eq $config.TailscaleIP) {
            continue
        }
        
        # Test ping
        $pingResult = Test-PeerPing -TailscaleIP $peer.TailscaleIP
        if (-not $pingResult.Success) {
            continue
        }
        
        # Test SMB connection
        $connected = Connect-RingShare -TailscaleIP $peer.TailscaleIP -CustomerCode $config.CustomerCode
        if (-not $connected) {
            continue
        }
        
        # Verify share exists
        $sharePath = "\\$($peer.TailscaleIP)\$(Get-RRShareName)"
        $shareExists = Test-Path $sharePath -ErrorAction SilentlyContinue
        
        Disconnect-RingShare -TailscaleIP $peer.TailscaleIP
        
        if ($shareExists) {
            $availablePeers += [PSCustomObject]@{
                Hostname = $peer.Hostname
                TailscaleIP = $peer.TailscaleIP
                Location = $peer.Location
                CustomerCode = $peer.CustomerCode
                QuotaGB = $peer.QuotaGB
                PingMs = $pingResult.PingMs
            }
        }
    }
    
    return $availablePeers | Sort-Object PingMs
}

#region Storage Rebalancing

function Get-RebalancePathSizeBytes {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) { return [int64]0 }
    
    $size = (Get-ChildItem $Path -Recurse -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    if ($size) { return [int64]$size }
    return [int64]0
}

function Open-RebalancePeerRoot {
    param(
        $Peer,
        [string]$CustomerCode
    )
    
    if ($Peer.IsLocal) {
        if (Test-Path $Peer.RootPath) { return $Peer.RootPath }
        return $null
    }
    
    $connected = Connect-RingShare -TailscaleIP $Peer.TailscaleIP -CustomerCode $CustomerCode
    if (-not $connected) {
        return $null
    }
    
    if (Test-Path $Peer.RootPath -ErrorAction SilentlyContinue) {
        return $Peer.RootPath
    }
    
    Disconnect-RingShare -TailscaleIP $Peer.TailscaleIP
    return $null
}

function Close-RebalancePeerRoot {
    param($Peer)
    
    if (-not $Peer.IsLocal) {
        Disconnect-RingShare -TailscaleIP $Peer.TailscaleIP
    }
}

function Get-RebalancePeerCatalog {
    <#
    .SYNOPSIS
        Returns all known peers with current usage and quota information
    #>
    $config = Get-RingConfig
    if (-not $config -or -not $config.CustomerCode) {
        return @()
    }
    
    $peerTable = @{}
    foreach ($peer in @(Get-StoragePeersList)) {
        if (-not $peer.TailscaleIP) { continue }
        
        $peerTable[$peer.TailscaleIP] = [PSCustomObject]@{
            Hostname = $peer.Hostname
            TailscaleIP = $peer.TailscaleIP
            Location = $peer.Location
            CustomerCode = $peer.CustomerCode
            QuotaGB = if ($peer.QuotaGB) { [double]$peer.QuotaGB } else { 0 }
        }
    }
    
    if ($config.TailscaleIP) {
        $existing = $peerTable[$config.TailscaleIP]
        if (-not $existing) {
            $existing = [PSCustomObject]@{
                Hostname = $config.Hostname
                TailscaleIP = $config.TailscaleIP
                Location = $config.Location
                CustomerCode = $config.CustomerCode
                QuotaGB = if ($config.QuotaGB) { [double]$config.QuotaGB } else { 0 }
            }
            $peerTable[$config.TailscaleIP] = $existing
        }
        elseif ((-not $existing.QuotaGB) -and $config.QuotaGB) {
            $existing.QuotaGB = [double]$config.QuotaGB
        }
    }
    
    $catalog = @()
    foreach ($peer in $peerTable.Values) {
        $isLocal = ($config.TailscaleIP -and $peer.TailscaleIP -eq $config.TailscaleIP)
        $rootPath = if ($isLocal) { $config.StoragePath } else { "\\$($peer.TailscaleIP)\$(Get-RRShareName)" }
        
        $entry = [PSCustomObject]@{
            Hostname = $peer.Hostname
            TailscaleIP = $peer.TailscaleIP
            Location = $peer.Location
            CustomerCode = $peer.CustomerCode
            QuotaGB = $peer.QuotaGB
            QuotaBytes = if ($peer.QuotaGB -gt 0) { [int64]($peer.QuotaGB * 1GB) } else { [int64]0 }
            IsLocal = $isLocal
            RootPath = $rootPath
            Accessible = $false
            UsedBytes = [int64]0
            UsedGB = 0
            RemainingBytes = [int64]0
            ExcessBytes = [int64]0
        }
        
        $openedPath = Open-RebalancePeerRoot -Peer $entry -CustomerCode $config.CustomerCode
        if ($openedPath) {
            try {
                $entry.Accessible = $true
                $entry.UsedBytes = Get-RebalancePathSizeBytes -Path $openedPath
                $entry.UsedGB = [math]::Round($entry.UsedBytes / 1GB, 2)
                $statusFile = Join-Path $openedPath "_nodeinfo\jobs-status.json"
                if (Test-Path $statusFile) {
                    try {
                        $nodeStatus = Get-Content $statusFile -Raw | ConvertFrom-Json
                        if ($null -ne $nodeStatus.CDriveFreeGB) {
                            $entry | Add-Member -NotePropertyName 'CDriveFreeGB' -NotePropertyValue $nodeStatus.CDriveFreeGB -Force
                        }
                        if ($null -ne $nodeStatus.StorageDriveFreeGB) {
                            $entry | Add-Member -NotePropertyName 'StorageDriveFreeGB' -NotePropertyValue $nodeStatus.StorageDriveFreeGB -Force
                        }
                    }
                    catch { }
                }
                if ($entry.QuotaBytes -gt 0) {
                    $entry.RemainingBytes = [math]::Max([int64]0, [int64]($entry.QuotaBytes - $entry.UsedBytes))
                    $entry.ExcessBytes = [math]::Max([int64]0, [int64]($entry.UsedBytes - $entry.QuotaBytes))
                }
            }
            finally {
                Close-RebalancePeerRoot -Peer $entry
            }
        }
        
        $catalog += $entry
    }
    
    return $catalog | Sort-Object Hostname
}

function Get-RebalanceFolderStats {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        return [PSCustomObject]@{ FileCount = 0; TotalBytes = [int64]0 }
    }
    
    $files = Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue
    $fileCount = @($files).Count
    $totalBytes = ($files | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    $resultBytes = if ($totalBytes) { $totalBytes } else { 0 }
    
    return [PSCustomObject]@{
        FileCount = $fileCount
        TotalBytes = [int64]$resultBytes
    }
}

function New-RebalanceCandidate {
    param(
        [string]$OpenedPath,
        [string]$CandidatePath,
        [string]$Customer,
        [string]$Location,
        [string]$Application,
        [string]$BackupType,
        [string]$BackupFolder,
        [string]$ItemKind = 'Folder'
    )
    
    $relativePath = $CandidatePath.Substring($OpenedPath.Length).TrimStart('\')
    $stats = if ($ItemKind -eq 'DirectFiles') {
        $files = Get-ChildItem $CandidatePath -File -ErrorAction SilentlyContinue
        $totalBytes = ($files | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        $resultBytes = if ($totalBytes) { $totalBytes } else { 0 }
        [PSCustomObject]@{
            FileCount = @($files).Count
            TotalBytes = [int64]$resultBytes
        }
    } else {
        Get-RebalanceFolderStats -Path $CandidatePath
    }
    
    return [PSCustomObject]@{
        RelativePath = $relativePath
        FullPath = $CandidatePath
        SizeBytes = $stats.TotalBytes
        SizeGB = [math]::Round($stats.TotalBytes / 1GB, 2)
        Customer = $Customer
        Location = $Location
        Application = $Application
        BackupType = $BackupType
        BackupFolder = $BackupFolder
        ItemKind = $ItemKind
        FileCount = $stats.FileCount
    }
}

function Get-RebalanceBackupFolders {
    param($Peer)
    
    $config = Get-RingConfig
    $folders = @()
    $openedPath = Open-RebalancePeerRoot -Peer $Peer -CustomerCode $config.CustomerCode
    if (-not $openedPath) {
        return @()
    }
    
    try {
        $customerDirs = Get-ChildItem $openedPath -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -ne '_nodeinfo' }
        $seenPaths = @{}
        
        foreach ($customerDir in $customerDirs) {
            foreach ($locationDir in @(Get-ChildItem $customerDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                foreach ($applicationDir in @(Get-ChildItem $locationDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                    $childDirs = @(Get-ChildItem $applicationDir.FullName -Directory -ErrorAction SilentlyContinue)
                    foreach ($childDir in $childDirs) {
                        $isKnownTypeDir = $childDir.Name -in @('file', 'directory', 'database')
                        
                        if ($isKnownTypeDir) {
                            $directFiles = @(Get-ChildItem $childDir.FullName -File -ErrorAction SilentlyContinue)
                            if ($directFiles.Count -gt 0 -and -not $seenPaths.ContainsKey($childDir.FullName)) {
                                $folders += New-RebalanceCandidate `
                                    -OpenedPath $openedPath `
                                    -CandidatePath $childDir.FullName `
                                    -Customer $customerDir.Name `
                                    -Location $locationDir.Name `
                                    -Application $applicationDir.Name `
                                    -BackupType $childDir.Name `
                                    -BackupFolder '[direct-files]' `
                                    -ItemKind 'DirectFiles'
                                $seenPaths[$childDir.FullName] = $true
                            }
                            
                            foreach ($backupDir in @(Get-ChildItem $childDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                                if ($seenPaths.ContainsKey($backupDir.FullName)) { continue }
                                $folders += New-RebalanceCandidate `
                                    -OpenedPath $openedPath `
                                    -CandidatePath $backupDir.FullName `
                                    -Customer $customerDir.Name `
                                    -Location $locationDir.Name `
                                    -Application $applicationDir.Name `
                                    -BackupType $childDir.Name `
                                    -BackupFolder $backupDir.Name
                                $seenPaths[$backupDir.FullName] = $true
                            }
                        }
                        else {
                            if ($seenPaths.ContainsKey($childDir.FullName)) { continue }
                            $folders += New-RebalanceCandidate `
                                -OpenedPath $openedPath `
                                -CandidatePath $childDir.FullName `
                                -Customer $customerDir.Name `
                                -Location $locationDir.Name `
                                -Application $applicationDir.Name `
                                -BackupType 'legacy' `
                                -BackupFolder $childDir.Name
                            $seenPaths[$childDir.FullName] = $true
                        }
                    }
                }
            }
        }
    }
    finally {
        Close-RebalancePeerRoot -Peer $Peer
    }
    
    return $folders | Sort-Object SizeBytes -Descending
}

function Find-RebalanceTargetPeer {
    param(
        $SourcePeer,
        $BackupFolder,
        [array]$PeerCatalog
    )
    
    $candidatePeers = $PeerCatalog |
        Where-Object {
            $_.Accessible -and
            $_.TailscaleIP -ne $SourcePeer.TailscaleIP -and
            $_.QuotaBytes -gt 0 -and
            $_.RemainingBytes -ge $BackupFolder.SizeBytes
        } |
        Sort-Object RemainingBytes -Descending
    
    foreach ($peer in $candidatePeers) {
        $config = Get-RingConfig
        $openedPath = Open-RebalancePeerRoot -Peer $peer -CustomerCode $config.CustomerCode
        if (-not $openedPath) { continue }
        
        try {
            $destPath = Join-Path $openedPath $BackupFolder.RelativePath
            if ($BackupFolder.ItemKind -eq 'DirectFiles') {
                if (-not (Test-Path $destPath)) {
                    return $peer
                }
                
                $sourceFiles = @(Get-ChildItem $BackupFolder.FullPath -File -ErrorAction SilentlyContinue)
                $hasConflict = $false
                foreach ($file in $sourceFiles) {
                    if (Test-Path (Join-Path $destPath $file.Name)) {
                        $hasConflict = $true
                        break
                    }
                }
                
                if (-not $hasConflict) {
                    return $peer
                }
            }
            elseif (-not (Test-Path $destPath)) {
                return $peer
            }
        }
        finally {
            Close-RebalancePeerRoot -Peer $peer
        }
    }
    
    return $null
}

function Move-RebalanceBackupFolder {
    param(
        $SourcePeer,
        $TargetPeer,
        $BackupFolder
    )
    
    $config = Get-RingConfig
    $sourceRoot = Open-RebalancePeerRoot -Peer $SourcePeer -CustomerCode $config.CustomerCode
    if (-not $sourceRoot) {
        return [PSCustomObject]@{ Success = $false; Reason = "Source inaccessible" }
    }
    
    $targetRoot = Open-RebalancePeerRoot -Peer $TargetPeer -CustomerCode $config.CustomerCode
    if (-not $targetRoot) {
        Close-RebalancePeerRoot -Peer $SourcePeer
        return [PSCustomObject]@{ Success = $false; Reason = "Target inaccessible" }
    }
    
    try {
        $sourcePath = Join-Path $sourceRoot $BackupFolder.RelativePath
        $targetPath = Join-Path $targetRoot $BackupFolder.RelativePath
        $targetParent = Split-Path $targetPath -Parent
        
        if ($BackupFolder.ItemKind -ne 'DirectFiles' -and (Test-Path $targetPath)) {
            return [PSCustomObject]@{ Success = $false; Reason = "Target already contains backup" }
        }
        
        if ($BackupFolder.ItemKind -eq 'DirectFiles') {
            if (-not (Test-Path $targetPath)) {
                New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
            }
        }
        elseif (-not (Test-Path $targetParent)) {
            New-Item -Path $targetParent -ItemType Directory -Force | Out-Null
        }

        if ($BackupFolder.ItemKind -eq 'DirectFiles') {
            $sourceFiles = @(Get-ChildItem $sourcePath -File -ErrorAction SilentlyContinue)
            if ($sourceFiles.Count -eq 0) {
                return [PSCustomObject]@{ Success = $false; Reason = "No direct files found" }
            }
            
            foreach ($file in $sourceFiles) {
                Copy-Item -Path $file.FullName -Destination (Join-Path $targetPath $file.Name) -Force -ErrorAction Stop
            }
            
            $sourceFileCount = $sourceFiles.Count
            $sourceBytes = [int64](($sourceFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum)
            $verifiedBytes = [int64]0
            foreach ($file in $sourceFiles) {
                $targetFile = Join-Path $targetPath $file.Name
                if (-not (Test-Path $targetFile)) {
                    return [PSCustomObject]@{ Success = $false; Reason = "Verification failed" }
                }
                
                $targetInfo = Get-Item $targetFile -ErrorAction Stop
                if ($targetInfo.Length -ne $file.Length) {
                    return [PSCustomObject]@{ Success = $false; Reason = "Verification failed" }
                }
                
                $verifiedBytes += [int64]$targetInfo.Length
            }
            
            if ($verifiedBytes -ne $sourceBytes) {
                return [PSCustomObject]@{ Success = $false; Reason = "Verification failed" }
            }
            
            foreach ($file in $sourceFiles) {
                Remove-Item $file.FullName -Force -ErrorAction Stop
            }
        }
        else {
            $robocopyLog = Join-Path $script:LogPath "rebalance_$($SourcePeer.Hostname)_to_$($TargetPeer.Hostname)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            $robocopyArgs = @(
                "`"$sourcePath`"",
                "`"$targetPath`"",
                "/E",
                "/DCOPY:DAT", "/COPY:DAT",
                "/R:2", "/W:5", "/MT:8",
                "/LOG:`"$robocopyLog`""
            )
            
            & robocopy @robocopyArgs | Out-Null
            $exitCode = $LASTEXITCODE
            if ($exitCode -gt 7) {
                return [PSCustomObject]@{ Success = $false; Reason = "Robocopy failed ($exitCode)" }
            }
            
            $sourceStats = Get-RebalanceFolderStats -Path $sourcePath
            $targetStats = Get-RebalanceFolderStats -Path $targetPath
            if (($sourceStats.FileCount -ne $targetStats.FileCount) -or ($sourceStats.TotalBytes -ne $targetStats.TotalBytes)) {
                return [PSCustomObject]@{ Success = $false; Reason = "Verification failed" }
            }
            
            Remove-Item $sourcePath -Recurse -Force -ErrorAction Stop
        }
        
        return [PSCustomObject]@{
            Success = $true
            MovedBytes = if ($BackupFolder.ItemKind -eq 'DirectFiles') { $sourceBytes } else { $sourceStats.TotalBytes }
            FileCount = if ($BackupFolder.ItemKind -eq 'DirectFiles') { $sourceFileCount } else { $sourceStats.FileCount }
        }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Reason = $_.Exception.Message }
    }
    finally {
        Close-RebalancePeerRoot -Peer $TargetPeer
        Close-RebalancePeerRoot -Peer $SourcePeer
    }
}

function Invoke-StorageRebalance {
    <#
    .SYNOPSIS
        Rebalances backup folders away from peers that exceed their quota
    #>
    Clear-Host
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "        REBALANCE STORAGE" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
    
    $config = Get-RingConfig
    if (-not $config -or -not $config.CustomerCode) {
        Write-Host "Ring is not configured on this node." -ForegroundColor Red
        Read-Host "`nPress Enter to continue"
        return
    }
    
    Write-Host "Analyzing peer usage and quotas..." -ForegroundColor Gray
    $peerCatalog = @(Get-RebalancePeerCatalog)
    $overQuotaPeers = $peerCatalog | Where-Object { $_.Accessible -and $_.ExcessBytes -gt 0 } | Sort-Object ExcessBytes -Descending
    $inaccessiblePeers = $peerCatalog | Where-Object { -not $_.Accessible }
    
    if ($overQuotaPeers.Count -eq 0) {
        Write-Host "`nNo accessible peers are over quota." -ForegroundColor Green
        if ($inaccessiblePeers.Count -gt 0) {
            Write-Host "`nPeers not analyzed:" -ForegroundColor Yellow
            foreach ($peer in $inaccessiblePeers) {
                Write-Host "  - $($peer.Hostname) [$($peer.TailscaleIP)]" -ForegroundColor DarkGray
            }
        }
        Read-Host "`nPress Enter to continue"
        return
    }
    
    Write-Host "`nPeers over quota:" -ForegroundColor Yellow
    Write-Host "  # | Hostname              | Location             | C Free | Used GB | Quota GB | Excess GB" -ForegroundColor Gray
    Write-Host " ---|-----------------------|----------------------|--------|---------|----------|----------" -ForegroundColor Gray
    for ($i = 0; $i -lt $overQuotaPeers.Count; $i++) {
        $peer = $overQuotaPeers[$i]
        $hostnameStr = if ($peer.Hostname) { $peer.Hostname } else { "Unknown" }
        if ($hostnameStr.Length -gt 21) { $hostnameStr = $hostnameStr.Substring(0, 21) }
        $locationStr = if ($peer.Location) { $peer.Location } else { "N/A" }
        if ($locationStr.Length -gt 20) { $locationStr = $locationStr.Substring(0, 20) }
        $cFreeStr = if ($null -ne $peer.CDriveFreeGB) { [string]([math]::Round([double]$peer.CDriveFreeGB, 1)) } else { "N/A" }
        
        Write-Host (" {0,2} | {1,-21} | {2,-20} | {3,6} | {4,7} | {5,8} | {6,8}" -f `
            ($i + 1),
            $hostnameStr,
            $locationStr,
            $cFreeStr,
            ([math]::Round($peer.UsedBytes / 1GB, 2)),
            $peer.QuotaGB,
            ([math]::Round($peer.ExcessBytes / 1GB, 2)))
    }
    
    if ($inaccessiblePeers.Count -gt 0) {
        Write-Host "`nPeers not analyzed:" -ForegroundColor Yellow
        foreach ($peer in $inaccessiblePeers) {
            Write-Host "  - $($peer.Hostname) [$($peer.TailscaleIP)]" -ForegroundColor DarkGray
        }
    }
    
    Write-Host ""
    Write-Host "This will move verified backup folders to peers with available quota." -ForegroundColor White
    Write-Host "No source folder is deleted until the copy is verified." -ForegroundColor White
    Write-Host ""
    Write-Host "Continue with rebalance? [Y/n]: " -NoNewline -ForegroundColor Yellow
    $response = Read-Host
    if ($response -ne '' -and $response -notmatch '^[Yy]') {
        Write-Host "`nRebalance cancelled." -ForegroundColor Yellow
        Read-Host "`nPress Enter to continue"
        return
    }
    
    $summary = @()
    foreach ($sourcePeer in $overQuotaPeers) {
        Write-Host "`nProcessing $($sourcePeer.Hostname)..." -ForegroundColor Cyan
        $folders = @(Get-RebalanceBackupFolders -Peer $sourcePeer)
        if ($folders.Count -eq 0) {
            Write-Host "  No backup folders found to move." -ForegroundColor Yellow
            $summary += [PSCustomObject]@{
                Source = $sourcePeer.Hostname
                MovedGB = 0
                RemainingExcessGB = [math]::Round($sourcePeer.ExcessBytes / 1GB, 2)
                Status = "No movable folders"
            }
            continue
        }
        
        $movedBytes = [int64]0
        foreach ($folder in $folders) {
            if ($sourcePeer.ExcessBytes -le 0) { break }
            
            $targetPeer = Find-RebalanceTargetPeer -SourcePeer $sourcePeer -BackupFolder $folder -PeerCatalog $peerCatalog
            if (-not $targetPeer) { continue }
            
            Write-Host "  Moving $($folder.RelativePath) -> $($targetPeer.Hostname)" -ForegroundColor Gray
            $result = Move-RebalanceBackupFolder -SourcePeer $sourcePeer -TargetPeer $targetPeer -BackupFolder $folder
            if ($result.Success) {
                $bytesMoved = if ($result.MovedBytes) { [int64]$result.MovedBytes } else { [int64]$folder.SizeBytes }
                $sourcePeer.UsedBytes = [math]::Max([int64]0, [int64]($sourcePeer.UsedBytes - $bytesMoved))
                $sourcePeer.ExcessBytes = [math]::Max([int64]0, [int64]($sourcePeer.UsedBytes - $sourcePeer.QuotaBytes))
                $sourcePeer.RemainingBytes = [math]::Max([int64]0, [int64]($sourcePeer.QuotaBytes - $sourcePeer.UsedBytes))
                $targetPeer.UsedBytes = [int64]($targetPeer.UsedBytes + $bytesMoved)
                $targetPeer.ExcessBytes = [math]::Max([int64]0, [int64]($targetPeer.UsedBytes - $targetPeer.QuotaBytes))
                $targetPeer.RemainingBytes = [math]::Max([int64]0, [int64]($targetPeer.QuotaBytes - $targetPeer.UsedBytes))
                $movedBytes += $bytesMoved
                Write-Log "Rebalanced $($folder.RelativePath) from $($sourcePeer.Hostname) to $($targetPeer.Hostname)" -Level SUCCESS
                Write-Host "    OK ($([math]::Round($bytesMoved / 1GB, 2)) GB)" -ForegroundColor Green
            }
            else {
                Write-Log "Failed to rebalance $($folder.RelativePath) from $($sourcePeer.Hostname): $($result.Reason)" -Level WARNING
                Write-Host "    Skipped: $($result.Reason)" -ForegroundColor Yellow
            }
        }
        
        $summary += [PSCustomObject]@{
            Source = $sourcePeer.Hostname
            MovedGB = [math]::Round($movedBytes / 1GB, 2)
            RemainingExcessGB = [math]::Round($sourcePeer.ExcessBytes / 1GB, 2)
            Status = if ($sourcePeer.ExcessBytes -le 0) { "Balanced" } else { "Still over quota" }
        }
    }
    
    Write-Host "`nRebalance summary:" -ForegroundColor Cyan
    foreach ($item in $summary) {
        $color = if ($item.Status -eq "Balanced") { "Green" } else { "Yellow" }
        Write-Host ("  {0,-21} moved {1,7} GB | remaining excess {2,7} GB | {3}" -f `
            $item.Source, $item.MovedGB, $item.RemainingExcessGB, $item.Status) -ForegroundColor $color
    }
    
    Read-Host "`nPress Enter to continue"
}

#endregion

function Get-DestinationPath {
    <#
    .SYNOPSIS
        Builds the destination path for a backup job
        Format: \\IP\RR_Backups\CUSTOMER_CODE\Location\Application\type\
    #>
    param(
        [string]$TailscaleIP,
        [string]$CustomerCode,
        [string]$Location,
        [string]$Application,
        [string]$BackupType
    )
    
    # Map backup type to folder name
    $typeFolderMap = @{
        "F" = "file"
        "D" = "directory"
        "SQL" = "database"
    }
    
    $typeFolder = $typeFolderMap[$BackupType]
    if (-not $typeFolder) { $typeFolder = $BackupType.ToLower() }
    
    # Build path: \\IP\RR_Backups\CODE\Location\Application\type\
    $destPath = "\\$TailscaleIP\$(Get-RRShareName)\$($CustomerCode.ToUpper())\$Location\$Application\$typeFolder"
    
    return $destPath
}

function Initialize-DestinationPath {
    <#
    .SYNOPSIS
        Creates the destination path if it doesn't exist
    #>
    param(
        [string]$TailscaleIP,
        [string]$DestinationPath,
        [string]$CustomerCode
    )
    
    # Connect to share
    $connected = Connect-RingShare -TailscaleIP $TailscaleIP -CustomerCode $CustomerCode
    if (-not $connected) {
        Write-Host "[ERROR] Could not connect to storage peer" -ForegroundColor Red
        return $false
    }
    
    # Create path if needed
    if (-not (Test-Path $DestinationPath)) {
        try {
            New-Item -Path $DestinationPath -ItemType Directory -Force | Out-Null
            Write-Host "[OK] Created destination path: $DestinationPath" -ForegroundColor Green
        }
        catch {
            Write-Host "[ERROR] Could not create destination path: $_" -ForegroundColor Red
            Disconnect-RingShare -TailscaleIP $TailscaleIP
            return $false
        }
    }
    else {
        Write-Host "[OK] Destination path exists: $DestinationPath" -ForegroundColor Green
    }
    
    # Test write permissions
    $testFile = Join-Path $DestinationPath "test_write_$(Get-Date -Format 'yyyyMMddHHmmss').tmp"
    try {
        "test" | Out-File -FilePath $testFile -ErrorAction Stop
        Remove-Item $testFile -Force -ErrorAction Stop
        Write-Host "[OK] Write permissions verified" -ForegroundColor Green
    }
    catch {
        Write-Host "[ERROR] Path is not writable: $_" -ForegroundColor Red
        Disconnect-RingShare -TailscaleIP $TailscaleIP
        return $false
    }
    
    Disconnect-RingShare -TailscaleIP $TailscaleIP
    return $true
}

function Invoke-StartupDiscovery {
    <#
    .SYNOPSIS
        Runs discovery at startup with a simple progress indicator
    #>
    
    # Check health first
    $health = Test-RingHealth
    
    if (-not $health.ConfigExists) {
        Write-Host "[INFO] Ring not configured - run 'Add Storage Peer' (P) to set up" -ForegroundColor Yellow
        return
    }
    
    $config = Get-RingConfig
    if (-not $config -or -not $config.CustomerCode) {
        Write-Host "[WARN] Config file exists but is invalid - run P to reconfigure" -ForegroundColor Yellow
        return
    }
    
    Write-Host "Discovering storage peers" -NoNewline -ForegroundColor Gray
    
    # Get tagged peers from Tailscale
    $taggedPeers = Get-TailscalePeersByTag -Tag $config.TailscaleTag
    
    if ($taggedPeers.Count -eq 0) {
        Write-Host " [No peers found]" -ForegroundColor Yellow
        return
    }
    
    $discovered = 0
    foreach ($peer in $taggedPeers) {
        Write-Host "." -NoNewline -ForegroundColor Gray
        
        # Skip self
        if ($peer.TailscaleIP -eq $config.TailscaleIP) { continue }
        
        # Quick ping test
        $pingResult = Test-PeerPing -TailscaleIP $peer.TailscaleIP
        if (-not $pingResult.Success) { continue }
        
        # Try to connect and get peer info
        $connected = Connect-RingShare -TailscaleIP $peer.TailscaleIP -CustomerCode $config.CustomerCode
        if (-not $connected) { continue }
        
        $peerInfo = Get-PeerInfo -TailscaleIP $peer.TailscaleIP
        Disconnect-RingShare -TailscaleIP $peer.TailscaleIP
        
        if ($peerInfo -and $peerInfo.CustomerCode -eq $config.CustomerCode) {
            $peerHostname = if ($peerInfo.Hostname) { $peerInfo.Hostname } else { $peer.HostName }
            
            Add-PeerToList -Peer ([PSCustomObject]@{
                Hostname = $peerHostname
                TailscaleIP = $peer.TailscaleIP
                CustomerCode = $peerInfo.CustomerCode
                Location = $peerInfo.Location
                AddedAt = (Get-Date).ToString('o')
                QuotaGB = $peerInfo.QuotaGB
            })
            $discovered++
        }
    }
    
    $totalPeers = (Get-StoragePeersList).Count
    Write-Host " [$totalPeers peers]" -ForegroundColor Green
}

#endregion

#region Startup Validation

function Invoke-TransactionDataMigration {
    <#
    .SYNOPSIS
        Migrates transaction data (LastRun, LastStatus, etc.) from jobs.json to jobs-status.json
    .DESCRIPTION
        One-time migration for existing installations. Extracts transaction fields
        from jobs.json and saves them to the separate jobs-status.json file.
        Part of the master/transaction data separation design principle.
    .OUTPUTS
        Returns count of jobs migrated
    #>
    $dataPath = Get-RRDataPath
    $jobsFile = Join-Path $dataPath "jobs.json"
    $statusFile = Join-Path $dataPath "jobs-status.json"
    
    # Skip if status file already exists (already migrated)
    if (Test-Path $statusFile) { return 0 }
    
    # Skip if no jobs file
    if (-not (Test-Path $jobsFile)) { return 0 }
    
    try {
        $rawContent = Get-Content $jobsFile -Raw | ConvertFrom-Json
        
        # Handle corrupted format
        if ($rawContent -is [PSCustomObject] -and $rawContent.PSObject.Properties.Name -contains 'value') {
            $jobs = @($rawContent.value)
        }
        else {
            $jobs = @($rawContent)
        }
        
        if ($jobs.Count -eq 0) { return 0 }
        
        # Extract transaction data
        $statusArray = @()
        foreach ($job in $jobs) {
            if ($job.JobName -and ($job.LastRun -or $job.LastStatus)) {
                $statusArray += [PSCustomObject]@{
                    JobName = $job.JobName
                    LastRun = $job.LastRun
                    LastStatus = $job.LastStatus
                    LastDurationSeconds = if ($job.LastDurationSeconds) { $job.LastDurationSeconds } else { 0 }
                    LastSizeBytes = if ($job.LastSizeBytes) { $job.LastSizeBytes } else { 0 }
                }
            }
        }
        
        if ($statusArray.Count -gt 0) {
            # Save transaction data to new file
            $json = ConvertTo-Json -InputObject $statusArray -Depth 10
            Set-Content -Path $statusFile -Value $json -Force
            Write-RRDebug "Migrated transaction data for $($statusArray.Count) jobs to jobs-status.json"
        }
        
        return $statusArray.Count
    }
    catch {
        Write-RRDebug "Transaction data migration failed: $_"
        return 0
    }
}

function Invoke-JobsValidation {
    <#
    .SYNOPSIS
        Validates jobs.json format and syncs with Windows Scheduled Tasks
    .DESCRIPTION
        Called on TUI startup to ensure:
        1. Jobs have all required fields (migrates legacy format if needed)
        2. Each job has a corresponding scheduled task
        3. Orphaned tasks are reported
    .OUTPUTS
        Returns validation result object with Issues array
    #>
    $result = @{
        JobsChecked = 0
        JobsMigrated = 0
        JobsRepaired = 0      # Auto-fixed issues (silent success)
        TasksCreated = 0
        TasksFixed = 0
        Issues = @()          # Only actual problems that need user attention
    }
    
    $jobsFile = Join-Path (Get-RRDataPath) "jobs.json"
    if (-not (Test-Path $jobsFile)) {
        return $result
    }
    
    # Migrate transaction data to separate file (one-time migration)
    $migratedCount = Invoke-TransactionDataMigration
    if ($migratedCount -gt 0) {
        $result.JobsMigrated += $migratedCount
        # Not an issue - just a migration that happened silently
    }
    
    try {
        $rawContent = Get-Content $jobsFile -Raw | ConvertFrom-Json
        
        # Handle corrupted format where jobs are wrapped in {"value": [...], "Count": N}
        # This happens when PowerShell's ConvertTo-Json pipes an array
        if ($rawContent -is [PSCustomObject] -and $rawContent.PSObject.Properties.Name -contains 'value') {
            $jobs = @($rawContent.value)
            # Silent repair - not shown to user
            $result.JobsRepaired++
            $modified = $true
            Write-RRDebug "Invoke-JobsValidation: Extracted $($jobs.Count) jobs from 'value' property (auto-repaired)"
        }
        else {
            $jobs = @($rawContent)
        }
        
        # Debug: Log what we got
        Write-RRDebug "Invoke-JobsValidation: Loaded $($jobs.Count) jobs from file"
        
        # Debug: Log first job structure to help diagnose issues
        if ($jobs.Count -gt 0) {
            $firstJob = $jobs[0]
            $props = if ($firstJob -is [PSCustomObject]) { 
                ($firstJob.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '
            } else { 
                "Not PSCustomObject: $($firstJob.GetType().Name)" 
            }
            Write-RRDebug "Invoke-JobsValidation: First job properties: $props"
            Write-RRDebug "Invoke-JobsValidation: First job JobName = '$($firstJob.JobName)'"
        }
    }
    catch {
        $result.Issues += "Could not parse jobs.json: $_"
        return $result
    }
    
    # Validate jobs have required fields
    # Use more robust check for JobName property existence
    $validJobs = @()
    $invalidCount = 0
    
    foreach ($job in $jobs) {
        $jobName = $null
        
        # Try to get JobName in multiple ways (PSCustomObject vs hashtable)
        if ($job -is [PSCustomObject] -and $job.PSObject.Properties.Name -contains 'JobName') {
            $jobName = $job.JobName
        }
        elseif ($job -is [hashtable] -and $job.ContainsKey('JobName')) {
            $jobName = $job['JobName']
        }
        
        if ($jobName -and $jobName -ne '') {
            $validJobs += $job
        }
        else {
            $invalidCount++
            Write-RRDebug "Invoke-JobsValidation: Invalid job found - JobName is empty or missing"
        }
    }
    
    if ($invalidCount -gt 0) {
        $result.Issues += "Found $invalidCount job(s) with empty names (not removed - manual review needed)"
    }
    
    Write-RRDebug "Invoke-JobsValidation: $($validJobs.Count) valid jobs after filter"
    
    if ($validJobs.Count -eq 0 -and $jobs.Count -gt 0) {
        # All jobs are invalid - this is suspicious, don't save
        $result.Issues += "WARNING: All jobs appear invalid - NOT modifying file (manual review needed)"
        # Write debug file to help diagnose
        try {
            $debugFile = Join-Path (Get-RRDataPath) "jobs-debug.json"
            $rawContent | ConvertTo-Json -Depth 10 | Set-Content $debugFile -Force
            $result.Issues += "Debug: Wrote raw content to jobs-debug.json for analysis"
        } catch { }
        return $result
    }
    
    $jobs = $validJobs
    if ($jobs.Count -eq 0) { return $result }
    
    # Note: $modified may already be true from value wrapper detection above
    if ($null -eq $modified) { $modified = $false }
    $result.JobsChecked = $jobs.Count
    
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $job = $jobs[$i]
        
        # Ensure TaskName exists and matches JobName
        $expectedTaskName = "VLABS_Backup_$($job.JobName)"
        if (-not $job.TaskName) {
            $jobs[$i] | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue $expectedTaskName -Force
            $modified = $true
            $result.JobsMigrated++
        }
        elseif ($job.TaskName -ne $expectedTaskName) {
            # TaskName doesn't match JobName - this is corruption, fix it
            $oldTaskName = $job.TaskName
            $jobs[$i] | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue $expectedTaskName -Force
            $modified = $true
            $result.JobsMigrated++
            # Note: The old task will be reported as orphaned and can be manually removed
        }
        
        # Ensure Enabled field exists
        if ($null -eq $job.Enabled) {
            $jobs[$i] | Add-Member -NotePropertyName 'Enabled' -NotePropertyValue $true -Force
            $modified = $true
        }
        
        # Ensure AppName exists (for legacy jobs)
        if (-not $job.AppName -and $job.JobName) {
            $jobs[$i] | Add-Member -NotePropertyName 'AppName' -NotePropertyValue $job.JobName -Force
            $modified = $true
            $result.JobsMigrated++
        }
        
        # Never allow this node to remain in its own peer destination list.
        if ($job.PeerDestinations -and $config -and $config.TailscaleIP) {
            $existingPeers = @($job.PeerDestinations)
            $filteredPeers = @($existingPeers | Where-Object { $_.TailscaleIP -and $_.TailscaleIP -ne $config.TailscaleIP })
            if ($filteredPeers.Count -ne $existingPeers.Count) {
                $jobs[$i] | Add-Member -NotePropertyName 'PeerDestinations' -NotePropertyValue $filteredPeers -Force
                $job = $jobs[$i]
                $modified = $true
                $result.JobsRepaired++
                Write-RRDebug "Removed local peer from destinations for job '$($job.JobName)'"
            }
        }
        
        # Check: Jobs without valid destination configuration
        # NOTE: We do NOT attempt network-based auto-fix here (startup must be fast).
        #       Network discovery happens only when the user explicitly runs 'D'.
        $hasValidDestination = ($job.PeerDestinations -and $job.PeerDestinations.Count -gt 0) -or
                               ($job.DestinationPath -and $job.DestinationPath -ne '')

        if (-not $hasValidDestination) {
            $result.Issues += "Job '$($job.JobName)' has no destinations (run 'D' to discover peers)"
            Write-RRDebug "Job '$($job.JobName)' has no valid destination"
        }
        
        # Note: LastRun, LastStatus, LastDurationSeconds, LastSizeBytes are now stored
        # in jobs-status.json (transaction data), not in jobs.json (master data)
        
        # Check scheduled task exists
        # Ensure TaskName is a proper string (could be array if corrupted)
        $rawTaskName = $jobs[$i].TaskName
        if ($rawTaskName -is [Array]) {
            # Corrupted: take first element
            $taskName = [string]$rawTaskName[0]
            $jobs[$i] | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue $taskName -Force
            $modified = $true
            $result.JobsMigrated++
        }
        else {
            $taskName = [string]$rawTaskName
        }
        
        if ([string]::IsNullOrWhiteSpace($taskName) -or $taskName -eq "VLABS_Backup_") {
            $taskName = "VLABS_Backup_$([string]$job.JobName)"
            $jobs[$i] | Add-Member -NotePropertyName 'TaskName' -NotePropertyValue $taskName -Force
            $modified = $true
        }
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        
        if (-not $task) {
            # Task missing - try to recreate if we have enough info
            if ($job.Frequency -and $null -ne $job.StartHour) {
                try {
                    if (Get-Command 'New-ScheduledBackupTask' -ErrorAction SilentlyContinue) {
                        $createResult = New-ScheduledBackupTask -Job $jobs[$i]
                        if ($createResult) {
                            $result.TasksCreated++
                        }
                        else {
                            $result.Issues += "Could not create task for job: $($job.JobName)"
                        }
                    }
                }
                catch {
                    $result.Issues += "Error creating task for $($job.JobName): $_"
                }
            }
            else {
                $result.Issues += "Missing task for job '$($job.JobName)' (insufficient schedule info)"
            }
        }
        else {
            # Task exists - check if enabled state matches
            $taskEnabled = ($task.State -ne 'Disabled')
            $jobEnabled = ($job.Enabled -ne $false)
            
            if ($taskEnabled -ne $jobEnabled) {
                try {
                    # Ensure taskName is a clean string for the cmdlet
                    $cleanTaskName = $taskName.Trim()
                    if ($jobEnabled) {
                        Enable-ScheduledTask -TaskName $cleanTaskName -ErrorAction Stop | Out-Null
                    }
                    else {
                        Disable-ScheduledTask -TaskName $cleanTaskName -ErrorAction Stop | Out-Null
                    }
                    $result.TasksFixed++
                }
                catch {
                    $jobNameStr = if ($job.JobName -is [Array]) { $job.JobName[0] } else { $job.JobName }
                    $result.Issues += "Could not sync task state for $jobNameStr : $_"
                }
            }
        }
    }
    
    # Save if modified - strip transaction data before saving master data
    if ($modified) {
        try {
            Write-RRDebug "Invoke-JobsValidation: Saving $($jobs.Count) jobs (modified=$modified)"
            
            # Master data properties only (strip transaction data)
            $masterDataProperties = @('JobName', 'AppName', 'BackupType', 'BackupObject', 'SourceLocation',
                                       'TargetPeers', 'PeerDestinations', 'Schedule', 'Frequency', 'StartHour', 
                                       'Retention', 'RetentionMonthly', 'RetentionWeekly', 'RetentionRecent', 
                                       'TaskName', 'Enabled', 'Destination', 'DestinationPath', 'DestinationDomain',
                                       'DestinationUsername', 'DestinationEncryptedPassword', 'CreatedDate')
            
            $cleanJobs = @()
            foreach ($job in $jobs) {
                $cleanJob = @{}
                foreach ($prop in $masterDataProperties) {
                    if ($null -ne $job.$prop) {
                        $cleanJob[$prop] = $job.$prop
                    }
                }
                $cleanJobs += [PSCustomObject]$cleanJob
            }
            
            $json = ConvertTo-Json -InputObject $cleanJobs -Depth 10
            Set-Content -Path $jobsFile -Value $json -Force
            # Not an issue - just informational
            Write-RRDebug "Saved repaired jobs.json (master data only)"
        }
        catch {
            $result.Issues += "Could not save migrated jobs: $_"
        }
    }
    
    # Check for orphaned tasks (tasks without jobs)
    try {
        $vlabsTasks = Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | 
                      Where-Object { $_.TaskName -like 'VLABS_Backup_*' }
        
        foreach ($task in $vlabsTasks) {
            $jobExists = $jobs | Where-Object { $_.TaskName -eq $task.TaskName }
            if (-not $jobExists) {
                $result.Issues += "Orphaned task found: $($task.TaskName) (no matching job)"
            }
        }
    }
    catch { }
    
    return $result
}

#endregion

#region Node Status Publishing

function Format-RRSize {
    param([Nullable[long]]$Bytes)
    
    if ($null -eq $Bytes) { return "0 B" }
    
    $value = [double]$Bytes
    if ($value -ge 1TB) { return ("{0:N2} TB" -f ($value / 1TB)) }
    if ($value -ge 1GB) { return ("{0:N2} GB" -f ($value / 1GB)) }
    if ($value -ge 1MB) { return ("{0:N2} MB" -f ($value / 1MB)) }
    if ($value -ge 1KB) { return ("{0:N2} KB" -f ($value / 1KB)) }
    return ("{0} B" -f [int64]$Bytes)
}

function Get-NodeBackupRouting {
    <#
    .SYNOPSIS
        Builds a routing summary of local jobs and their configured peer destinations
    #>
    param([array]$Jobs)
    
    $routes = @()
    foreach ($job in @($Jobs)) {
        $destinations = @()
        
        foreach ($peer in @($job.PeerDestinations)) {
            if (-not $peer) { continue }
            $destinations += [PSCustomObject]@{
                Hostname = $peer.Hostname
                TailscaleIP = $peer.TailscaleIP
                Location = $peer.Location
                BasePath = $peer.BasePath
            }
        }
        
        if ($destinations.Count -eq 0 -and $job.DestinationPath) {
            $destinations += [PSCustomObject]@{
                Hostname = $job.Destination
                TailscaleIP = $null
                Location = $null
                BasePath = $job.DestinationPath
            }
        }
        
        $routes += [PSCustomObject]@{
            JobName = $job.JobName
            AppName = if ($job.AppName) { $job.AppName } else { $job.JobName }
            SourceLocation = $job.SourceLocation
            BackupType = $job.BackupType
            Enabled = ($job.Enabled -ne $false)
            DestinationCount = $destinations.Count
            Destinations = $destinations
        }
    }
    
    return @($routes)
}

function Get-NodeStorageInventory {
    <#
    .SYNOPSIS
        Scans the local storage root and returns a backup inventory summary
    #>
    param([string]$StoragePath)
    
    $inventory = @{
        GeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        TotalBackupSets = 0
        TotalFiles = 0
        TotalBytes = [int64]0
        BackupSets = @()
    }
    
    if (-not $StoragePath -or -not (Test-Path $StoragePath)) {
        return [PSCustomObject]$inventory
    }
    
    $backupSets = @()
    $customerDirs = @(Get-ChildItem $StoragePath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '_nodeinfo' })
    foreach ($customerDir in $customerDirs) {
        foreach ($locationDir in @(Get-ChildItem $customerDir.FullName -Directory -ErrorAction SilentlyContinue)) {
            foreach ($applicationDir in @(Get-ChildItem $locationDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                foreach ($typeDir in @(Get-ChildItem $applicationDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                    foreach ($backupDir in @(Get-ChildItem $typeDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                        $stats = Get-RebalanceFolderStats -Path $backupDir.FullName
                        $lastWrite = $null
                        try {
                            $lastWriteCandidate = Get-ChildItem $backupDir.FullName -Recurse -File -ErrorAction SilentlyContinue |
                                Sort-Object LastWriteTime -Descending |
                                Select-Object -First 1 -ExpandProperty LastWriteTime
                            if ($lastWriteCandidate) {
                                $lastWrite = (Get-Date $lastWriteCandidate).ToString("yyyy-MM-dd HH:mm:ss")
                            }
                        }
                        catch { }
                        
                        $relativePath = $backupDir.FullName.Substring($StoragePath.Length).TrimStart('\')
                        $backupSets += [PSCustomObject]@{
                            RelativePath = $relativePath
                            CustomerCode = $customerDir.Name
                            SourceLocation = $locationDir.Name
                            Application = $applicationDir.Name
                            BackupType = $typeDir.Name
                            BackupFolder = $backupDir.Name
                            FileCount = $stats.FileCount
                            SizeBytes = [int64]$stats.TotalBytes
                            SizeDisplay = (Format-RRSize -Bytes $stats.TotalBytes)
                            LastWriteTime = $lastWrite
                        }
                    }
                }
            }
        }
    }
    
    $inventory.TotalBackupSets = @($backupSets).Count
    if ($inventory.TotalBackupSets -gt 0) {
        $totalFiles = ((@($backupSets) | Measure-Object -Property FileCount -Sum).Sum)
        $totalBytes = ((@($backupSets) | Measure-Object -Property SizeBytes -Sum).Sum)
        $inventory.TotalFiles = if ($null -ne $totalFiles) { [int]$totalFiles } else { 0 }
        $inventory.TotalBytes = if ($null -ne $totalBytes) { [int64]$totalBytes } else { [int64]0 }
        $inventory.BackupSets = @($backupSets | Sort-Object @{ Expression = 'LastWriteTime'; Descending = $true }, @{ Expression = 'SizeBytes'; Descending = $true })
    }
    else {
        $inventory.TotalFiles = 0
        $inventory.TotalBytes = [int64]0
        $inventory.BackupSets = @()
    }
    
    return [PSCustomObject]$inventory
}

function Get-NodeStorageInventoryGroups {
    <#
    .SYNOPSIS
        Returns grouped inventory rows for TUI display
    #>
    param([string]$StoragePath)
    
    $inventory = Get-NodeStorageInventory -StoragePath $StoragePath
    $groups = @()
    
    foreach ($group in @($inventory.BackupSets | Group-Object SourceLocation, Application, BackupType)) {
        $items = @($group.Group)
        $latest = $items | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $groups += [PSCustomObject]@{
            SourceLocation = $items[0].SourceLocation
            Application = $items[0].Application
            BackupType = $items[0].BackupType
            BackupSetCount = $items.Count
            TotalFiles = (@($items) | Measure-Object -Property FileCount -Sum).Sum
            TotalBytes = [int64]((@($items) | Measure-Object -Property SizeBytes -Sum).Sum)
            TotalSizeDisplay = (Format-RRSize -Bytes ((@($items) | Measure-Object -Property SizeBytes -Sum).Sum))
            LatestBackupFolder = $latest.BackupFolder
            LatestWriteTime = $latest.LastWriteTime
        }
    }
    
    return @($groups | Sort-Object @{ Expression = 'LatestWriteTime'; Descending = $true }, @{ Expression = 'TotalBytes'; Descending = $true })
}

function Publish-NodeStatus {
    <#
    .SYNOPSIS
        Publishes this node's job status to the local RR_Backups share for RRM to read
    .DESCRIPTION
        Creates/updates _nodeinfo/jobs-status.json on the local storage path.
        Called on TUI startup and after each backup run.
    #>
    try {
        $config = Get-RingConfig
        if (-not $config -or -not $config.CustomerCode) { return $false }
        
        # Get local storage path
        $storagePath = $config.StoragePath
        if (-not $storagePath -or -not (Test-Path $storagePath)) { return $false }
        
        # Create _nodeinfo folder
        $nodeInfoPath = Join-Path $storagePath "_nodeinfo"
        if (-not (Test-Path $nodeInfoPath)) {
            New-Item -Path $nodeInfoPath -ItemType Directory -Force | Out-Null
        }
        
        # Get all jobs (master data + transaction data merged)
        $dataPath = Get-RRDataPath
        $jobsFile = Join-Path $dataPath "jobs.json"
        $statusFile = Join-Path $dataPath "jobs-status.json"
        
        $jobs = @()
        $statusTable = @{}
        
        # Load master data
        if (Test-Path $jobsFile) {
            try {
                $jobsContent = Get-Content $jobsFile -Raw | ConvertFrom-Json
                # Handle corrupted format
                if ($jobsContent -is [PSCustomObject] -and $jobsContent.PSObject.Properties.Name -contains 'value') {
                    $jobsContent = $jobsContent.value
                }
                if ($jobsContent) { $jobs = @($jobsContent) }
            }
            catch { }
        }
        
        # Load transaction data
        if (Test-Path $statusFile) {
            try {
                $statusContent = Get-Content $statusFile -Raw | ConvertFrom-Json
                if ($statusContent -is [PSCustomObject] -and $statusContent.PSObject.Properties.Name -contains 'value') {
                    $statusContent = $statusContent.value
                }
                foreach ($s in @($statusContent)) {
                    if ($s.JobName) { $statusTable[$s.JobName] = $s }
                }
            }
            catch { }
        }
        
        # Merge status into jobs
        foreach ($job in $jobs) {
            $status = $statusTable[$job.JobName]
            if ($status) {
                $job | Add-Member -NotePropertyName 'LastRun' -NotePropertyValue $status.LastRun -Force
                $job | Add-Member -NotePropertyName 'LastStatus' -NotePropertyValue $status.LastStatus -Force
                $job | Add-Member -NotePropertyName 'LastDurationSeconds' -NotePropertyValue $status.LastDurationSeconds -Force
                $job | Add-Member -NotePropertyName 'LastSizeBytes' -NotePropertyValue $status.LastSizeBytes -Force
            }
        }
        
        # Get Tailscale hostname
        $tsHostname = ""
        try {
            $tsStatus = tailscale status --json 2>$null | ConvertFrom-Json
            $tsHostname = $tsStatus.Self.DNSName -replace '\..*$', ''
        }
        catch { $tsHostname = $env:COMPUTERNAME }
        
        # Build status object
        $cDriveFreeGB = $null
        $storageDriveFreeGB = $null
        
        try {
            $cDrive = Get-PSDrive -Name 'C' -ErrorAction SilentlyContinue
            if ($cDrive) {
                $cDriveFreeGB = [math]::Round($cDrive.Free / 1GB, 2)
            }
        }
        catch { }
        
        try {
            $storageDriveLetter = (Split-Path $storagePath -Qualifier).TrimEnd(':')
            $storageDrive = Get-PSDrive -Name $storageDriveLetter -ErrorAction SilentlyContinue
            if ($storageDrive) {
                $storageDriveFreeGB = [math]::Round($storageDrive.Free / 1GB, 2)
            }
        }
        catch { }
        
        $routing = Get-NodeBackupRouting -Jobs $jobs
        $inventory = Get-NodeStorageInventory -StoragePath $storagePath
        
        $nodeStatus = @{
            NodeHostname = $tsHostname
            CustomerCode = $config.CustomerCode
            Location = $config.Location
            LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            CDriveFreeGB = $cDriveFreeGB
            StorageDriveFreeGB = $storageDriveFreeGB
            RoutingJobCount = @($routing).Count
            InventoryBackupSetCount = $inventory.TotalBackupSets
            InventoryTotalBytes = $inventory.TotalBytes
            Jobs = @()
        }
        
        foreach ($job in $jobs) {
            $nodeStatus.Jobs += @{
                JobName = $job.JobName
                AppName = $job.AppName
                BackupType = $job.BackupType
                BackupObject = $job.BackupObject
                SourceLocation = $job.SourceLocation
                Enabled = $job.Enabled
                LastRun = $job.LastRun
                LastStatus = $job.LastStatus
                LastDurationSeconds = $job.LastDurationSeconds
                LastSizeBytes = $job.LastSizeBytes
                Frequency = $job.Frequency
                RetentionMonthly = $job.RetentionMonthly
                RetentionWeekly = $job.RetentionWeekly
                RetentionRecent = $job.RetentionRecent
            }
        }
        
        # Save to share
        $statusFile = Join-Path $nodeInfoPath "jobs-status.json"
        $nodeStatus | ConvertTo-Json -Depth 10 | Set-Content $statusFile -Force
        
        $routingFile = Join-Path $nodeInfoPath "backup-routing.json"
        @{
            NodeHostname = $tsHostname
            CustomerCode = $config.CustomerCode
            Location = $config.Location
            LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Jobs = $routing
        } | ConvertTo-Json -Depth 10 | Set-Content $routingFile -Force
        
        $inventoryFile = Join-Path $nodeInfoPath "storage-inventory.json"
        @{
            NodeHostname = $tsHostname
            CustomerCode = $config.CustomerCode
            Location = $config.Location
            LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            TotalBackupSets = $inventory.TotalBackupSets
            TotalFiles = $inventory.TotalFiles
            TotalBytes = $inventory.TotalBytes
            BackupSets = $inventory.BackupSets
        } | ConvertTo-Json -Depth 10 | Set-Content $inventoryFile -Force
        
        return $true
    }
    catch {
        return $false
    }
}

#endregion

# Functions are available when dot-sourced
