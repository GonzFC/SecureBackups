<#
.SYNOPSIS
    VLABS Secure Backup Tool - Backup Execution Script
.DESCRIPTION
    Executes backup jobs created by VLABS-SecureBackup.ps1
    Called by Windows Scheduled Tasks
.PARAMETER JobName
    Name of the backup job to execute
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$JobName
)

# Configuration
# Data in ProgramData (separate from git install directory)
$script:ConfigPath = "C:\ProgramData\VLABS_ResilienceRing"
$script:JobsFile = Join-Path $ConfigPath "jobs.json"
$script:LogPath = Join-Path $ConfigPath "Logs"

# Load crypto utilities for machine-independent password decryption
$cryptoUtilsPath = Join-Path $PSScriptRoot "CryptoUtils.ps1"
if (Test-Path $cryptoUtilsPath) {
    . $cryptoUtilsPath
}

# VLABS Monitor Configuration (for future integration)
$script:VlabsMonitorUrl = $env:VLABS_MONITOR_URL  # e.g., "http://100.x.x.x:8080/api"
$script:VlabsMonitorEnabled = $false  # Will be enabled when VLABS Monitor is deployed

#region Checksum Functions

function Get-FileChecksum {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )

    try {
        if (-not (Test-Path $FilePath -PathType Leaf)) {
            Write-Log "Cannot calculate checksum - file not found: $FilePath" -Level WARNING
            return $null
        }

        $hash = Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction Stop
        return $hash.Hash
    }
    catch {
        Write-Log "Error calculating checksum for $FilePath : $_" -Level ERROR
        return $null
    }
}

function Get-DirectoryChecksum {
    param(
        [Parameter(Mandatory=$true)]
        [string]$DirectoryPath,

        [int]$MaxFiles = 100  # Limit for performance
    )

    try {
        if (-not (Test-Path $DirectoryPath -PathType Container)) {
            Write-Log "Cannot calculate checksum - directory not found: $DirectoryPath" -Level WARNING
            return $null
        }

        $checksums = @{}
        $files = Get-ChildItem -Path $DirectoryPath -File -Recurse -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending |
                 Select-Object -First $MaxFiles

        foreach ($file in $files) {
            $relativePath = $file.FullName.Substring($DirectoryPath.Length).TrimStart('\')
            $hash = Get-FileHash -Path $file.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue
            if ($hash) {
                $checksums[$relativePath] = $hash.Hash
            }
        }

        return $checksums
    }
    catch {
        Write-Log "Error calculating directory checksums: $_" -Level ERROR
        return $null
    }
}

function Test-ChecksumMatch {
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourcePath,

        [Parameter(Mandatory=$true)]
        [string]$DestinationPath,

        [ValidateSet('File','Directory')]
        [string]$Type = 'File'
    )

    try {
        Write-Log "Verifying checksum integrity..." -Level INFO

        if ($Type -eq 'File') {
            $sourceHash = Get-FileChecksum -FilePath $SourcePath
            $destHash = Get-FileChecksum -FilePath $DestinationPath

            if ($null -eq $sourceHash -or $null -eq $destHash) {
                Write-Log "Could not calculate checksums for verification" -Level WARNING
                return @{ Success = $false; Reason = "Checksum calculation failed" }
            }

            if ($sourceHash -eq $destHash) {
                Write-Log "Checksum verification PASSED: $sourceHash" -Level SUCCESS
                return @{ Success = $true; SourceHash = $sourceHash; DestHash = $destHash }
            }
            else {
                Write-Log "Checksum MISMATCH! Source: $sourceHash, Dest: $destHash" -Level ERROR
                return @{ Success = $false; Reason = "Hash mismatch"; SourceHash = $sourceHash; DestHash = $destHash }
            }
        }
        else {
            # Directory comparison - sample verification
            $sourceChecksums = Get-DirectoryChecksum -DirectoryPath $SourcePath
            $destChecksums = Get-DirectoryChecksum -DirectoryPath $DestinationPath

            if ($null -eq $sourceChecksums -or $null -eq $destChecksums) {
                Write-Log "Could not calculate directory checksums" -Level WARNING
                return @{ Success = $false; Reason = "Directory checksum calculation failed" }
            }

            $mismatches = @()
            foreach ($file in $sourceChecksums.Keys) {
                if ($destChecksums.ContainsKey($file)) {
                    if ($sourceChecksums[$file] -ne $destChecksums[$file]) {
                        $mismatches += $file
                    }
                }
            }

            if ($mismatches.Count -eq 0) {
                Write-Log "Directory checksum verification PASSED ($($sourceChecksums.Count) files verified)" -Level SUCCESS
                return @{ Success = $true; FilesVerified = $sourceChecksums.Count }
            }
            else {
                Write-Log "Directory checksum MISMATCH! $($mismatches.Count) files differ" -Level ERROR
                return @{ Success = $false; Reason = "Files with mismatches: $($mismatches -join ', ')"; MismatchCount = $mismatches.Count }
            }
        }
    }
    catch {
        Write-Log "Error during checksum verification: $_" -Level ERROR
        return @{ Success = $false; Reason = $_.ToString() }
    }
}

