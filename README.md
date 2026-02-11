# Resilience Ring

**Distributed Backup System** - Small but professional tool to backup files and databases to NAT-traversal locations via Tailscale.

## Quick Start (One-Liner)

```powershell
iex (irm https://raw.githubusercontent.com/GonzFC/SecureBackups/main/install.ps1)
```

Or the longer form:
```powershell
irm https://raw.githubusercontent.com/GonzFC/SecureBackups/main/install.ps1 | iex
```

## What is Resilience Ring?

Resilience Ring creates a distributed backup mesh where each site in your organization backs up to multiple peer sites. Instead of relying on a single backup server (single point of failure), your backups are distributed across your network.

```
   Site A (SLP) ──────► Site B (MTY)
       │                    │
       │                    │
       ▼                    ▼
   Site C (GDL) ◄────── Site D (CDMX)
```

**Key Features:**
- 🔄 **Self-updating** - Always runs the latest version
- 🔐 **Secure** - Credentials encrypted with Windows DPAPI
- 🌐 **NAT Traversal** - Uses Tailscale for connectivity
- ✅ **Integrity Verification** - SHA256 checksums post-copy
- 📊 **VLABS Monitor Ready** - Telemetry hooks for central monitoring

## Requirements

- Windows Server 2012 R2+ or Windows 10/11
- PowerShell 5.1+
- [Tailscale](https://tailscale.com/) installed and connected
- Administrator privileges

## Backup Types

| Type | Description | Use Case |
|------|-------------|----------|
| **F** (File) | Single file backup with timestamp | Critical config files, databases |
| **D** (Directory) | Full directory mirror | Document folders, application data |
| **SQL** | SQL Server backup folder sync | Database backup directories |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    RESILIENCE RING                       │
├─────────────────────────────────────────────────────────┤
│  install.ps1        → Bootstrap installer (one-liner)   │
│  ResilienceRing.ps1 → Main TUI with auto-update         │
│  Execute-Backup.ps1 → Scheduled task executor           │
│  version.txt        → Version control                   │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────┐
│                    VLABS MONITOR                         │
│              (Central Monitoring Server)                 │
├─────────────────────────────────────────────────────────┤
│  • Collector API (receives telemetry)                   │
│  • Dashboard (status of all nodes)                      │
│  • Alert Engine (Telegram notifications)                │
└─────────────────────────────────────────────────────────┘
```

## Configuration

Configuration files are stored in the installation directory:

| File | Purpose |
|------|---------|
| `destinations.json` | Backup target definitions (SMB paths + credentials) |
| `jobs.json` | Backup job configurations |
| `Logs/` | Daily logs with auto-archival |

## Usage

### From the TUI

Run the installer/updater, then use the menu:

```
========================================
         RESILIENCE RING v1.1.0
    Distributed Backup System
========================================

 DESTINATIONS
   1. Create Destination
   2. Edit Destination
   3. Delete Destination

 BACKUP JOBS
   4. Create Backup Job
   5. Edit Backup Job
   6. Delete Backup Job
   7. Run Backup Job Now

 STATUS
   8. Show All Backup Jobs
   9. View Status & History

 SYSTEM
   U. Check for Updates
   0. Exit
```

### Scheduled Execution

Backup jobs automatically create Windows Scheduled Tasks. The executor script runs independently with full logging and checksum verification.

## VLABS Monitor Integration

When VLABS Monitor is deployed, set the environment variable:

```powershell
$env:VLABS_MONITOR_URL = "http://100.x.x.x:8080/api"
```

The client will then report:
- Backup success/failure
- Checksum verification results
- Periodic heartbeats

## Updating

From the menu, press `U` to check for and apply updates. The update preserves your configuration files.

Or re-run the one-liner:
```powershell
iex (irm https://raw.githubusercontent.com/GonzFC/SecureBackups/main/install.ps1)
```

## Security Notes

- Credentials are encrypted using Windows DPAPI (machine/user-specific)
- All traffic travels over Tailscale (WireGuard encrypted)
- Files at rest are not encrypted (same legal entity owns all nodes)

## License

Proprietary - VLABS Internal Use

---

**Powered by VLABS** | Part of the VLABS Infrastructure Toolkit
