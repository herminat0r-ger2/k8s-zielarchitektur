# Proxmox VE Storage-Lösungen (File- & Block-Level)

**Analyse & Bewertungstabelle für Enterprise-Stretched-Cluster**

---

## Inhaltsverzeichnis

1. [Rahmenbedingungen des Setups](#1-rahmenbedingungen-des-setups)
2. [Alle relevanten Proxmox Storage-Typen](#2-alle-relevanten-proxmox-storage-typen) — inkl. [2.4 NVMe-oF im Detail](#24-nvme-of-im-detail--die-transporte)
4. [Detaillierte Analyse](#4-detaillierte-analyse-der-relevanten-optionen) — inkl. [4.1.1 Einbindung in Proxmox](#411-einbindung-in-proxmox-ve) und [4.1.2 Metro-Paar-Fallstrick](#412-der-metro-paar-fallstrick)
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
| **Cluster** | Drei Proxmox-Cluster: je einer eigenständig in Standort A und B (lokaler Alletra-Storage, **kein** Sync) **plus** ein **gestreckter** Cluster über beide Standorte. Für den gestreckten gilt: **kein eigenes Proxmox-Feature** — zulässig, solange die allgemeine Cluster-Anforderung **< 5 ms Latenz zwischen allen Nodes** erfüllt ist (Admin Guide: *"latencies under 5 milliseconds … to operate stably"*). Corosync-Timeouts auf die Metro-Latenz abstimmen, dritte Stimme über **Corosync-QDevice** — Details: [failover.md §8/§9](failover.md) |
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
- NVMe-oF + LVM — drei Transporte mit sehr unterschiedlichen Voraussetzungen: **NVMe/FC**, **NVMe/TCP** und **NVMe/RDMA**. Welche möglich sind, bestimmt die Array, nicht der Host → [2.4 NVMe-oF im Detail](#24-nvme-of-im-detail--die-transporte)
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

### 2.4 NVMe-oF im Detail — die Transporte

**Der entscheidende Punkt zuerst:** NVMe-oF ist *ein* Protokoll mit mehreren Transport-Bindings — welche man nutzen kann, entscheidet **die Array**, nicht der Host. Für die HPE Alletra Storage MP B10000 sind laut HPE-QuickSpecs **Fibre Channel, NVMe-oF/FC, NVMe-oF/TCP und iSCSI** dokumentiert. **NVMe/RDMA (RoCE) ist nicht dabei.** Die Wahl reduziert sich in diesem Setup also real auf **NVMe/FC vs. NVMe/TCP** (iSCSI als Fallback).

#### 2.4.1 Die drei Transporte im Vergleich

| | **NVMe/FC** | **NVMe/TCP** | **NVMe/RDMA** |
|---|---|---|---|
| Fabrik | Fibre Channel | Ethernet (TCP/IP) | RoCEv2 / InfiniBand |
| Standard | NVMe-oF 1.0, FC-NVMe | NVMe-oF TCP (ab NVMe 1.4) | NVMe-oF 1.0 |
| Host-Hardware | FC-HBA mit NVMe/FC-Firmware | normale NIC, kein RDMA nötig | RDMA-fähige NIC (RoCE/iWARP) |
| Host-CPU-Last | niedrig (HBA offloadet) | höher (Kapselung im Host-Stack) | am niedrigsten |
| Switch-Anforderung | FC-Switches + Zoning | bestehende Ethernet-Switches | **verlustfreies** Ethernet (PFC/ECN/DCB) |
| MTU-Thema | keins (FC rahmt selbst) | relevant — Array kann 1280–9000 Byte | relevant (PFC) |
| Multipath | nativ im Kernel | nativ im Kernel | nativ im Kernel |
| Reifegrad | hoch (SAN-Welt, Zoning-/HBA-Tools) | jünger, aber produktionsreif | hoch, aber sehr tuning-intensiv |
| **Auf der B10000?** | **ja** — 32/64 Gb, bis **12 Ports/Node** | **ja** — 10/25 GbE und 100 GbE, **0–2 Ports/Node** | **nein** |

**Warum die Port-Zahlen zählen:** Die Alletra bietet FC bzw. NVMe/FC bis zu **12 Ports pro Node**, Ethernet (iSCSI oder NVMe/TCP) dagegen nur **0–2 Ports pro Node** (10/25 GbE bzw. 100 GbE). Für Dual-Fabric plus Pfadredundanz über viele Hosts ist die FC-Seite der Array also deutlich großzügiger; auf der Ethernet-Seite müssen die Pfade eingeteilt werden. (Zahlen sind modellabhängig — im QuickSpecs nachsehen.)

**Entscheidungsregel:**

- **NVMe/FC**, wenn ein FC-Fabric samt HBAs vorhanden ist oder beschafft wird: geringste Host-CPU-Last, die meisten Array-Ports, etabliertes Zoning und Management.
- **NVMe/TCP**, wenn die Ethernet-Infrastruktur genutzt werden soll: kein FC-Switch, kein HBA, Kabel und VLANs wiederverwenden — dafür mehr Host-CPU, wenige Array-Ports und der Fallstrick aus 2.4.4.
- **iSCSI**, wenn maximale Kompatibilität gefragt ist: ältester und ruhigster Stack, aber mehr Overhead und `dm-multipath` statt nativem Multipath.
- **NVMe/RDMA** scheidet hier aus, weil die B10000 es nicht anbietet.

#### 2.4.2 Harte Randbedingungen der B10000 (HPE-Implementation-Guide)

| Regel | Konsequenz für die Planung |
|---|---|
| NVMe/TCP **kann** mit FC und/oder NVMe/FC **auf dem System** koexistieren | beide Welten auf einer Array möglich |
| NVMe/TCP **kann NICHT mit NVMe/FC auf demselben Host** koexistieren | pro Host **einen** NVMe-oF-Transport wählen — nicht mischen |
| NVMe/TCP und iSCSI können auf **derselben** Array koexistieren (zusätzliche Slots) | iSCSI als Zweitprotokoll möglich — pro Host aber nicht mischen |
| Max. Sessions pro Array: **2048** (2 Nodes) / **4096** (4 Nodes) | Planungsgröße für die Host-Anzahl |
| Ethernet-MTU: **1280–9000 Byte** | Jumbo Frames 9000 werden unterstützt |
| Kein Boot from SAN, kein Direct Connect, kein DHCP | Boot-Volume bleibt lokal |
| Auto-Negotiation wird nicht unterstützt | Switch-Port-Speed manuell fixieren, SFP-Speed muss passen |
| Ethernet-Pause und PFC (DCBX) mit NVMe/TCP unterstützt | Lossless-Option vorhanden |
| Ab ArcusOS 10.6: alle 10 Frontend-Ethernet-Ports einzeln als iSCSI **oder** NVMe/TCP konfigurierbar | flexiblere Port-Planung |

#### 2.4.3 Bewertung im Kontext dieses Setups
- **NVMe/FC** ist die technisch stärkste Option: HBA-Offload, bis zu 12 Ports/Node auf der Array, hohe Reife. Preis: ein FC-Fabric muss da sein.
- **NVMe/TCP** hat die niedrigste Einstiegshürde (vorhandenes Ethernet), kostet aber Host-CPU, ist auf der Array auf 0–2 Ethernet-Ports/Node begrenzt und trifft mit dem NQN-Fallstrick ([4.1.2](#412-der-metro-paar-fallstrick)) genau die geplante Doppelnutzung der Arrays.
- In der Bewertungstabelle unten sind beide deshalb **getrennt** geführt.

> **Einbindung in Proxmox VE** und die **Pflicht-Vorprüfung** (Metro-Paar-Fallstrick) stehen in der Detailanalyse der empfohlenen Option: [§4.1](#41-nvme-of--fc--iscsi--lvm-auf-hpe-alletra-b10000-klare-empfehlung) — dort auch die Diagnose-Befehle.

---

## 3. Bewertungstabelle Enterprise-Stretched-Cluster

**Szenario:** HPE Alletra B10000 + PBS

**Bewertungskriterien:** 1–10, höher = besser, unter Berücksichtigung des Szenarios.

| Storage-Typ | Shared / Metro geeignet | Snapshots (Proxmox) | Performance | Komplexität | HA / Live-Migration | Resilienz bei Netzfehlern (Linux-VMs) | PBS-Integration | Gesamt-Eignung Enterprise Stretched | Empfehlung für dein Setup |
|---|---|---|---|---|---|---|---|---|---|
| **iSCSI + LVM (Thick)** | 10 (Alletra nativ) | 4–7 ¹ | 9 | 6 | 10 | **9–10** (Multipath) | 8 | **9.5** | **Primär empfohlen** |
| **NVMe-oF/FC + LVM** | 10 | 4–7 ¹ | **10** | 6 | 10 | **10** (natives Multipath) | 8 | **9.7** | **Beste Performance** (HBA-Offload, bis 12 Ports/Node) |
| **NVMe-oF/TCP + LVM** | 10 | 4–7 ¹ | 9.5 | **5** | 10 | **9.5** (natives Multipath) | 8 | **9.4** | Ohne FC-Fabric — Ethernet, mehr Host-CPU, 0–2 Ports/Node ³ |
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
- ³ Nur 0–2 Ethernet-Host-Ports pro Node (10/25 GbE bzw. 100 GbE), mehr Host-CPU-Last als FC **und** der NQN-Fallstrick bei zwei LUN-Klassen auf denselben Arrays — siehe [4.1.2](#412-der-metro-paar-fallstrick). **NVMe/RDMA (RoCE) bietet die B10000 nicht.**

---

## 4. Detaillierte Analyse der relevanten Optionen

### 4.1 NVMe-oF / FC / iSCSI + LVM auf HPE Alletra B10000 (klare Empfehlung)

- Alletra als Metro-Paar (Peer Persistence) präsentiert denselben LUN an beiden Standorten mit transparentem Failover.
- **Transport bewusst wählen** — auf der B10000 stehen **NVMe/FC** und **NVMe/TCP**, **kein** NVMe/RDMA ([2.4](#24-nvme-of-im-detail--die-transporte)):
  - **NVMe/FC** = technisch stärkste Variante (HBA-Offload, bis 12 Ports/Node, etabliertes Zoning) — braucht ein FC-Fabric.
  - **NVMe/TCP** = nutzt die Ethernet-Infrastruktur, dafür Host-CPU-Last und nur 0–2 Ethernet-Ports/Node; bei zwei LUN-Klassen auf denselben Arrays ist der NQN-Fallstrick (4.1.2) Pflicht-Prüfpunkt.
  - **iSCSI/FC ohne NVMe** = gleichwertiger Fallback, wenn Kompatibilität wichtiger ist als Latenz.
- Proxmox: Anbindung per CLI (`nvme-cli`, `nvme discover`/`connect`) → LVM-Volume-Group auf dem Multipath-Device → als **shared** markieren — Anleitung und Diagnose: [4.1.1](#411-einbindung-in-proxmox-ve).

#### 4.1.1 Einbindung in Proxmox VE

Die Verbindung wird **am Host** aufgebaut (kein Storage-Typ in der GUI), danach wird das Device als LVM eingetragen:

Proxmox hat **keinen NVMe-oF-Storage-Typ in der GUI** — die Verbindung wird per CLI am Host aufgebaut, danach wird das Device als **LVM (shared)** eingetragen:

```bash
apt update && apt -y install nvme-cli
modprobe nvme_tcp
echo "nvme_tcp" > /etc/modules-load.d/nvme_tcp.conf     # RDMA: Modul nvme_rdma
nvme discover -t tcp -a <array-ip> -s 4420
nvme connect  -t tcp -n <nqn> -a <array-ip> -s 4420
nvme list                       # -> /dev/nvmeXnY
vgcreate <vg> /dev/nvmeXnY      # von EINEM Host
# dann in der PVE-GUI: LVM-Storage, "Existing volume groups", Nodes wählen, "Shared" markieren
```

**Persistenz über Reboot:** Eintrag in `/etc/nvme/discovery.conf` + `systemctl enable nvmf-autoconnect.service` (Alternative: `nvme-stas` als Connection-Manager). Bei **NVMe/FC** genügt HBA-Zoning — kein `nvme connect` nötig.

**Prüfen — die vier Befehle, die man im Fehlerfall braucht:**

```bash
nvme list              # Namespaces
nvme list-subsys       # Pfade je Subsystem (Multipath-Status)
nvme list -v           # NQN, NDSID, Controller, Pfad-Zustand
dmesg | grep -i nvme   # z. B. "IDs don't match for shared namespace"
```

#### 4.1.2 Der Metro-Paar-Fallstrick

> ⚠️ **Pflicht-Vorprüfung vor dem Produktivstart:** beide LUN-Klassen gleichzeitig an einem Testhost hochziehen und `nvme list -v` prüfen. Tauchen dort zwei Subsysteme mit gleicher NDSID auf, ist das vor dem VM-Umzug zu lösen.

Ein Proxmox-Forum-Fall (PVE 9.2, **zwei aktiv-aktiv gespiegelte HPE-Alletra-Arrays**, NVMe/TCP mit nativem Kernel-Multipath) beschreibt einen Fehler, der **exakt** zu einer Array mit zwei LUN-Klassen passt — wie sie hier geplant ist (*lokal-only* **und** *Metro* auf denselben Systemen):

- **Symptom:** Nach einem Reboot waren einige shared Volumes auf **einem** Host nicht mehr sichtbar. Im `dmesg` stand *„IDs don't match for shared namespace"*, obwohl alle Subsysteme verbunden waren. `nvme disconnect all`, `nvme discover` und `nvme ns-rescan` halfen nicht.
- **Ursache:** Das zum **Master** promovierte Array exponiert bei gespiegelten Volumes alle Pfade mit **seinem** NQN — genau damit Clients dasselbe Volume sehen, egal über welches Array sie zugreifen. Es exponierte dabei aber **auch die nicht gespiegelten Volumes** des Partner-Arrays, und die kamen von dort mit **deren** NQN → **identische NDSIDs, unterschiedliche NQNs** → der Kernel lehnt das Namespace ab.
- **Konsequenz für die Planung:** Die beiden LUN-Klassen dürfen sich auf **Namespace-/Subsystem-Ebene** nicht in die Quere kommen:
  - **Getrennte Ports/Port-Sets und Host-Gruppen** je Klasse — nicht alles über dieselben Ziel-Ports präsentieren.
  - **Getrennte Host-NQNs** für die lokale und die Metro-Anbindung, damit der Host nicht zwei Subsysteme mit gleicher NDSID sieht.
  - **Alternativ die Klassen trennen:** lokal-only über iSCSI/FC, Metro über NVMe-oF (oder umgekehrt) — die Kombination NVMe/TCP + iSCSI **auf der Array** ist laut HPE erlaubt, auf demselben **Host** nicht.

**Resilienz Linux-VMs:**

- Multipath ist entscheidend — bei NVMe-oF **nativ im Kernel** (`nvme_core.multipath=Y`), bei iSCSI/FC über `dm-multipath`.
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
| 1 | **Primär-VM-Storage** | HPE Alletra B10000 über **NVMe-oF** — Transport nach Fabric wählen ([2.4](#24-nvme-of-im-detail--die-transporte)): **NVMe/FC** bei vorhandenem SAN, sonst **NVMe/TCP**; iSCSI/FC + LVM als gleichwertiger Fallback. Einbindung: [4.1.1](#411-einbindung-in-proxmox-ve), **Vorprüfung NQN/NDSID: [4.1.2](#412-der-metro-paar-fallstrick)** |
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

**Transporte.** Das Suffix benennt den Transport: **NVMe/FC** (FC-Fabric, HBA-Offload, bis 12 Ports/Node), **NVMe/TCP** (Standard-Ethernet, mehr Host-CPU, 0–2 Ethernet-Ports/Node), **NVMe/RDMA** (RoCEv2/InfiniBand, verlustfreies Ethernet nötig — von der B10000 **nicht** angeboten). Vollständiger Vergleich, die HPE-Randbedingungen und der Metro-Paar-Fallstrick: [2.4](#24-nvme-of-im-detail--die-transporte).

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

**Bezug zum Stretched Cluster.** Über einen Metro-Link ist die Corosync-Latenz (und PPS) der bestimmende Faktor — **nicht** die Node-Zahl: die Doku nennt kein hartes Limit, in Produktion sind > 50 Nodes dokumentiert. Bei Link-Flackern droht der fälschliche Ausschluss eines Standorts. Genau dieses Argument ist in [`failover.md`](failover.md) §8/§9 die Grundlage der **Auflagen** für den gestreckten Cluster: Latenz-Budget < 5 ms, gemessene Timeouts und der QDevice als dritte Stimme.

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