#endregion

#region VLABS Monitor Reporting (Prepared for future integration)

function Send-BackupReport {
    param(
        [Parameter(Mandatory=$true)]
        [string]$JobName,

        [Parameter(Mandatory=$true)]
        [ValidateSet('Success','Failed','ChecksumMismatch')]
        [string]$Status,

        [hashtable]$ChecksumResult = $null,

        [string]$ErrorMessage = $null,

        [long]$BytesTransferred = 0,

        [int]$DurationSeconds = 0
    )

    # Skip if VLABS Monitor is not configured
    if (-not $script:VlabsMonitorEnabled -or [string]::IsNullOrEmpty($script:VlabsMonitorUrl)) {
        Write-Log "VLABS Monitor reporting skipped (not configured)" -Level INFO
        return $true
    }

    try {
        $report = @{
            timestamp = (Get-Date).ToString("o")
            hostname = $env:COMPUTERNAME
            jobName = $JobName
            status = $Status
            bytesTransferred = $BytesTransferred
            durationSeconds = $DurationSeconds
            checksumVerified = ($null -ne $ChecksumResult -and $ChecksumResult.Success)
            errorMessage = $ErrorMessage
        }

        $json = $report | ConvertTo-Json -Compress
        $endpoint = "$script:VlabsMonitorUrl/backup/result"

        Write-Log "Sending backup report to VLABS Monitor..." -Level INFO

        $response = Invoke-RestMethod -Uri $endpoint -Method Post -Body $json -ContentType "application/json" -TimeoutSec 10 -ErrorAction Stop

        Write-Log "Backup report sent successfully" -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "Failed to send report to VLABS Monitor: $_" -Level WARNING
        # Don't fail the backup if reporting fails
        return $false
    }
}

function Send-Heartbeat {
    param(
        [string]$JobName = $null
    )

    if (-not $script:VlabsMonitorEnabled -or [string]::IsNullOrEmpty($script:VlabsMonitorUrl)) {
        return $true
    }

    try {
        $heartbeat = @{
            timestamp = (Get-Date).ToString("o")
            hostname = $env:COMPUTERNAME
            jobName = $JobName
            status = "alive"
        }

        $json = $heartbeat | ConvertTo-Json -Compress
        $endpoint = "$script:VlabsMonitorUrl/heartbeat"

        Invoke-RestMethod -Uri $endpoint -Method Post -Body $json -ContentType "application/json" -TimeoutSec 5 -ErrorAction Stop

        return $true
    }
    catch {
        Write-Log "Failed to send heartbeat: $_" -Level WARNING
        return $false
    }
}

#endregion

#region Logging Functions

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [ValidateSet('INFO','WARNING','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )

    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logFile = Join-Path $LogPath "VLABS_Backup_$(Get-Date -Format 'yyyyMMdd').log"
        $logEntry = "[$timestamp] [$Level] $Message"

        Add-Content -Path $logFile -Value $logEntry -ErrorAction Stop

        # Also write to console for debugging
        switch ($Level) {
            'ERROR' { Write-Host $logEntry -ForegroundColor Red }
            'WARNING' { Write-Host $logEntry -ForegroundColor Yellow }
            'SUCCESS' { Write-Host $logEntry -ForegroundColor Green }
            default { Write-Host $logEntry -ForegroundColor Gray }
        }
    }
    catch {
        Write-Host "Warning: Could not write to log file: $_" -ForegroundColor Yellow
    }
}

#endregion

#region Configuration Functions

function Get-Jobs {
    try {
        if (-not (Test-Path $JobsFile)) {
            Write-Log "Jobs file not found: $JobsFile" -Level ERROR
            return $null
        }

        $content = Get-Content $JobsFile -Raw -ErrorAction Stop
        $result = $content | ConvertFrom-Json

        # Force result to be an array (PowerShell returns single objects as non-arrays)
        if ($result -eq $null) {
            return @()
        }

        # Use @() to ensure we always have an array, even with one item
        return @($result)
    }
    catch {
        Write-Log "Error reading jobs: $_" -Level ERROR
        return $null
    }
}

