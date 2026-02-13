# VLABS Resilience Ring - Architecture

*Last updated: 2026-02-13 (v1.9.0 - Master/Transaction separation)*

## Project Goal

**Primary Goal:** Distributed backup system where each site backs up to multiple peer sites automatically, with no single point of failure.

**Business Goal:** Enable VLABS to monitor and invoice customers based on active peers per month.

## Design Principles

### 1. No Single Point of Failure
- Data lives on peers, not a central server
- RRM is just a viewer that queries live data
- Each peer maintains its own state
- Backups exist on at least 2 remote peers

### 2. Separate Master Data from Transaction Data
- **Master Data** (changes rarely): Job definitions, peer configuration
- **Transaction Data** (changes frequently): Run history, status
- Reduces corruption risk from frequent writes

### 3. Self-Updating Architecture
- One-liner install from GitHub
- Auto-update check on startup
- Config stored in ProgramData (survives updates)
- Scripts stored in install directory (replaced on update)

### 4. Pull-Based Discovery
- Peers don't push config to each other
- Discovery via Tailscale tags
- Each peer publishes its status to its own share
- Managers pull status from all peers on demand

## Components

### Resilience Ring Client (RRC)
**Purpose:** Runs on each peer. Manages backup jobs and execution.

**Files:**
- `ResilienceRing.ps1` - Main TUI
- `Execute-Backup.ps1` - Scheduled task executor
- `PeerManagement.ps1` - Peer discovery, storage setup
- `BackupJob.ps1` - Unified job creation workflow
- `VLABS-SecureBackup.ps1` - Legacy functions (being migrated)
- `CryptoUtils.ps1` - AES encryption for credentials

**Data Paths:**
- Install: `C:\VLABS_ResilienceRing\` (scripts, git repo)
- Data: `C:\ProgramData\VLABS_ResilienceRing\` (config, logs)

**Data Files:**
- `ring-config.json` - This peer's configuration
- `jobs.json` - Backup job definitions (MASTER DATA: JobName, BackupType, paths, retention, schedule)
- `jobs-status.json` - Execution history (TRANSACTION DATA: LastRun, LastStatus, LastDurationSeconds, LastSizeBytes)
- `storage-peers.json` - Known peers in the ring

**Why Two Files?** (Design Principle)
The separation of master data from transaction data reduces corruption risk. `jobs.json` is only written when configuration changes. `jobs-status.json` is written after every backup run. If the status file corrupts, configuration is safe.

### Resilience Ring Manager (RRM)
**Purpose:** Multi-ring monitoring and invoicing. Runs from any Tailscale-connected machine.

**Files:**
- `ResilienceRingManager.ps1` - Main TUI
- `install-rrm.ps1` - One-liner installer

**Data Paths:**
- Install: `C:\VLABS_ResilienceRingManager\`
- Data: `C:\ProgramData\VLABS_RRM\`

**Data Files:**
- `rings.json` - Connected rings (local only)

### Shared Storage (per peer)
**Path:** `\\peer\RR_Backups\`

**Structure:**
```
RR_Backups\
├── _nodeinfo\
│   └── jobs-status.json    # Published for RRM to read
├── peer-info.json          # Peer metadata
└── CUSTOMER_CODE\
    └── Location\
        └── Application\
            └── type\
                ├── App-YYYY-MM-monthly\
                ├── App-YYYY-MM-DD-weekly\
                └── App-YYYY-MM-DD-HHMM\
```

## Data Flow

### Backup Execution
```
Windows Scheduled Task
    → Execute-Backup.ps1 -JobName "X"
    → Load job from jobs.json
    → For each PeerDestination:
        → Connect via SMB (RR_Service account)
        → Robocopy with retention policy
        → Verify checksums
    → Update jobs-status.json (transaction data)
    → Publish to _nodeinfo/jobs-status.json
```

### RRM Statistics Query
```
RRM: Show Ring Statistics
    → tailscale status --json (get peers by tag)
    → For each peer:
        → Connect to \\peer\RR_Backups
        → Read _nodeinfo/jobs-status.json
        → Read storage usage
    → Aggregate and display
```

## Security Model

- **Transport:** Tailscale (WireGuard encrypted)
- **SMB Auth:** RR_Service account with deterministic password from CustomerCode
- **Credentials:** AES-256 encrypted using machine GUID
- **At Rest:** Not encrypted (same legal entity owns all nodes)

## Retention Policy

| Type | When Created | Naming |
|------|--------------|--------|
| Monthly | Last day of month | `App-YYYY-MM-monthly` |
| Weekly | Saturdays | `App-YYYY-MM-DD-weekly` |
| Recent | Every run | `App-YYYY-MM-DD-HHMM` |

## Version History

- **v1.8.x** - Unified backup jobs, startup validation
- **v1.7.x** - Separated install/data paths, Tailscale names
- **v1.6.x** - Location field, path structure
- **v1.4.x-1.5.x** - Storage peers with Tailscale tag filtering
- **RRM v1.1.x** - Multi-ring monitoring, job listing

## Known Issues & Lessons Learned

### PowerShell JSON Handling
- `ConvertFrom-Json` + `@()` can produce unexpected results
- `ConvertTo-Json` via pipe can wrap arrays in objects
- Always use `-InputObject` parameter, not piping
- Always verify array contents after loading

### File Corruption Prevention
- Never save in multiple places in same function
- Validate data BEFORE saving, not after
- Log what you're about to save
- Consider backup before overwrite
