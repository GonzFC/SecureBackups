<#
.SYNOPSIS
    Resilience Ring - Bootstrap Installer

.DESCRIPTION
    One-liner installer for Resilience Ring backup system.

    Usage:
        iex (irm https://raw.githubusercontent.com/GonzFC/SecureBackups/main/install.ps1)

    Or:
        irm https://raw.githubusercontent.com/GonzFC/SecureBackups/main/install.ps1 | iex

.NOTES
    Part of VLABS Resilience Ring - Distributed Backup System
    Automatically elevates to Administrator if needed
#>

$ErrorActionPreference = 'Stop'

# Configuration
$script:RepoOwner = 'GonzFC'
$script:RepoName = 'SecureBackups'
$script:RepoBranch = 'main'
$script:InstallPath = 'C:\VLABS_ResilienceRing'
$script:AppName = 'Resilience Ring'

# Colors
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = 'White'
    )
    Write-Host $Message -ForegroundColor $Color
}

# Banner
Clear-Host
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "      VLABS RESILIENCE RING" -ForegroundColor Cyan
Write-Host "    Distributed Backup System" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-ColorOutput "Administrator privileges required." -Color Yellow
    Write-ColorOutput "Relaunching as Administrator..." -Color Yellow
    Write-Host ""

    try {
        # Re-download and execute as admin
        $scriptUrl = "https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/install.ps1"
        $scriptContent = Invoke-RestMethod -Uri $scriptUrl -UseBasicParsing
        $encodedScript = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($scriptContent))

        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedScript"
        exit 0
    }
    catch {
        Write-ColorOutput "Failed to elevate. Please run PowerShell as Administrator manually." -Color Red
        Write-Host ""
        Write-Host "Then run:" -ForegroundColor Gray
        Write-Host "  iex (irm https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/install.ps1)" -ForegroundColor White
        Write-Host ""
        pause
        exit 1
    }
}

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-ColorOutput "ERROR: PowerShell 5.1 or higher is required." -Color Red
    Write-ColorOutput "Current version: $($PSVersionTable.PSVersion)" -Color Yellow
    Write-Host ""
    Write-ColorOutput "Please upgrade PowerShell and try again." -Color Yellow
    Write-Host ""
    pause
    exit 1
}

Write-ColorOutput "[OK] Running as Administrator" -Color Green
Write-ColorOutput "[OK] PowerShell Version: $($PSVersionTable.PSVersion)" -Color Green
Write-Host ""

# Enable TLS 1.2
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-ColorOutput "[OK] TLS 1.2 enabled" -Color Green
}
catch {
    Write-ColorOutput "[WARN] Could not enable TLS 1.2" -Color Yellow
}

Write-Host ""
Write-ColorOutput "Installation directory: $script:InstallPath" -Color Cyan
Write-Host ""

# Check if Git is available
$gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)

if ($gitAvailable) {
    Write-ColorOutput "Git detected - using git clone for installation" -Color Green
    Write-Host ""

    try {
        # Check if directory exists and has .git
        if (Test-Path (Join-Path $script:InstallPath '.git')) {
            Write-ColorOutput "Existing installation found. Updating..." -Color Yellow
            Push-Location $script:InstallPath
            git fetch origin $script:RepoBranch --quiet
            git reset --hard "origin/$script:RepoBranch" --quiet
            Pop-Location
            Write-ColorOutput "Repository updated successfully!" -Color Green
        }
        else {
            # Remove existing directory if it exists (but not a git repo)
            if (Test-Path $script:InstallPath) {
                Write-ColorOutput "Removing existing non-git installation..." -Color Yellow
                Remove-Item -Path $script:InstallPath -Recurse -Force -ErrorAction Stop
            }

            # Clone repository
            Write-ColorOutput "Cloning repository..." -Color Cyan
            git clone --quiet "https://github.com/$script:RepoOwner/$script:RepoName.git" $script:InstallPath

            Write-ColorOutput "Repository cloned successfully!" -Color Green
        }

        # Unblock all files
        Write-ColorOutput "Unblocking files..." -Color White
        Get-ChildItem -Path $script:InstallPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    }
    catch {
        Write-ColorOutput "Git operation failed: $($_.Exception.Message)" -Color Red
        Write-ColorOutput "Falling back to ZIP download..." -Color Yellow
        $gitAvailable = $false
    }
}