function Save-Jobs {
    param([Parameter(Mandatory=$true)] $Jobs)

    try {
        # Ensure we always have an array, even if empty
        $jobsArray = @($Jobs)

        # ConvertTo-Json with explicit array handling
        if ($jobsArray.Count -eq 0) {
            # Explicitly save empty array as "[]"
            "[]" | Set-Content $JobsFile -ErrorAction Stop
        }
        else {
            $jobsArray | ConvertTo-Json -Depth 10 | Set-Content $JobsFile -ErrorAction Stop
        }
        return $true
    }
    catch {
        Write-Log "Error saving jobs: $_" -Level ERROR
        return $false
    }
}

function Update-JobStatus {
    param(
        [Parameter(Mandatory=$true)]
        [string]$JobName,

        [Parameter(Mandatory=$true)]
        [ValidateSet('Success','Failed','Running')]
        [string]$Status
    )

    try {
        $jobs = Get-Jobs
        if (-not $jobs) { return $false }

        $jobIndex = -1
        for ($i = 0; $i -lt $jobs.Count; $i++) {
            if ($jobs[$i].JobName -eq $JobName) {
                $jobIndex = $i
                break
            }
        }

        if ($jobIndex -ge 0) {
            $jobs[$jobIndex].LastRun = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $jobs[$jobIndex].LastStatus = $Status

            return (Save-Jobs -Jobs $jobs)
        }

        return $false
    }
    catch {
        Write-Log "Error updating job status: $_" -Level ERROR
        return $false
    }
}

#endregion

#region Credential Management Functions

function ConvertFrom-EncryptedPassword {
    param(
        [Parameter(Mandatory=$true)]
        [string]$EncryptedPassword
    )

    try {
        $securePassword = ConvertTo-SecureString -String $EncryptedPassword
        return $securePassword
    }
    catch {
        Write-Log "Error decrypting password: $_" -Level ERROR
        return $null
    }
}

function Get-PlainTextPassword {
    param(
        [Parameter(Mandatory=$true)]
        [System.Security.SecureString]$SecurePassword
    )

    try {
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        return $plainPassword
    }
    catch {
        Write-Log "Error converting secure password: $_" -Level ERROR
        return $null
    }
}

function Split-UncPath {
    param(
        [Parameter(Mandatory=$true)]
        [string]$UncPath
    )

    try {
        if ($UncPath -notmatch '^\\\\([^\\]+)\\([^\\]+)(.*)$') {
            Write-Log "Invalid UNC path format: $UncPath" -Level ERROR
            return $null
        }

        $server = $matches[1]
        $share = $matches[2]
        $subPath = $matches[3].TrimStart('\')

        return @{
            Server = $server
            Share = $share
            SubPath = $subPath
            SharePath = "\\$server\$share"
            FullPath = $UncPath
        }
    }
    catch {
        Write-Log "Error parsing UNC path: $_" -Level ERROR
        return $null
    }
}

function Connect-SmbShare {
    param(
        [Parameter(Mandatory=$true)]
        $Job
    )

    try {
        $pathInfo = Split-UncPath -UncPath $Job.DestinationPath
        if (-not $pathInfo) {
            Write-Log "Failed to parse destination path" -Level ERROR
            return $false
        }

        # Check if already connected
        $existingConnection = net use | Select-String -Pattern "\\\\$($pathInfo.Server)\\$($pathInfo.Share)"
        if ($existingConnection) {
            Write-Log "Share already connected: $($pathInfo.SharePath)" -Level INFO
            return $true
        }

        # Decrypt password using hybrid method (AES first, then DPAPI fallback)
        $plainPassword = $null
        
        # Try new AES method first (if CryptoUtils is loaded)
        if (Get-Command 'Unprotect-Password' -ErrorAction SilentlyContinue) {
            $plainPassword = Unprotect-Password -EncryptedPassword $Job.DestinationEncryptedPassword
        }
        
        # Fallback to legacy DPAPI if AES failed or CryptoUtils not available
        if (-not $plainPassword) {
            try {
                $securePassword = ConvertTo-SecureString -String $Job.DestinationEncryptedPassword -ErrorAction Stop
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
                $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
            }
            catch {
                Write-Log "Failed to decrypt password (neither AES nor DPAPI worked)" -Level ERROR
                return $false
            }
        }
        
        if (-not $plainPassword) {
            Write-Log "Failed to decrypt password" -Level ERROR
            return $false
        }

        # Build credentials string
        $userString = if ($Job.DestinationDomain) {
            "$($Job.DestinationDomain)\$($Job.DestinationUsername)"
        } else {
            $Job.DestinationUsername
        }

        # Connect using net use
        Write-Log "Connecting to $($pathInfo.SharePath) as $userString..." -Level INFO

        $netUseCmd = "net use `"$($pathInfo.SharePath)`" /user:`"$userString`" `"$plainPassword`" 2>&1"
        $result = cmd.exe /c $netUseCmd

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Successfully connected to share: $($pathInfo.SharePath)" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "Failed to connect to share: $result" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "Error connecting to SMB share: $_" -Level ERROR
        return $false
    }
}

function Disconnect-SmbShare {
    param(
        [Parameter(Mandatory=$true)]
        $Job
    )

    try {
        $pathInfo = Split-UncPath -UncPath $Job.DestinationPath
        if (-not $pathInfo) {
            Write-Log "Failed to parse destination path for disconnect" -Level WARNING
            return $false
        }

        # Check if connected
        $existingConnection = net use | Select-String -Pattern "\\\\$($pathInfo.Server)\\$($pathInfo.Share)"
        if (-not $existingConnection) {
            Write-Log "Share not connected: $($pathInfo.SharePath)" -Level INFO
            return $true
        }

        # Disconnect using net use
        Write-Log "Disconnecting from $($pathInfo.SharePath)..." -Level INFO

        $result = net use $pathInfo.SharePath /delete 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Successfully disconnected from share: $($pathInfo.SharePath)" -Level SUCCESS
            return $true
        }
        else {
            Write-Log "Failed to disconnect from share: $result" -Level WARNING
            return $false
        }
    }
    catch {
        Write-Log "Error disconnecting from SMB share: $_" -Level WARNING
        return $false
    }
}

