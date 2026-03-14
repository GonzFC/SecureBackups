# VLABS Resilience Ring

**Distributed Backup System** - Professional backup tool that automatically replicates data across multiple storage peers via Tailscale.

## Quick Start

```powershell
iex (irm https://raw.githubusercontent.com/GonzFC/SecureBackups/main/install.ps1)
```

## What is Resilience Ring?

Resilience Ring creates a distributed backup mesh where each site backs up to **multiple peer sites automatically**. No single point of failure.

```
   San Antonio ──────► Houston
       │    \          /   │
       │     \        /    │
       ▼      ▼      ▼     ▼
   Austin ◄──────── Dallas
   
   Every backup exists on at least 2 remote peers
```

## Key Features

- 🔄 **Self-updating** - Always runs the latest version
- 🎯 **Smart Peer Selection** - Automatically distributes to least-used peers
- 📅 **Retention Policies** - Monthly, weekly, and recent backups
- ✅ **Integrity Verification** - SHA256 checksums post-copy
- 🌐 **NAT Traversal** - Uses Tailscale for connectivity
- 📊 **VLABS Monitor Ready** - Telemetry for central monitoring

## Requirements

- Windows Server 2012 R2+ or Windows 10/11
- PowerShell 5.1+
- [Tailscale](https://tailscale.com/) installed and connected
- Administrator privileges

## Setup Flow

### 1. Add Storage Peer (P)

Run on each machine that will participate in the ring:

```
STEP 1: Tailscale Setup
STEP 2: Customer Codename (e.g., "vlabs")
STEP 3: Tailscale Tag (e.g., "tag:rr-vlabs")
STEP 4: Location Name (e.g., "San Antonio Office")
STEP 5: Storage Path (e.g., "D:\Backups")
STEP 6: Storage Quota (e.g., 500 GB)
```

This creates:
- Local service account `RR_Service` for SMB access
- SMB share `RR_Backups` with proper permissions
- Registration in the peer mesh
- Runtime quota metadata used to enforce the maximum backup size on every execution

### 2. Discover Peers (D)

After setting up multiple machines, run D to discover all peers with the same tag.

### 3. Create Backup Job

Creates a backup job with automatic peer selection:

```
STEP 1: Application Name (e.g., "Community")
STEP 2: Backup Type (F=File, D=Directory, SQL=Database)
STEP 3: Backup Object (source path)
STEP 4: Retention Policy
        - Monthly copies (last day of month): 3
        - Weekly copies (Saturdays): 4
        - Recent copies: 2
STEP 5: Frequency (every N hours, starting at HH:00)
```

## Retention Policy

The retention system keeps organized copies:

| Type | Naming Convention | Example |
|------|-------------------|---------|
| Monthly | `AppName-YYYY-MM-monthly` | `Community-2026-01-monthly` |
| Weekly | `AppName-YYYY-MM-DD-weekly` | `Community-2026-02-08-weekly` |
| Recent | `AppName-YYYY-MM-DD-HHMM` | `Community-2026-02-12-1430` |

With retention policy (3, 4, 2):
- 3 monthly backups (last 3 months' end-of-month)
- 4 weekly backups (last 4 Saturdays)
- 2 recent backups (last 2 runs)
- **Total: Up to 9 copies** across all peers

## Peer Selection Algorithm

Backups are **automatically distributed** to at least 2 remote peers:

1. **Minimum 2 Peers** - Every backup exists in 3 places (source + 2 peers)
2. **Even Distribution** - Selects peers with lowest storage usage
3. **Capacity Aware** - Only uses larger peers when smaller ones hit 70%
4. **Auto-Failover** - If a peer is offline, uses next best available

## Storage Quota Enforcement

`Storage Quota` is enforced at runtime, not just during setup:

- The system recalculates current usage of each peer before every backup run.
- If `current usage + estimated backup size > QuotaGB`, that peer is skipped for that execution.
- If a configured peer no longer has capacity, the system tries to use another available peer with remaining quota.
- If no peer has enough capacity, the backup fails instead of filling the destination drive.

This keeps the configured backup folder from growing past the maximum logical size defined for the peer.

## File Structure

```
C:\VLABS_ResilienceRing\           ← Scripts (git repo)
├── ResilienceRing.ps1
├── Execute-Backup.ps1
├── PeerManagement.ps1
└── ...

C:\ProgramData\VLABS_ResilienceRing\  ← Data (persists across updates)
├── ring-config.json
├── storage-peers.json
├── jobs.json
└── Logs\

\\peer\RR_Backups\                 ← Remote storage
└── CUSTOMER_CODE\
    └── Location\
        └── Application\
            └── type\
                ├── AppName-2026-01-monthly\
                ├── AppName-2026-02-08-weekly\
                └── AppName-2026-02-12-1430\
```

## Backup Types

| Type | Description | Use Case |
|------|-------------|----------|
| **F** (File) | Single file with timestamp | Config files, small databases |
| **D** (Directory) | Full directory mirror | Document folders, app data |
| **SQL** | SQL Server backup folder | Database backup directories |

## Usage

### Main Menu

```
========================================
      VLABS RESILIENCE RING v1.8.0
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

## Scheduled Execution

Each backup job creates a Windows Scheduled Task:
- Name: `VLABS_Backup_<JobName>`
- Runs every N hours at specified start time
- Executes `Execute-Backup.ps1 -JobName "<JobName>"`

## Updating

Press `U` from the menu or re-run:
```powershell
iex (irm https://raw.githubusercontent.com/GonzFC/SecureBackups/main/install.ps1)
```

Configuration is preserved (stored in `C:\ProgramData\VLABS_ResilienceRing\`).

## Security

- **SMB Access**: Dedicated `RR_Service` account with deterministic password
- **Transport**: All traffic over Tailscale (WireGuard encrypted)
- **At Rest**: Not encrypted (same legal entity owns all nodes)
- **Credentials**: AES-256 encrypted using machine GUID

---

**Powered by VLABS** | Resilience Ring v1.8.0