if (-not $gitAvailable) {
    Write-ColorOutput "Downloading Resilience Ring (ZIP method)..." -Color Cyan
    Write-Host ""

    try {
        $zipUrl = "https://github.com/$script:RepoOwner/$script:RepoName/archive/refs/heads/$script:RepoBranch.zip"
        $zipPath = Join-Path $env:TEMP 'ResilienceRing.zip'
        $extractPath = Join-Path $env:TEMP 'ResilienceRing_Extract'

        # Download
        Write-ColorOutput "Downloading from GitHub..." -Color White
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

        # Extract
        Write-ColorOutput "Extracting files..." -Color White
        if (Test-Path $extractPath) {
            Remove-Item -Path $extractPath -Recurse -Force
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractPath)

        # Move to final location
        $extractedFolder = Get-ChildItem $extractPath -Directory | Select-Object -First 1

        if (Test-Path $script:InstallPath) {
            Remove-Item -Path $script:InstallPath -Recurse -Force
        }

        Move-Item -Path $extractedFolder.FullName -Destination $script:InstallPath

        # Cleanup
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue

        # Unblock all files
        Write-ColorOutput "Unblocking downloaded files..." -Color White
        Get-ChildItem -Path $script:InstallPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

        Write-ColorOutput "Download complete!" -Color Green
    }
    catch {
        Write-ColorOutput "ERROR: Failed to download Resilience Ring" -Color Red
        Write-ColorOutput $_.Exception.Message -Color Red
        Write-Host ""
        pause
        exit 1
    }
}

# Migrate existing configuration if present
$oldConfigPath = "C:\VLABS_SecureBackups"
if ((Test-Path $oldConfigPath) -and ($oldConfigPath -ne $script:InstallPath)) {
    Write-Host ""
    Write-ColorOutput "Existing configuration found at $oldConfigPath" -Color Yellow

    $configFiles = @('destinations.json', 'jobs.json')
    $migratedAny = $false

    foreach ($file in $configFiles) {
        $oldFile = Join-Path $oldConfigPath $file
        $newFile = Join-Path $script:InstallPath $file

        if ((Test-Path $oldFile) -and (-not (Test-Path $newFile))) {
            Copy-Item -Path $oldFile -Destination $newFile -Force
            Write-ColorOutput "  Migrated: $file" -Color Green
            $migratedAny = $true
        }
    }

    # Migrate logs folder
    $oldLogs = Join-Path $oldConfigPath 'Logs'
    $newLogs = Join-Path $script:InstallPath 'Logs'
    if ((Test-Path $oldLogs) -and (-not (Test-Path $newLogs))) {
        Copy-Item -Path $oldLogs -Destination $newLogs -Recurse -Force
        Write-ColorOutput "  Migrated: Logs folder" -Color Green
        $migratedAny = $true
    }

    if ($migratedAny) {
        Write-ColorOutput "Configuration migrated from legacy installation!" -Color Green
    }
}

# Get installed version
$versionFile = Join-Path $script:InstallPath 'version.txt'
$installedVersion = if (Test-Path $versionFile) {
    (Get-Content $versionFile -Raw).Trim()
} else {
    'unknown'
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-ColorOutput "  Installation Complete!" -Color Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-ColorOutput "  Version:  $installedVersion" -Color Cyan
Write-ColorOutput "  Location: $script:InstallPath" -Color Cyan
Write-Host ""

# Create shortcut in Start Menu
try {
    $startMenuPath = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $shortcutPath = Join-Path $startMenuPath 'Resilience Ring.lnk'

    $WScriptShell = New-Object -ComObject WScript.Shell
    $shortcut = $WScriptShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:InstallPath\ResilienceRing.ps1`""
    $shortcut.WorkingDirectory = $script:InstallPath
    $shortcut.Description = 'Resilience Ring - Distributed Backup System by VLABS'
    $shortcut.Save()

    Write-ColorOutput "  Start Menu shortcut created" -Color Green
    Write-Host ""
}
catch {
    # Not critical
}

# Offer to run now
Write-Host "Would you like to run Resilience Ring now? [Y/n]: " -NoNewline -ForegroundColor Yellow
$response = Read-Host

if ($response -eq '' -or $response -match '^[Yy]') {
    Write-Host ""
    Write-ColorOutput "Launching Resilience Ring..." -Color Cyan
    Write-Host ""
    Start-Sleep -Seconds 1

    # Launch the app
    $mainScript = Join-Path $script:InstallPath 'ResilienceRing.ps1'
    if (Test-Path $mainScript) {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$mainScript`"" -WorkingDirectory $script:InstallPath
    }
    else {
        # Fallback to old script name during transition
        $legacyScript = Join-Path $script:InstallPath 'VLABS-SecureBackup.ps1'
        if (Test-Path $legacyScript) {
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$legacyScript`"" -WorkingDirectory $script:InstallPath
        }
    }
}
else {
    Write-Host ""
    Write-ColorOutput "To run Resilience Ring later:" -Color Cyan
    Write-Host ""
    Write-Host "  Option 1: Search 'Resilience Ring' in Start Menu" -ForegroundColor White
    Write-Host ""
    Write-Host "  Option 2: Run this one-liner again:" -ForegroundColor White
    Write-Host "    iex (irm https://raw.githubusercontent.com/$script:RepoOwner/$script:RepoName/$script:RepoBranch/install.ps1)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Option 3: Direct execution:" -ForegroundColor White
    Write-Host "    & '$script:InstallPath\ResilienceRing.ps1'" -ForegroundColor Gray
    Write-Host ""
}