#endregion

#region Tailscale Management Functions

function Connect-Tailscale {
    try {
        Write-Log "Checking Tailscale status..." -Level INFO

        # Check if Tailscale is installed
        $tailscalePath = "tailscale"
        $testCmd = Get-Command tailscale -ErrorAction SilentlyContinue
        if (-not $testCmd) {
            Write-Log "Tailscale CLI not found in PATH, checking common locations..." -Level WARNING

            # Check common installation paths
            $commonPaths = @(
                "$env:ProgramFiles\Tailscale\tailscale.exe",
                "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe",
                "$env:LocalAppData\Tailscale\tailscale.exe"
            )

            foreach ($path in $commonPaths) {
                if (Test-Path $path) {
                    $tailscalePath = $path
                    Write-Log "Found Tailscale at: $tailscalePath" -Level INFO
                    break
                }
            }

            if ($tailscalePath -eq "tailscale") {
                Write-Log "Tailscale not found. Please ensure Tailscale is installed." -Level ERROR
                return $false
            }
        }

        # Check if already connected
        $statusResult = & $tailscalePath status 2>&1
        if ($LASTEXITCODE -eq 0 -and $statusResult -notmatch "Logged out") {
            Write-Log "Tailscale is already connected" -Level INFO
            return $true
        }

        # Bring up Tailscale connection
        Write-Log "Bringing up Tailscale connection..." -Level INFO
        $upResult = & $tailscalePath up 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Tailscale connection established successfully" -Level SUCCESS

            # Wait a moment for connection to stabilize
            Start-Sleep -Seconds 2
            return $true
        }
        else {
            Write-Log "Failed to bring up Tailscale: $upResult" -Level ERROR
            return $false
        }
    }
    catch {
        Write-Log "Error managing Tailscale connection: $_" -Level ERROR
        return $false
    }
}

function Disconnect-Tailscale {
    try {
        Write-Log "Bringing down Tailscale connection..." -Level INFO

        # Find tailscale executable
        $tailscalePath = "tailscale"
        $testCmd = Get-Command tailscale -ErrorAction SilentlyContinue
        if (-not $testCmd) {
            $commonPaths = @(
                "$env:ProgramFiles\Tailscale\tailscale.exe",
                "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe",
                "$env:LocalAppData\Tailscale\tailscale.exe"
            )

            foreach ($path in $commonPaths) {
                if (Test-Path $path) {
                    $tailscalePath = $path
                    break
                }
            }
        }

        # Bring down Tailscale
        $downResult = & $tailscalePath down 2>&1

        if ($LASTEXITCODE -eq 0) {
            Write-Log "Tailscale connection brought down successfully" -Level SUCCESS
            return $true
        }
        else {
            # Don't treat this as a critical error - log warning and continue
            Write-Log "Tailscale down command returned: $downResult" -Level WARNING
            return $true
        }
    }
    catch {
        Write-Log "Error disconnecting Tailscale: $_" -Level WARNING
        return $true  # Don't fail the backup if we can't disconnect
    }
}

#endregion

#region Backup Functions

