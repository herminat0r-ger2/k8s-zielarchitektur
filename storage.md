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
8. [Anhang: Begriffe & Grundlagen](#anhang-begriffe--grundlagen)

---

## 1. Rahmenbedingungen des Setups

| Komponente | Ausprägung |
|---|---|
| **Cluster** | Proxmox Cluster über 2 Standorte (**Stretched Cluster**) — **kein eigenes Proxmox-Feature**: zulässig, solange die allgemeine Cluster-Anforderung **< 5 ms Latenz zwischen allen Nodes** erfüllt ist (Admin Guide: *"latencies under 5 milliseconds … to operate stably"*; über ~10 ms ab mehr als drei Nodes *"rather unlikely"*). Corosync-Timeouts sind auf die Metro-Latenz abzustimmen, dritte Stimme über **Corosync-QDevice** — Details: [failover.md §8/§9](failover.md) |
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

---

## Anhang: Begriffe & Grundlagen

Kurz erklärt, was die im Dokument verwendeten Storage- und Cluster-Begriffe technisch bedeuten.

### NVMe-oF (NVMe over Fabrics)

**Was es ist.** NVMe ist das Kommando-Protokoll für SSDs — nicht mehr SCSI, sondern für massiv parallele, latenzarme Zugriffe über PCIe gebaut (viele tiefe Queues statt einer). **NVMe-oF** nimmt genau dieses Protokoll und legt es über ein *Netzwerk* statt über PCIe. Für den Host sieht die entfernte SSD aus wie eine lokale NVMe-Namespace (`/dev/nvmeXnY`).

**Transporte** (der Teil nach dem Schrägstrich):

| Transport | Läuft über | Voraussetzung | Charakter |
|---|---|---|---|
| **NVMe/FC** | Fibre-Channel-Fabric | FC-NVMe-fähige HBAs/Ports (Gen 6/7) | Nutzt bestehende SAN-Verkabelung + Zoning, hohe Reife |
| **NVMe/TCP** | Standard-Ethernet (10/25/40/100 GbE) | keine RDMA-Hardware | Einfachste Einführung; etwas mehr CPU-Overhead und Latenz als RDMA |
| **NVMe/RDMA** | RoCEv2 (Ethernet) oder InfiniBand | **verlustfreies** Ethernet (PFC/ECN/DCB) | Niedrigste Latenz und CPU-Last, aber saubere QoS-Konfiguration nötig |

**Warum es im Dokument vorne steht.** Gegenüber iSCSI deutlich weniger Latenz und CPU-Overhead (kein SCSI-über-TCP-Stack) — und Multipath ist **im Kernel eingebaut**: wo iSCSI `dm-multipath` braucht, macht NVMe es selbst (`nvme_core.multipath=Y`; `nvme list-subsys` zeigt die Pfade, `nvme list -v` die Namespaces). Im Proxmox-Setup legt man die LVM-Volume-Group wieder auf das Multipath-Device und markiert den Storage als *shared*.

**Grenze.** Multipath ersetzt kein redundantes SAN-Design: es bündelt nur die Pfade, die physisch existieren → siehe Dual-Fabric.

### Dual-Fabric

**Was es ist.** Ein *Fabric* ist das geswitchte Storage-Netz zwischen Hosts und Storage (FC-Switched-Fabric mit Zoning, oder ein dediziertes Ethernet-Netz). **Dual-Fabric** heißt: **zwei physisch und logisch getrennte Fabrics** — Fabric A und Fabric B, jedes mit eigenen Switches und je einem eigenen Host-Port (HBA/NIC).

**Warum getrennt und nicht einfach zwei Links auf denselben Switch.** Ein einzelner Switch ist ein Single Point of Failure: Firmware-Bug, Config-Fehler, Netzteil oder ein Wartungsfenster treffen sonst **alle** Pfade gleichzeitig — und aus "redundant" wird "gleichzeitig weg". Getrennte Fabrics isolieren die Fehlerdomäne: ein Fabric lässt sich warten, während das andere den I/O trägt.

**Zusammenspiel mit Multipath.** Der Host sieht pro Fabric einen Pfad zu denselben LUNs. Die Multipath-Schicht (bei SCSI/FC/iSCSI `dm-multipath`, bei NVMe-oF der native NVMe-Multipath) bündelt sie zu *einem* Gerät und wählt den aktiven Pfad. Fällt ein Fabric komplett aus (Switch, Kabel, HBA), läuft der I/O über das andere weiter — Path-Failover im Bereich 1–2 s.

**Praxis auf Ethernet.** Zwei unabhängige Switch-Stacks (idealerweise unterschiedliche Modelle/Hersteller, damit nicht derselbe Firmware-Bug doppelt auftritt), duale NICs, getrennte VLANs. Bei RoCE zusätzlich **getrennte PFC/DCB-Domänen** — sonst kann ein Pause-Storm in einem Fabric das andere mitreißen.

**Im Stretched Cluster.** Beide Fabrics spannen über beide Standorte. Pro Fabric ist damit der Metro-Link selbst wieder ein gemeinsamer Punkt — deshalb: dual Fabric **und** je Standort redundante Anbindung planen.

### Corosync-Netz

**Was es ist.** Corosync ist die Cluster-Engine unter Proxmox VE (`pvecm`). Sie hält die Cluster-Mitgliedschaft, verteilt die Konfiguration (`pmxcfs`) und führt die Quorum-Abstimmung. Das **Corosync-Netz** ist das dedizierte Netz, über das diese Heartbeats und Votes laufen.

**Eigenschaften (laut Proxmox-Doku):**

- Geringer Bandbreitenbedarf, aber **Latenz und PPS (Pakete/Sekunde) sind der begrenzende Faktor** → ein dediziertes 1-Gbit-NIC genügt, solange es nur Corosync trägt.
- **UDP-Ports 5405–5412** müssen zwischen allen Nodes offen sein.
- Seit PVE 6 ist **Kronosnet** der Transport (in `pvecm status` als `Transport: knet` sichtbar) — es erlaubt **bis zu 8 Links**. Ein zweiter Link muss auf einem **anderen physischen Netz** liegen; ein einzelner Link, der nur auf einem Bond hängt, ist in bestimmten Fehlerszenarien problematisch.

**Warum strikt getrennt von Storage und Live-Migration.** Die Doku ist hier unmissverständlich: *"Storage communication should never be on the same network as corosync!"* Corosync reagiert empfindlich auf Latenzspitzen. Ein Speicher-Burst oder eine laufende Migration im selben Netz verzögert die Heartbeats; laufen die Timeouts ab, gilt ein Node als **tot** → HA-Aktion/Fencing, obwohl die Hardware völlig gesund ist. Das ist ein selbstgebauter Ausfall durch geteilte Ressource.

**Bezug zum Stretched Cluster.** Über einen Metro-Link ist die Corosync-Latenz (und PPS) der bestimmende Faktor — **nicht** die Node-Zahl: die Doku nennt kein hartes Limit, in Produktion sind > 50 Nodes dokumentiert. Bei Link-Flackern droht der fälschliche Ausschluss eines Standorts. Genau dieses Argument trägt in [`failover.md`](failover.md) §8 die Entscheidung **gegen** einen gestreckten Proxmox-Cluster.

**Zwei-Node-Konstellation.** Für verlässliches Quorum braucht es eine ungerade Stimmenzahl — bei 2 Nodes übernimmt das der **Corosync-QDevice** (3. Vote). Davon zu unterscheiden ist der **externe Witness** aus `failover.md`: keine Quorum-Stimme *innerhalb* eines Clusters, sondern eine eigenständige externe Instanz mit eigener Check-Logik über die getrennten Cluster.

> **Betriebsauflagen im gestreckten Cluster** — Latenz-Budget, Timeout-Formel (`token`/`consensus`) mit den 30/40/45/60-s-Schwellen, Link-Prioritäten und Corosync-QDevice: siehe [`failover.md`](failover.md) **§9**.

### Verwandte Begriffe (Kurzform)

| Begriff | Bedeutung |
|---|---|
| **Multipath** | Mehrere physische Pfade zu derselben LUN, zu *einem* Gerät gebündelt; ein Pfad fällt aus, I/O läuft weiter |
| **Path-Failover** | Umschalten des laufenden I/O auf einen anderen Pfad (Ziel: 1–2 s) |
| **Peer Persistence / Active Peer Persistence** (HPE) | Transparentes Failover zwischen zwei Arrays im Metro-Cluster; *Active* = beide Seiten sind aktiv |
| **Quorum-Witness / Tie-Breaker** | Unabhängige dritte Instanz, die bei einer Trennung entscheidet, wer weitermachen darf |
| **Stretched Cluster** | Ein Cluster über zwei Standorte; die Cluster-Kommunikation läuft über den Metro-Link |
| **Metro-Link** | Die dedizierte Verbindung zwischen den Standorten (Anforderung hier: < 5 ms RTT) |
| **LUN / Namespace** | Die vom Array präsentierte logische Speichereinheit (SCSI: LUN, NVMe: Namespace) |
| **PBS** | Proxmox Backup Server — dedupliziertes, inkrementelles Backup-Ziel (kein Live-Storage) |
