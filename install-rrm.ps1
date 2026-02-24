<#
.SYNOPSIS
    One-liner installer for VLABS Resilience Ring Manager
    
.DESCRIPTION
    Run with: iex (irm https://raw.githubusercontent.com/GonzFC/SecureBackups/main/install-rrm.ps1)
    
.NOTES
    Part of VLABS Infrastructure Tools
#>

$ErrorActionPreference = 'Stop'

# Configuration
$RepoOwner = 'GonzFC'
$RepoName = 'SecureBackups'
$Branch = 'main'
$InstallPath = 'C:\VLABS_ResilienceRingManager'
$DataPath = 'C:\ProgramData\VLABS_RRM'

function Write-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  VLABS RESILIENCE RING MANAGER" -ForegroundColor Cyan
    Write-Host "         INSTALLER" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Test-Administrator {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-WithGit {
    Write-Host "Installing via Git..." -ForegroundColor Cyan
    
    if (Test-Path $InstallPath) {
        Write-Host "  Updating existing installation..." -ForegroundColor Gray
        Push-Location $InstallPath
        git fetch origin $Branch 2>&1 | Out-Null
        git reset --hard "origin/$Branch" 2>&1 | Out-Null
        Pop-Location
    }
    else {
        Write-Host "  Cloning repository..." -ForegroundColor Gray
        git clone --branch $Branch "https://github.com/$RepoOwner/$RepoName.git" $InstallPath 2>&1 | Out-Null
    }
    
    return $true
}

function Install-WithZip {
    Write-Host "Installing via ZIP download..." -ForegroundColor Cyan
    
    $zipUrl = "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/$Branch.zip"
    $zipPath = Join-Path $env:TEMP 'RRM_Install.zip'
    $extractPath = Join-Path $env:TEMP 'RRM_Install_Extract'
    
    # Download
    Write-Host "  Downloading..." -ForegroundColor Gray
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
    
    # Extract
    Write-Host "  Extracting..." -ForegroundColor Gray
    if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractPath)
    
    # Find extracted folder
    $sourceFolder = Get-ChildItem $extractPath -Directory | Select-Object -First 1
    
    # Copy to install location
    if (Test-Path $InstallPath) { Remove-Item $InstallPath -Recurse -Force }
    Copy-Item -Path $sourceFolder.FullName -Destination $InstallPath -Recurse
    
    # Cleanup
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    
    return $true
}

# Main installation
Write-Banner

# Check admin
if (-not (Test-Administrator)) {
    Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
    $scriptUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/install-rrm.ps1"
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"iex (irm '$scriptUrl')`""
    exit
}

Write-Host "[OK] Running as Administrator" -ForegroundColor Green

# Check Tailscale
Write-Host "Checking Tailscale..." -ForegroundColor Gray
$tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
if ($tailscale) {
    Write-Host "[OK] Tailscale found" -ForegroundColor Green
}
else {
    Write-Host "[WARN] Tailscale not found - required for operation" -ForegroundColor Yellow
}

# Create data directory
if (-not (Test-Path $DataPath)) {
    New-Item -Path $DataPath -ItemType Directory -Force | Out-Null
    Write-Host "[OK] Created data directory: $DataPath" -ForegroundColor Green
}

# Install
$gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)

if ($gitAvailable) {
    $success = Install-WithGit
}
else {
    $success = Install-WithZip
}

if ($success) {
    # Unblock files
    Get-ChildItem -Path $InstallPath -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  INSTALLATION COMPLETE!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Install path: $InstallPath" -ForegroundColor White
    Write-Host "Data path:    $DataPath" -ForegroundColor White
    Write-Host ""
    Write-Host "Starting Resilience Ring Manager..." -ForegroundColor Cyan
    Write-Host ""
    
    # Register background collector task
    Write-Host "Registering collector task..." -ForegroundColor Gray -NoNewline
    try {
        $taskName   = "VLABS_RRM_Collector"
        $scriptPath = Join-Path $InstallPath 'Run-Collector.ps1'

        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }

        $action = New-ScheduledTaskAction `
            -Execute "PowerShell.exe" `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

        $trigger = New-ScheduledTaskTrigger `
            -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Hours 1) `
            -RepetitionDuration (New-TimeSpan -Days 9999)

        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
            -StartWhenAvailable -RunOnlyIfNetworkAvailable

        $principal = New-ScheduledTaskPrincipal `
            -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

        Register-ScheduledTask `
            -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force | Out-Null

        Write-Host " [OK]" -ForegroundColor Green
    }
    catch {
        Write-Host " [WARN] $_" -ForegroundColor Yellow
    }

    # Create history directory
    $historyPath = Join-Path $DataPath 'history'
    if (-not (Test-Path $historyPath)) {
        New-Item -Path $historyPath -ItemType Directory -Force | Out-Null
    }

    # Launch the manager
    $managerScript = Join-Path $InstallPath 'ResilienceRingManager.ps1'
    if (Test-Path $managerScript) {
        & $managerScript
    }
    else {
        Write-Host "Manager script not found: $managerScript" -ForegroundColor Red
        Write-Host "The repository may still be updating. Try running manually." -ForegroundColor Yellow
    }
}
else {
    Write-Host ""
    Write-Host "Installation failed!" -ForegroundColor Red
}