function Invoke-FileBackup {
    param(
        [Parameter(Mandatory=$true)]
        $Job
    )

    try {
        Write-Log "Starting file backup for job: $($Job.JobName)" -Level INFO

        # Verify source file exists
        if (-not (Test-Path $Job.BackupObject -PathType Leaf)) {
            Write-Log "Source file not found: $($Job.BackupObject)" -Level ERROR
            return $false
        }

        # Get file info
        $sourceFile = Get-Item $Job.BackupObject
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $fileName = $sourceFile.BaseName + "_" + $timestamp + $sourceFile.Extension

        # Bring up Tailscale connection
        if (-not (Connect-Tailscale)) {
            Write-Log "Failed to establish Tailscale connection" -Level ERROR
            return $false
        }

        # Connect to SMB share
        if (-not (Connect-SmbShare -Job $Job)) {
            Write-Log "Failed to connect to destination share" -Level ERROR
            Disconnect-Tailscale | Out-Null
            return $false
        }

        # Verify destination is accessible
        if (-not (Test-Path $Job.DestinationPath)) {
            Write-Log "Destination path not accessible: $($Job.DestinationPath)" -Level ERROR
            Disconnect-SmbShare -Job $Job | Out-Null
            Disconnect-Tailscale | Out-Null
            return $false
        }

        # Create job-specific subfolder in destination
        $destinationFolder = Join-Path $Job.DestinationPath $Job.JobName
        if (-not (Test-Path $destinationFolder)) {
            New-Item -Path $destinationFolder -ItemType Directory -Force | Out-Null
            Write-Log "Created destination folder: $destinationFolder" -Level INFO
        }

        $destinationFile = Join-Path $destinationFolder $fileName

        # Copy file using robocopy for reliability
        $sourceDir = $sourceFile.DirectoryName
        $robocopyLog = Join-Path $LogPath "robocopy_$($Job.JobName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

        Write-Log "Copying file: $($sourceFile.FullName) -> $destinationFile" -Level INFO

        # Robocopy parameters: /R:3 (3 retries) /W:5 (5 seconds wait) /NFL (no file list) /NDL (no directory list)
        $robocopyArgs = @(
            "`"$sourceDir`"",
            "`"$destinationFolder`"",
            "`"$($sourceFile.Name)`"",
            "/R:3",
            "/W:5",
            "/LOG:`"$robocopyLog`""
        )

        $robocopyCmd = "robocopy $($robocopyArgs -join ' ')"
        $result = Invoke-Expression $robocopyCmd

        # Robocopy exit codes: 0-7 are success (0=no files, 1=files copied, 2=extra files, etc.)
        if ($LASTEXITCODE -le 7) {
            # Rename the copied file to include timestamp
            $copiedFile = Join-Path $destinationFolder $sourceFile.Name
            $finalDestFile = Join-Path $destinationFolder $fileName
            if (Test-Path $copiedFile) {
                Rename-Item -Path $copiedFile -NewName $fileName -Force -ErrorAction Stop
            }

            Write-Log "File copy completed, verifying integrity..." -Level INFO

            # Checksum verification
            $checksumResult = Test-ChecksumMatch -SourcePath $sourceFile.FullName -DestinationPath $finalDestFile -Type 'File'

            if ($checksumResult.Success) {
                Write-Log "File backup completed successfully with verified integrity" -Level SUCCESS

                # Report success to VLABS Monitor
                Send-BackupReport -JobName $Job.JobName -Status 'Success' -ChecksumResult $checksumResult

                # Apply retention policy
                Invoke-RetentionPolicy -DestinationFolder $destinationFolder -Retention $Job.Retention

                # Disconnect from SMB share
                Disconnect-SmbShare -Job $Job | Out-Null

                # Bring down Tailscale connection
                Disconnect-Tailscale | Out-Null

                return $true
            }
            else {
                Write-Log "CHECKSUM MISMATCH - Backup integrity verification FAILED!" -Level ERROR

                # Report checksum failure to VLABS Monitor
                Send-BackupReport -JobName $Job.JobName -Status 'ChecksumMismatch' -ChecksumResult $checksumResult -ErrorMessage $checksumResult.Reason

                # Still disconnect cleanly
                Disconnect-SmbShare -Job $Job | Out-Null
                Disconnect-Tailscale | Out-Null

                return $false
            }
        }
        else {
            Write-Log "Robocopy failed with exit code: $LASTEXITCODE" -Level ERROR

            # Report failure to VLABS Monitor
            Send-BackupReport -JobName $Job.JobName -Status 'Failed' -ErrorMessage "Robocopy exit code: $LASTEXITCODE"

            Disconnect-SmbShare -Job $Job | Out-Null
            Disconnect-Tailscale | Out-Null
            return $false
        }
    }
    catch {
        Write-Log "Error during file backup: $_" -Level ERROR

        # Report failure to VLABS Monitor
        Send-BackupReport -JobName $Job.JobName -Status 'Failed' -ErrorMessage $_.ToString()

        Disconnect-SmbShare -Job $Job | Out-Null
        Disconnect-Tailscale | Out-Null
        return $false
    }
}

