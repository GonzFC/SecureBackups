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
$script:ConfigPath = "C:\VLABS_SecureBackups"
$script:JobsFile = Join-Path $ConfigPath "jobs.json"
$script:LogPath = Join-Path $ConfigPath "Logs"

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

        # Decrypt password
        $securePassword = ConvertFrom-EncryptedPassword -EncryptedPassword $Job.DestinationEncryptedPassword
        if (-not $securePassword) {
            Write-Log "Failed to decrypt password" -Level ERROR
            return $false
        }

        $plainPassword = Get-PlainTextPassword -SecurePassword $securePassword
        if (-not $plainPassword) {
            Write-Log "Failed to retrieve password" -Level ERROR
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
            Disconnect-Tailscale
            return $false
        }

        # Verify destination is accessible
        if (-not (Test-Path $Job.DestinationPath)) {
            Write-Log "Destination path not accessible: $($Job.DestinationPath)" -Level ERROR
            Disconnect-SmbShare -Job $Job
            Disconnect-Tailscale
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
            if (Test-Path $copiedFile) {
                Rename-Item -Path $copiedFile -NewName $fileName -Force -ErrorAction Stop
            }

            Write-Log "File backup completed successfully" -Level SUCCESS

            # Apply retention policy
            Invoke-RetentionPolicy -DestinationFolder $destinationFolder -Retention $Job.Retention

            # Disconnect from SMB share
            Disconnect-SmbShare -Job $Job

            # Bring down Tailscale connection
            Disconnect-Tailscale

            return $true
        }
        else {
            Write-Log "Robocopy failed with exit code: $LASTEXITCODE" -Level ERROR
            Disconnect-SmbShare -Job $Job
            Disconnect-Tailscale
            return $false
        }
    }
    catch {
        Write-Log "Error during file backup: $_" -Level ERROR
        Disconnect-SmbShare -Job $Job
        Disconnect-Tailscale
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
            Disconnect-Tailscale
            return $false
        }

        # Verify destination is accessible
        if (-not (Test-Path $Job.DestinationPath)) {
            Write-Log "Destination path not accessible: $($Job.DestinationPath)" -Level ERROR
            Disconnect-SmbShare -Job $Job
            Disconnect-Tailscale
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
            Write-Log "Directory synchronization completed successfully" -Level SUCCESS

            # Disconnect from SMB share
            Disconnect-SmbShare -Job $Job

            # Bring down Tailscale connection
            Disconnect-Tailscale

            return $true
        }
        else {
            Write-Log "Robocopy failed with exit code: $LASTEXITCODE" -Level ERROR
            Disconnect-SmbShare -Job $Job
            Disconnect-Tailscale
            return $false
        }
    }
    catch {
        Write-Log "Error during directory backup: $_" -Level ERROR
        Disconnect-SmbShare -Job $Job
        Disconnect-Tailscale
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
            Disconnect-Tailscale
            return $false
        }

        # Verify destination is accessible
        if (-not (Test-Path $Job.DestinationPath)) {
            Write-Log "Destination path not accessible: $($Job.DestinationPath)" -Level ERROR
            Disconnect-SmbShare -Job $Job
            Disconnect-Tailscale
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
            Write-Log "SQL backup synchronization completed successfully" -Level SUCCESS
            Disconnect-SmbShare -Job $Job
            Disconnect-Tailscale
            return $true
        }
        else {
            Write-Log "Robocopy failed with exit code: $LASTEXITCODE" -Level ERROR
            Disconnect-SmbShare -Job $Job
            Disconnect-Tailscale
            return $false
        }
    }
    catch {
        Write-Log "Error during SQL backup synchronization: $_" -Level ERROR
        Disconnect-SmbShare -Job $Job
        Disconnect-Tailscale
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
                $success = Invoke-FileBackup -Job $job
            }
            "D" {
                $success = Invoke-DirectoryBackup -Job $job
            }
            "SQL" {
                $success = Invoke-SqlBackup -Job $job
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

    # Update final status
    $finalStatus = if ($success) { "Success" } else { "Failed" }
    Update-JobStatus -JobName $JobName -Status $finalStatus

    Write-Log "=== Backup Job Execution Completed: $JobName - Status: $finalStatus ===" -Level $(if($success){'SUCCESS'}else{'ERROR'})

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
