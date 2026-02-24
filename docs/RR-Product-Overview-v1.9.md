# VLABS Resilience Ring
## Product Overview

**Version:** 1.9 | **Document:** v1.0 | **Audience:** Customer (Decision Maker)

---

## What Is It?

**Resilience Ring** is a distributed backup system that automatically protects your critical data by replicating it across multiple sites — without a central server, without cloud dependency, and without recurring storage fees.

Think of it as a **cooperative backup mesh**: each of your locations backs up to other locations, and receives backups in return. Every piece of data lives in at least 3 places simultaneously.

---

## The Problem It Solves

Traditional backup solutions fail in predictable ways:

| Problem | Traditional Backup | Resilience Ring |
|---------|-------------------|-----------------|
| Single point of failure | Central NAS or cloud | No central point — data lives on peers |
| Ransomware spreads to backups | Mapped drives get encrypted too | Isolated service accounts, no mapped drives |
| Bandwidth costs | Cloud upload on every run | LAN/VPN transfers, no cloud bills |
| Recovery time | Hours to download from cloud | Local LAN speeds |
| Complexity | Agents, licenses, portals | One PowerShell script, no portal needed |

---

## How It Works

Each participating machine (called a **peer**) runs a small background agent. The agent:

1. Backs up your data to **at least 2 remote peer locations** on a schedule
2. Accepts backups from other peers in the ring
3. Enforces retention policies automatically
4. Verifies data integrity via SHA-256 checksums after every transfer

All communication travels over **Tailscale** — an encrypted WireGuard tunnel. No firewall rules, no VPN configuration, no exposed ports.

```
   Office A ──────► Office B
      │    \          /   │
      │     \        /    │
      ▼      ▼      ▼     ▼
   Office C ◄──── Office D

   Every backup exists on at least 2 remote peers
```

---

## Key Features

### 🔄 Automatic Peer Distribution
The system selects backup destinations intelligently:
- Prefers peers with the most available space
- Distributes load evenly across the ring
- Skips unreachable peers and retries automatically
- Minimum 2 remote copies, always

### 📅 Smart Retention Policies
Three retention tiers per backup job:

| Tier | What It Keeps | Example |
|------|---------------|---------|
| **Recent** | Last N runs | Last 2 runs (hourly frequency) |
| **Weekly** | Last N Saturdays | Last 4 Saturdays |
| **Monthly** | Last N end-of-months | Last 3 months |

Old copies are pruned automatically. No manual cleanup required.

### ✅ Integrity Verification
Every backup is verified with SHA-256 checksums after copy. If verification fails, the job is marked as failed and your monitoring system is notified.

### 🌐 NAT Traversal via Tailscale
No port forwarding. No public IPs. Works across offices, home networks, and cloud VMs as long as Tailscale is installed.

### 🔁 Self-Updating
The agent updates itself from GitHub on startup. You set it up once, and it stays current. Your data configuration is preserved through all updates.

### 📊 Centralized Monitoring (optional)
The **Resilience Ring Manager** (RRM) connects to all rings from a single workstation, giving you a live view of:
- All backup jobs across all customers
- Last run time and status per job
- Storage usage per peer
- Backup counts per tier

---

## What It Backs Up

| Type | Description | Use Case |
|------|-------------|----------|
| **File** | Single file, timestamped | Databases, configs |
| **Directory** | Full mirror with incremental sync | Document folders, app data |
| **SQL** | SQL Server backup directory | All SQL Server databases |

---

## Requirements

| Requirement | Detail |
|-------------|--------|
| **OS** | Windows 10/11 or Windows Server 2012 R2+ |
| **Shell** | PowerShell 5.1+ |
| **Network** | Tailscale installed on all peers |
| **Privileges** | Administrator (installation only) |
| **Storage** | Dedicated disk/partition recommended |

---

## Security Model

| Layer | Implementation |
|-------|----------------|
| **Transport** | Tailscale / WireGuard (end-to-end encrypted) |
| **Authentication** | Dedicated `RR_Service` account on each peer |
| **Credential Storage** | AES-256 encrypted, keyed to machine GUID |
| **Access Scope** | Service account can only write to `RR_Backups` share |

Data is **not encrypted at rest** — this is intentional. All nodes belong to the same legal entity (your organization), and encryption at rest would add recovery complexity without meaningful security benefit.

---

## Deployment Model

**Minimum ring:** 3 peers (each backs up to the other 2)
**Recommended:** 4+ peers across different physical locations

Each peer is configured once with:
- A customer code (shared across the ring)
- A location name
- A storage path and quota
- One or more backup jobs

---

## Summary

Resilience Ring is the backup solution for IT teams that want **reliability without complexity** and **distributed protection without cloud dependency**. It runs silently in the background, protects itself from single failures, and gives you a clear operational view from one screen.

---

*VLABS Resilience Ring is developed and maintained by VLABS*
*For setup and support, contact your VLABS representative*