function Invoke-DirectoryBackup {
    param(
        [Parameter(Mandatory=$true)]
        $Job
    )

    try {
        Write-Log "Starting directory backup for job: $($Job.JobName)" -Level INFO

        # Verify source directory exists
        if (-not (Test-Path $Job.BackupObject -PathType Container)) {
            Write-Log "Source directory not found: $($Job.BackupObject)" -Level ERROR
            return $false
        }

        # Bring up Tailscale connection
        if (-not (Connect-Tailscale)) {
            Write-Log "Failed to establish Tailscale connection" -Level ERROR
            return $false
        }

        # Connect to SMB share
        if (-not (Connect-SmbShare -Job $Job)) {
            Write-Log "Failed to connect to destination share" -Level ERROR
            Disconnect-Tailscale | Out-Null
            return $false
        }

        # Verify destination is accessible
        if (-not (Test-Path $Job.DestinationPath)) {
            Write-Log "Destination path not accessible: $($Job.DestinationPath)" -Level ERROR
            Disconnect-SmbShare -Job $Job | Out-Null
            Disconnect-Tailscale | Out-Null
            return $false
        }

        # Create job-specific subfolder in destination (sync target)
        $destinationFolder = Join-Path $Job.DestinationPath $Job.JobName
        if (-not (Test-Path $destinationFolder)) {
            New-Item -Path $destinationFolder -ItemType Directory -Force | Out-Null
            Write-Log "Created destination folder: $destinationFolder" -Level INFO
        }

        $robocopyLog = Join-Path $LogPath "robocopy_$($Job.JobName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

        Write-Log "Synchronizing directory: $($Job.BackupObject) -> $destinationFolder" -Level INFO

        # Robocopy parameters for sync with change detection:
        # /MIR = Mirror (sync all, delete extras at destination)
        # /R:3 = 3 retries on failed copies
        # /W:5 = Wait 5 seconds between retries
        # /MT:8 = Multi-threaded (8 threads)
        # /DCOPY:DAT = Copy directory timestamps, attributes, data
        # /COPY:DAT = Copy file data, attributes, timestamps
        # /LOG = Log file
        $robocopyArgs = @(
            "`"$($Job.BackupObject)`"",
            "`"$destinationFolder`"",
            "/MIR",
            "/DCOPY:DAT",
            "/COPY:DAT",
            "/R:3",
            "/W:5",
            "/MT:8",
            "/LOG:`"$robocopyLog`""
        )

        $robocopyCmd = "robocopy $($robocopyArgs -join ' ')"
        $result = Invoke-Expression $robocopyCmd

        # Robocopy exit codes: 0-7 are success
        if ($LASTEXITCODE -le 7) {
            Write-Log "Directory sync completed, verifying integrity (sampling)..." -Level INFO

            # Checksum verification (samples recent files)
            $checksumResult = Test-ChecksumMatch -SourcePath $Job.BackupObject -DestinationPath $destinationFolder -Type 'Directory'

            if ($checksumResult.Success) {
                Write-Log "Directory synchronization completed with verified integrity ($($checksumResult.FilesVerified) files sampled)" -Level SUCCESS

                # Report success to VLABS Monitor
                Send-BackupReport -JobName $Job.JobName -Status 'Success' -ChecksumResult $checksumResult

                # Disconnect from SMB share
                Disconnect-SmbShare -Job $Job | Out-Null

                # Bring down Tailscale connection
                Disconnect-Tailscale | Out-Null

                return $true
            }
            else {
                Write-Log "CHECKSUM MISMATCH - Directory integrity verification FAILED!" -Level ERROR

                # Report checksum failure to VLABS Monitor
                Send-BackupReport -JobName $Job.JobName -Status 'ChecksumMismatch' -ChecksumResult $checksumResult -ErrorMessage $checksumResult.Reason

                Disconnect-SmbShare -Job $Job | Out-Null
                Disconnect-Tailscale | Out-Null
                return $false
            }
        }
        else {
            Write-Log "Robocopy failed with exit code: $LASTEXITCODE" -Level ERROR

            # Report failure to VLABS Monitor
            Send-BackupReport -JobName $Job.JobName -Status 'Failed' -ErrorMessage "Robocopy exit code: $LASTEXITCODE"

            Disconnect-SmbShare -Job $Job | Out-Null
            Disconnect-Tailscale | Out-Null
            return $false
        }
    }
    catch {
        Write-Log "Error during directory backup: $_" -Level ERROR

        # Report failure to VLABS Monitor
        Send-BackupReport -JobName $Job.JobName -Status 'Failed' -ErrorMessage $_.ToString()

        Disconnect-SmbShare -Job $Job | Out-Null
        Disconnect-Tailscale | Out-Null
        return $false
    }
}

function Invoke-SqlBackup {
    param(
        [Parameter(Mandatory=$true)]
        $Job
    )

    try {
        Write-Log "Starting SQL backup synchronization for job: $($Job.JobName)" -Level INFO

        # Verify source directory exists
        if (-not (Test-Path $Job.BackupObject -PathType Container)) {
            Write-Log "Source SQL backup directory not found: $($Job.BackupObject)" -Level ERROR
            return $false
        }

        # Bring up Tailscale connection
        if (-not (Connect-Tailscale)) {
            Write-Log "Failed to establish Tailscale connection" -Level ERROR
            return $false
        }

        # Connect to SMB share
        if (-not (Connect-SmbShare -Job $Job)) {
            Write-Log "Failed to connect to destination share" -Level ERROR
            Disconnect-Tailscale | Out-Null
            return $false
        }

        # Verify destination is accessible
        if (-not (Test-Path $Job.DestinationPath)) {
            Write-Log "Destination path not accessible: $($Job.DestinationPath)" -Level ERROR
            Disconnect-SmbShare -Job $Job | Out-Null
            Disconnect-Tailscale | Out-Null
            return $false
        }

        # Create job-specific subfolder in destination (sync target)
        $destinationFolder = Join-Path $Job.DestinationPath $Job.JobName
        if (-not (Test-Path $destinationFolder)) {
            New-Item -Path $destinationFolder -ItemType Directory -Force | Out-Null
            Write-Log "Created destination folder: $destinationFolder" -Level INFO
        }

        $robocopyLog = Join-Path $LogPath "robocopy_$($Job.JobName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

        Write-Log "Synchronizing SQL backup directory: $($Job.BackupObject) -> $destinationFolder" -Level INFO

        # Use robocopy to sync all files with change detection:
        # /MIR = Mirror (sync all, delete extras at destination)
        # /R:3 = 3 retries on failed copies
        # /W:5 = Wait 5 seconds between retries
        # /MT:8 = Multi-threaded (8 threads)
        # /DCOPY:DAT = Copy directory timestamps, attributes, data
        # /COPY:DAT = Copy file data, attributes, timestamps
        # /LOG = Log file
        $robocopyArgs = @(
            "`"$($Job.BackupObject)`"",
            "`"$destinationFolder`"",
            "/MIR",
            "/DCOPY:DAT",
            "/COPY:DAT",
            "/R:3",
            "/W:5",
            "/MT:8",
            "/LOG:`"$robocopyLog`""
        )

        $robocopyCmd = "robocopy $($robocopyArgs -join ' ')"
        $result = Invoke-Expression $robocopyCmd

        # Robocopy exit codes: 0-7 are success
        if ($LASTEXITCODE -le 7) {
            Write-Log "SQL backup sync completed, verifying integrity (sampling)..." -Level INFO

            # Checksum verification (samples recent files - SQL backups are critical)
            $checksumResult = Test-ChecksumMatch -SourcePath $Job.BackupObject -DestinationPath $destinationFolder -Type 'Directory'

            if ($checksumResult.Success) {
                Write-Log "SQL backup synchronization completed with verified integrity ($($checksumResult.FilesVerified) files sampled)" -Level SUCCESS

                # Report success to VLABS Monitor
                Send-BackupReport -JobName $Job.JobName -Status 'Success' -ChecksumResult $checksumResult

                Disconnect-SmbShare -Job $Job | Out-Null
                Disconnect-Tailscale | Out-Null
                return $true
            }
            else {
                Write-Log "CHECKSUM MISMATCH - SQL backup integrity verification FAILED!" -Level ERROR

                # Report checksum failure to VLABS Monitor
                Send-BackupReport -JobName $Job.JobName -Status 'ChecksumMismatch' -ChecksumResult $checksumResult -ErrorMessage $checksumResult.Reason

                Disconnect-SmbShare -Job $Job | Out-Null
                Disconnect-Tailscale | Out-Null
                return $false
            }
        }
        else {
            Write-Log "Robocopy failed with exit code: $LASTEXITCODE" -Level ERROR

            # Report failure to VLABS Monitor
            Send-BackupReport -JobName $Job.JobName -Status 'Failed' -ErrorMessage "Robocopy exit code: $LASTEXITCODE"

            Disconnect-SmbShare -Job $Job | Out-Null
            Disconnect-Tailscale | Out-Null
            return $false
        }
    }
    catch {
        Write-Log "Error during SQL backup synchronization: $_" -Level ERROR

        # Report failure to VLABS Monitor
        Send-BackupReport -JobName $Job.JobName -Status 'Failed' -ErrorMessage $_.ToString()

        Disconnect-SmbShare -Job $Job | Out-Null
        Disconnect-Tailscale | Out-Null
        return $false
    }
}

