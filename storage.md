# Proxmox VE Storage-Lösungen (File- & Block-Level)

**Analyse & Bewertungstabelle für Enterprise-Stretched-Cluster**

---

## Inhaltsverzeichnis

1. [Rahmenbedingungen des Setups](#1-rahmenbedingungen-des-setups)
2. [Alle relevanten Proxmox Storage-Typen](#2-alle-relevanten-proxmox-storage-typen)
3. [Bewertungstabelle Enterprise-Stretched-Cluster](#3-bewertungstabelle-enterprise-stretched-cluster)
4. [Detaillierte Analyse der relevanten Optionen](#4-detaillierte-analyse-der-relevanten-optionen)
5. [Empfohlenes Architektur-Setup](#5-empfohlenes-architektur-setup)
6. [Resilienz-Maßnahmen für Linux-VMs bei Netzwerkfehlern](#6-resilienz-maßnahmen-für-linux-vms-bei-netzwerkfehlern)
7. [Fazit](#7-fazit)

---

## 1. Rahmenbedingungen des Setups

| Komponente | Ausprägung |
|---|---|
| **Cluster** | Proxmox Stretched Cluster über 2 Standorte (< 5 ms RTT) → offiziell unterstützt (Corosync + Quorum-Witness/Tie-Breaker empfohlen) |
| **Primärer Shared Storage** | HPE Alletra MP B10000 als Metro-Cluster (Peer Persistence / Active Peer Persistence). Unterstützt Block (iSCSI, FC, NVMe-oF/FC/TCP) **und** File (NFS) |
| **Backup** | Proxmox Backup Server (PBS) – dediziert, idealerweise an beiden Standorten oder mit Replikation |
| **Kritisch** | Resilienz der Linux-VMs bei Netzwerkfehlern (Pfadausfall, Site-Trennung, Storage-Netz-Probleme). Linux-Gäste profitieren stark von Multipath, Queue-Timeouts und filesystem-seitigen Features (z. B. `nofail`, `x-systemd.device-timeout`) |

---

## 2. Alle relevanten Proxmox Storage-Typen

*Stand ~2026*

### 2.1 Block-Level

> Bevorzugt für VM-Disks.

- LVM / LVM-Thin (lokal oder auf Shared-LUN)
- ZFS (lokal + Replication)
- iSCSI (+ LVM)
- FC / SAS (native + LVM)
- NVMe-oF (FC/TCP) + LVM
- Ceph RBD
- ZFS over iSCSI

### 2.2 File-Level

- Directory (lokal)
- NFS
- CIFS/SMB
- CephFS
- GlusterFS (weniger relevant)
- BTRFS (Tech Preview)

### 2.3 Spezial

- **Proxmox Backup Server (PBS)** – nur für Backups, nicht für Live-VM-Disks

---

## 3. Bewertungstabelle Enterprise-Stretched-Cluster

**Szenario:** HPE Alletra B10000 + PBS

**Bewertungskriterien:** 1–10, höher = besser, unter Berücksichtigung des Szenarios.

| Storage-Typ | Shared / Metro geeignet | Snapshots (Proxmox) | Performance | Komplexität | HA / Live-Migration | Resilienz bei Netzfehlern (Linux-VMs) | PBS-Integration | Gesamt-Eignung Enterprise Stretched | Empfehlung für dein Setup |
|---|---|---|---|---|---|---|---|---|---|
| **iSCSI + LVM (Thick)** | 10 (Alletra nativ) | 4–7 ¹ | 9 | 6 | 10 | **9–10** (Multipath) | 8 | **9.5** | **Primär empfohlen** |
| **NVMe-oF (FC/TCP) + LVM** | 10 | 4–7 ¹ | **10** | 7 | 10 | **10** (natives Multipath) | 8 | **9.7** | **Beste Performance** |
| **FC + LVM** | 10 | 4–7 ¹ | 9.5 | 6 | 10 | **9–10** | 8 | **9.5** | Sehr gut |
| **NFS (Alletra File)** | 9 | 6–8 ² | 7–8 | **3** | 9 | 6–7 (weniger robust bei Path-Fail) | 9 | 7.5 | Gut für ISO/Templates |
| **Ceph RBD** | 8 (eigene Stretch-Mode) | **10** | 8–9 | 8–9 | 10 | 8 (eigene Replikation) | 9 | 7–8 | Nur wenn Hyperconverged |
| **ZFS lokal + Replication** | 3 | **10** | **9–10** | 5 | 4 (async) | 5 (kein Shared) | **10** | 5 | Nur ergänzend |
| **LVM-Thin lokal** | 1 | 9 | 9 | 3 | 1 | 3 | 8 | 3 | Nicht für HA |
| **Directory / CIFS** | 2–7 | 5–7 | 5–7 | 2 | 2–7 | 4–6 | 9 | 4 | Nur ISO/Backup |
| **CephFS** | 8 | 9 | 7 | 8 | 9 | 7 | 8 | 6.5 | Optional File |
| **ZFS over iSCSI** | 9 | **10** | 8 | 8 | 9 | 7–8 | 8 | 7.5 | Möglich, aber komplex |
| **PBS** | ja (Backup) | n/a | – | 3 | n/a | n/a | **10** | n/a | **Obligatorisch** |

**Legende:**

- ¹ Mit neueren Proxmox-Versionen (Volume Chains / qcow2-on-LVM) besser; ansonsten Array-Snapshots (Alletra) nutzen.
- ² qcow2 oder Array-seitige Snapshots.

---

## 4. Detaillierte Analyse der relevanten Optionen

### 4.1 iSCSI / FC / NVMe-oF + LVM auf HPE Alletra B10000 (klare Empfehlung)

- Alletra als Metro-Cluster (Peer Persistence) präsentiert denselben LUN an beiden Standorten mit Transparent Failover.
- Proxmox: LVM Volume Group auf dem Multipath-Device anlegen → als shared Storage markieren.

**Resilienz Linux-VMs:**

- Multipath (`dm-multipath` oder natives NVMe-Multipath) ist entscheidend.
- Path-Failover < 1–2 s möglich.
- Bei Site-Trennung übernimmt die verbleibende Site transparent (Quorum Witness der Alletra).
- Linux-Gäste: `scsi_mod.scan=sync`, angepasste Queue-Timeouts, `nofail` in `fstab` falls Mounts, `multipath-tools` korrekt konfiguriert.

**Vorteile:**

- Sehr hohe Performance
- Echte Shared-Block-Storage
- Live-Migration & HA funktionieren nativ
- Keine zusätzliche Software-Schicht

**Nachteile:**

- Snapshots primär Array-seitig oder über neuere Proxmox-Features (Volume Chains).

### 4.2 NFS von Alletra File-Service

- Einfacher, unterstützt alle Content-Typen (ISO, Templates, qcow2-Disks).
- Resilienz schwächer als Block bei Pfadausfällen (kein echtes Multipath auf File-Ebene). Bei < 5 ms und redundantem Netzwerk trotzdem akzeptabel.
- Gut als ergänzender Storage für ISOs, Templates und ggf. weniger kritische VMs.

### 4.3 Ceph RBD

- Proxmox hat offiziellen Stretch-Mode (`size=4`, `min_size=2`, Tie-Breaker).
- Bei < 5 ms machbar, aber du hast bereits eine teure Enterprise-Array → doppelter Aufwand und Ressourcenverbrauch unnötig.
- Nur sinnvoll, wenn du hyperconverged ohne externe Array willst.

### 4.4 ZFS lokal + Replication

- Exzellente Performance und Datenintegrität, aber **kein** echtes Shared Storage → Live-Migration nur mit Downtime oder nach Replikation.
- Gut als lokaler Cache oder für besonders I/O-intensive VMs + PBS-Replikation.

### 4.5 Proxmox Backup Server

- Ideal als dediziertes Backup-Target (an beiden Standorten oder mit Sync).
- Unterstützt deduplizierte, inkrementelle Backups, Verification, Encryption.
- Kann auf Alletra (NFS oder iSCSI) oder separatem Storage laufen.

---

## 5. Empfohlenes Architektur-Setup

| # | Ebene | Empfehlung |
|---|---|---|
| 1 | **Primär-VM-Storage** | HPE Alletra B10000 über **NVMe-oF (bevorzugt)** oder iSCSI/FC + LVM (shared) |
| 2 | **ISO / Templates / Snippets** | NFS von Alletra oder Directory auf einem der Nodes |
| 3 | **Backup** | PBS (möglichst redundant an beiden Standorten oder mit PBS-Sync) |
| 4 | **Optional** | Lokales ZFS/LVM-Thin für extrem latenzsensitive Workloads + ZFS-Replication oder PBS |
| 5 | **Netzwerk** | • Dediziertes, redundantes Storage-Netz (Multipath / dual Fabric)<br>• Separates Corosync-Netz (idealerweise 2 Links)<br>• < 5 ms RTT ist grünes Licht |

---

## 6. Resilienz-Maßnahmen für Linux-VMs bei Netzwerkfehlern

- Immer Multipath aktivieren und testen (`multipath -ll`).
- Alletra Peer Persistence + Quorum Witness korrekt konfigurieren.
- In den Linux-Gästen: angemessene I/O-Timeouts, `elevator=none` oder `mq-deadline`, kein unnötiges Journaling-Overhead.
- Proxmox HA-Gruppen mit Fencing und korrekten Constraints.
- Regelmäßige Path-Failover- und Site-Trennungstests.
- Monitoring von Multipath-Events und Storage-Latency.

---

## 7. Fazit

Mit der HPE Alletra B10000 als Metro-Storage ist **Block-Storage über NVMe-oF oder iSCSI + LVM** die klar beste und resilienteste Lösung für das Stretched-Cluster.

- **NFS** nur ergänzend.
- **Ceph** wäre Overkill.
- **PBS** als Backup-Schicht ist Pflicht.

> Falls konkrete Konfigurationsbeispiele (`multipath.conf`, LVM-Setup, Alletra Peer Persistence) benötigt werden, können diese ergänzt werden.
