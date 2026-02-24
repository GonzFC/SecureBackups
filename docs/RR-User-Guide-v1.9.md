# VLABS Resilience Ring
## User Guide

**Version:** 1.9 | **Document:** v1.0 | **Audience:** Customer (Administrator)

---

## Overview

This guide covers day-to-day operation of the Resilience Ring client on each peer machine. For product overview and architecture, see the Product Overview document.

---

## Installation

Run this one-liner from an **elevated PowerShell** window:

```powershell
iex (irm https://raw.githubusercontent.com/GonzFC/SecureBackups/main/install.ps1)
```

The installer will:
1. Download all scripts to `C:\VLABS_ResilienceRing\`
2. Create the data directory at `C:\ProgramData\VLABS_ResilienceRing\`
3. Launch the main menu

> **Note:** Your configuration (jobs, peers, ring settings) is stored in `C:\ProgramData\VLABS_ResilienceRing\` and is **never overwritten** by updates.

---

## Starting the Application

```powershell
# From any elevated PowerShell:
powershell -File "C:\VLABS_ResilienceRing\ResilienceRing.ps1"
```

On startup, the application will:
- Check for and apply updates automatically
- Validate all jobs and tasks
- Auto-fix any configuration issues found
- Display the main menu

---

## Main Menu

```
========================================
      VLABS RESILIENCE RING v1.9.x
    Distributed Backup System
========================================

 BACKUP JOBS
   1. Create Backup Job
   2. Edit Backup Job
   3. Delete Backup Job
   4. Run Backup Job Now
   5. Show All Backup Jobs

 STORAGE PEERS
   P. Add Storage Peer (configure this machine)
   S. Show Available Storage Peers
   D. Discover & Update Peer List

 STATUS
   9. View Status & History

 SYSTEM
   U. Check for Updates
   0. Exit
```

---

## First-Time Setup (New Peer)

### Step 1: Configure This Machine as a Storage Peer

Press **P** from the main menu and follow the prompts:

| Prompt | Description | Example |
|--------|-------------|---------|
| Customer Code | Short identifier for your ring (lowercase, no spaces) | `acme` |
| Tailscale Tag | Tag used by all peers in this ring | `tag:rr-acme` |
| Location Name | Human-readable name for this site | `San Antonio Office` |
| Storage Path | Where to store backups received from peers | `D:\Backups` |
| Storage Quota | How much disk space to allocate | `500` (GB) |

This creates:
- Local service account `RR_Service` for secure SMB access
- SMB share `RR_Backups` with correct permissions
- Registers this peer on the mesh

### Step 2: Discover Peers

Press **D** to scan for other machines in the ring using your Tailscale tag.

> All peers must have the same **Customer Code** and **Tailscale Tag** to be discovered.

### Step 3: Create a Backup Job

Press **1** and follow the prompts:

| Prompt | Description | Example |
|--------|-------------|---------|
| Application Name | Short identifier for this job | `Community` |
| Backup Type | F=File, D=Directory, SQL=SQL Server backup folder | `SQL` |
| Backup Object | Path to the file or folder to back up | `C:\Program Files\Microsoft SQL Server\MSSQL16.COMMUNITY\MSSQL\Backup` |
| Monthly copies | How many end-of-month snapshots to keep | `3` |
| Weekly copies | How many Saturday snapshots to keep | `4` |
| Recent copies | How many recent run copies to keep | `2` |
| Frequency | Run every N hours | `6` |
| Start hour | First run of the day (24h format) | `5` |

This creates a **Windows Scheduled Task** that runs automatically.

---

## Daily Operations

### Checking Backup Status

Press **9** (View Status & History) to see:
- Last run time and result for each job
- Next scheduled run
- Source and destination paths
- Recent log entries

### Running a Job Immediately

Press **4**, then select the job. Useful for:
- Testing after initial setup
- Running before a planned change
- Catching up after a machine was offline

### Viewing Available Peers

Press **S** to see all discovered peers with:
- Hostname and Tailscale IP
- Storage used / total quota
- Last seen time

---

## Backup Types Explained

### SQL (Recommended for SQL Server)
Points to the SQL Server backup folder. SQL Server writes `.bak` files there; Resilience Ring copies the entire folder to peers.

```
BackupObject: C:\Program Files\Microsoft SQL Server\MSSQL16.INSTANCE\MSSQL\Backup
```

### Directory (D)
Full mirror of any folder. Uses robocopy with `/MIR` flag — destination always matches source exactly.

```
BackupObject: C:\MyApp\Data
```

### File (F)
Single file with timestamp preservation. Useful for config files or flat database files.

```
BackupObject: C:\MyApp\config.db
```

---

## Retention Policy

Each backup job maintains three tiers of copies **per peer**:

| Tier | Trigger | Example folder name |
|------|---------|---------------------|
| **Recent** | Every run | `Community-2026-02-14-1430` |
| **Weekly** | Saturdays | `Community-2026-02-08-weekly` |
| **Monthly** | Last day of month | `Community-2026-01-monthly` |

Old copies beyond the configured count are automatically deleted.

**Example:** With retention (3 monthly, 4 weekly, 2 recent), you have up to **9 restore points** per peer, up to **18+ copies** across 2 peers.

---

## Updating

Press **U** from the main menu, or re-run the install one-liner. Your configuration is always preserved.

The application also checks for updates automatically on startup and applies them silently.

---

## Troubleshooting

### "Job has no destinations"
The job exists but has no peer assigned. Run **D** (Discover Peers) first, then restart the application. The auto-fix will assign available peers.

### "Failed to connect to peer"
- Verify Tailscale is running on both machines (`tailscale status`)
- Confirm both machines use the same Customer Code
- Check the peer's `RR_Service` account is active

### "Source not found"
The backup source path doesn't exist. Use **2** (Edit Backup Job) to correct the path.

### Jobs running but status shows "Failed"
Check the log files at `C:\ProgramData\VLABS_ResilienceRing\Logs\`. The robocopy logs (`robocopy_<JobName>_<Peer>_<timestamp>.log`) contain detailed transfer output.

### Log File Locations

| File | Contents |
|------|----------|
| `C:\ProgramData\VLABS_ResilienceRing\Logs\VLABS_Backup_YYYYMMDD.log` | Main backup execution log |
| `C:\ProgramData\VLABS_ResilienceRing\Logs\robocopy_<job>_<peer>_<ts>.log` | Robocopy transfer detail |
| `C:\ProgramData\VLABS_ResilienceRing\debug.log` | Application debug output |

---

## File Reference

| Path | Purpose |
|------|---------|
| `C:\VLABS_ResilienceRing\` | Scripts (updated automatically) |
| `C:\ProgramData\VLABS_ResilienceRing\` | Your configuration and logs (never touched by updates) |
| `C:\ProgramData\VLABS_ResilienceRing\ring-config.json` | This peer's identity (customer code, location, storage) |
| `C:\ProgramData\VLABS_ResilienceRing\jobs.json` | Backup job definitions |
| `C:\ProgramData\VLABS_ResilienceRing\jobs-status.json` | Last run results per job |
| `C:\ProgramData\VLABS_ResilienceRing\storage-peers.json` | Known peers in the ring |

---

*VLABS Resilience Ring — User Guide v1.0*
*For support, contact your VLABS representative*