function Invoke-RetentionPolicy {
    param(
        [Parameter(Mandatory=$true)]
        [string]$DestinationFolder,

        [Parameter(Mandatory=$true)]
        [int]$Retention
    )

    try {
        Write-Log "Applying retention policy: Keep $Retention most recent backup(s)" -Level INFO

        # Get all backup items (files or directories) in the destination folder
        $backupItems = Get-ChildItem -Path $DestinationFolder |
                       Sort-Object CreationTime -Descending

        if ($backupItems.Count -le $Retention) {
            Write-Log "Current backup count ($($backupItems.Count)) is within retention limit ($Retention)" -Level INFO
            return
        }

        # Delete oldest backups beyond retention limit
        $itemsToDelete = $backupItems | Select-Object -Skip $Retention

        foreach ($item in $itemsToDelete) {
            try {
                Write-Log "Deleting old backup: $($item.Name) (Created: $($item.CreationTime))" -Level INFO

                if ($item.PSIsContainer) {
                    Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction Stop
                }
                else {
                    Remove-Item -Path $item.FullName -Force -ErrorAction Stop
                }

                Write-Log "Successfully deleted: $($item.Name)" -Level SUCCESS
            }
            catch {
                Write-Log "Failed to delete $($item.Name): $_" -Level ERROR
            }
        }

        Write-Log "Retention policy applied: Deleted $($itemsToDelete.Count) old backup(s)" -Level SUCCESS
    }
    catch {
        Write-Log "Error applying retention policy: $_" -Level ERROR
    }
}

#endregion

#region Main Execution

function Invoke-BackupJob {
    param(
        [Parameter(Mandatory=$true)]
        [string]$JobName
    )

    Write-Log "=== Backup Job Execution Started: $JobName ===" -Level INFO

    # Load job configuration
    $jobs = Get-Jobs
    if (-not $jobs) {
        Write-Log "Failed to load job configuration" -Level ERROR
        return $false
    }

    $job = $jobs | Where-Object { $_.JobName -eq $JobName }
    if (-not $job) {
        Write-Log "Job not found: $JobName" -Level ERROR
        return $false
    }

    # Check if job is enabled
    if ($job.Enabled -eq $false) {
        Write-Log "Job is disabled: $JobName" -Level WARNING
        return $false
    }

    # Update status to Running
    Update-JobStatus -JobName $JobName -Status "Running"

    # Execute backup based on type
    $success = $false

    try {
        switch ($job.BackupType) {
            "F" {
                # Capture only the boolean return value, suppress other output
                $result = Invoke-FileBackup -Job $job
                $success = ($result -eq $true)
            }
            "D" {
                $result = Invoke-DirectoryBackup -Job $job
                $success = ($result -eq $true)
            }
            "SQL" {
                $result = Invoke-SqlBackup -Job $job
                $success = ($result -eq $true)
            }
            default {
                Write-Log "Unknown backup type: $($job.BackupType)" -Level ERROR
                $success = $false
            }
        }
    }
    catch {
        Write-Log "Unexpected error during backup execution: $_" -Level ERROR
        $success = $false
    }

    # Ensure $success is strictly boolean
    if ($success -ne $true) {
        $success = $false
    }

    # Update final status
    $finalStatus = if ($success -eq $true) { "Success" } else { "Failed" }
    Update-JobStatus -JobName $JobName -Status $finalStatus

    Write-Log "=== Backup Job Execution Completed: $JobName - Status: $finalStatus ===" -Level $(if($success -eq $true){'SUCCESS'}else{'ERROR'})

    return $success
}

#endregion

# Main entry point
try {
    # Ensure log directory exists
    if (-not (Test-Path $LogPath)) {
        New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
    }

    # Execute the backup job
    $result = Invoke-BackupJob -JobName $JobName

    exit $(if ($result) { 0 } else { 1 })
}
catch {
    Write-Log "Fatal error in backup execution: $_" -Level ERROR
    exit 1
}
