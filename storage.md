# Proxmox VE Storage-Lösungen (File- & Block-Level)

**Analyse & Bewertungstabelle für Enterprise-Stretched-Cluster**

---

## Inhaltsverzeichnis

1. [Rahmenbedingungen des Setups](#1-rahmenbedingungen-des-setups)
2. [Alle relevanten Proxmox Storage-Typen](#2-alle-relevanten-proxmox-storage-typen) — inkl. [2.4 NVMe-oF im Detail](#24-nvme-of-im-detail--die-transporte) und [2.5 Thin Provisioning](#25-thin-provisioning--auf-welcher-schicht-entsteht-es)
3. [Bewertungstabelle Enterprise-Stretched-Cluster](#3-bewertungstabelle-enterprise-stretched-cluster)
4. [Detaillierte Analyse der relevanten Optionen](#4-detaillierte-analyse-der-relevanten-optionen) — inkl. [4.1.1 Einbindung in Proxmox](#411-einbindung-in-proxmox-ve) und [4.1.2 Metro-Paar-Fallstrick](#412-der-metro-paar-fallstrick)
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

### 2.5 Thin Provisioning — auf welcher Schicht entsteht es?

**Thin Provisioning ist keine Dateisystem-Eigenschaft**, sondern eine Eigenschaft *jeder Schicht* im Pfad. Die Proxmox-Doku formuliert die Regel:

> "All storage types which have the 'Snapshots' feature also support thin provisioning." *(Admin Guide, Thin Provisioning)*

Vier Orte, an denen „dünn" entstehen kann:

| Schicht | Was dort dünn ist | Anmerkung |
|---|---|---|
| **1. Array** | das LUN selbst (Alletra Thin Provisioning) | **Der wichtigste Hebel in diesem Setup** — wirkt unabhängig davon, was der Host darüber macht |
| **2. Volume-Manager im Host** | LVM-**thin**-Pool (dm-thin): Overcommit + Snapshots | ⚠️ **Proxmox führt `lvmthin` ausdrücklich NICHT als shared Storage** (Feature-Matrix: *Shared = no*) → nur für lokale/standortgebundene Pools |
| **3. Datei-Ebene** | qcow2 (immer dünn), Sparse-Dateien auf ext4/XFS/Btrfs/ZFS | gilt für `dir`, `nfs`, `cifs`, `cephfs` |
| **4. Pool-Dateisystem** | ZFS-zvols (dünn, solange ohne Reservierung), Ceph RBD (immer dünn) | ZFS: `refreservation=none` = dünn, `refreservation=<size>` = dick |

**Konsequenz für die geplante Architektur:**

- Auf dem **gemeinsamen Metro-LUN** kommt die Dünnheit aus der **Array** (dünnes LUN). Im Host läuft dann **LVM (thick)** auf dem Multipath-Device und der Storage wird als *shared* markiert — weil `lvmthin` als shared nicht unterstützt wird (siehe [4.1](#41-nvme-of--fc--iscsi--lvm-auf-hpe-alletra-b10000-klare-empfehlung)).
- Für **lokale** Pools (standortgebundene VMs) sind LVM-thin oder ZFS die Thin-Optionen, jeweils mit Snapshots.
- **Overcommit ist ein echtes Risiko:** Läuft der Storage voll, bekommen **alle** Gäste I/O-Fehler und Dateisysteme können inkonsistent werden (Caution-Abschnitt der Doku) → Überprovisionierung nur mit Monitoring und Schwellwerten.

*Quelle: Proxmox VE Admin Guide, Kapitel 7 — Storage Types (Feature-Matrix) und Thin Provisioning.*

#### 2.5.1 Wie die Array selbst dünn macht (HPE Alletra B10000)

**Dünnheit ist eine Eigenschaft des Volumens**, kein Schalter am LUN: ein **TPVV** (*Thin Provisioned Virtual Volume*) wird aus einer **CPG** (*Common Provisioning Group*, ein Pool aus Shared-LDs) versorgt. Auf der B10000 ist **TPVV der Default**; `full` ist die dickere Ausnahme, `-reduce` legt zusätzlich Dedup + Kompression an:

```bash
createvv -tpvv -usr_aw 50 -usr_al 75 cpg1 tpvv1 10G   # thin; Warnung ab 50 %, Limit bei 75 % der VSize
createvv -tpvv -minalloc 2048 cpg2 tpvv1 1g            # Mindest-Allokationsgröße 2 GB
createvv -reduce cpg2 vv1 16g                          # thin + Dedup + Kompression
```

**Platzvergabe:** Der Host sieht die volle *virtuelle* Größe (VSize); physischer Platz kommt **beim ersten Schreiben** aus der CPG, in Allokationsblöcken. Die Array alloziert dabei absichtlich etwas mehr als akut gebraucht wird — HPE nennt als Grund, I/O-Verzögerungen durch Volumen-Wachstum zu vermeiden — deshalb ist `Tot_Rsvd` > `Used`. Beispiel aus der HPE-Doku: VSize 1,5 TB, `Used` 25 GB (1,6 %), `Tot_Rsvd` 29 GB.

**Dem Host sagen, dass es dünn ist:** die Array setzt das **TPE-Bit** (*Thin Provisioning Enabled*) in `READ CAPACITY (16)` — HPE nennt das *TP LUN Reporting*; erst dadurch sendet ein Host überhaupt `UNMAP`. Das Überschreiten der Schwellen meldet sie über die *Thin Provisioning Soft Threshold Reached* Check Condition.

**Reclaim — die Kette muss durchgereicht werden:**

```
Gast-FS (fstrim/TRIM) → virtio-scsi (PVE-Disk-Option discard) → QEMU sendet Discard auf das LV
  → Block-Layer → SCSI: UNMAP   |   NVMe: DSM Deallocate   → Array gibt Blöcke an die CPG zurück
```

Drei Punkte, die dabei überraschen:

- **Es ist nicht sofort.** HPE: *„The space-reclaim and defrag operations automatically throttle and run at different time intervals in the system, reclaiming space over an interval of time and **not** after receiving the `UNMAP` command."* Nach einem großen Löschen steigt die freie Kapazität also **schrittweise** über einen Zeitraum.
- **Bei SCSI ist `WRITE SAME (16)` die bevorzugte Variante** — HPE: *„the preferred command due to guaranteed zeroing of the blocks."*
- **`Used` ≠ `df -k`** im Gast — Fragmentierung und Inode-Tabelle (HPE-Doku explizit).

**⚠️ NVMe-Deallocate: Größen- und Firmwarelimit** (HPE Advisory a00150116): Deallocate über FC-NVMe und NVMe/TCP wird unterstützt. Bis **10.5.x** gab es **kein Limit** für die Request-Größe — Hosts sendeten teils ≥ 2 GB pro Request und liefen in **Timeouts**. Ab 10.5.x kündigt die Array im NVMe-Identify **max. 32 MB pro Deallocate-Request** an; größere Requests werden **abgelehnt**, und der Platz bleibt *„stranded within the current namespace"* — für dieses Volume noch nutzbar, aber **nicht an andere Volumes vergebbar** → schleichend steigende Auslastung. Betroffen war ESXi 7.x/8.x über FC-NVMe/NVMe/TCP (dort manuelle Host-Parameter nötig); **behoben in 10.5.50**. Konsequenz: **Firmware ≥ 10.5.50** fahren und die Reclaim-Wirkung einmal real nachmessen (große Datei schreiben → löschen → `showvv -s` über die nächsten Intervalle beobachten).

**Monitoring:** `showvv -s <VV>` zeigt je Volume `Usr Used`, `%VSize`, `Tot_Rsvd` (real alloziert) und den `Snap`-Anteil. Zu beobachten sind **Volume-`Used`**, die **CPG**-Auslastung und bei Snapshots der Snapshot-Anteil. Die Proxmox-Belegung allein sagt über die Pool-Auslastung **nichts**.

**Host-Schritt in Proxmox:** Auf jeder VM-Disk die **`discard`-Option** setzen (Admin Guide, Trim/Discard: *„You only need to ensure that the Virtual Machines enable the disk discard option."*). Fehlt sie, wächst das dünne LUN nur noch — der Array-Vorteil verpufft still.

**Kontext:** In der bestehenden VMware-Umgebung läuft genau diese Kombination — **TPVV + Metro/Peer Persistence auf Primera** — bereits produktiv. Die Array-Seite ist damit bewährt und die Bedienung ist dieselbe Linie: die B10000-CLI führt die 3PAR/Primera-Befehle und -Rollen weiter (`createvv -tpvv`, `showvv -s`, CPG-Konzepte). Neu ist also **nicht** die Array-Mechanik, sondern der **Host-Pfad**: ESXi schließt die Reclaim-Kette heute selbst (VAAI UNMAP, inkl. der in a00150116 genannten Host-Parameter), unter Proxmox muss sie explizit aufgebaut werden (Gast-TRIM → `discard`-Option → UNMAP/Deallocate).

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
| **Auf der B10000?** | **ja** — 32/64 Gb, bis **12 Ports/Node** | **ja** — Ethernet je Adapter **4 Ports** (10/25GbE-4-Port-HBA: ab Werk 2× iSCSI + 2× NVMe/TCP) bzw. **2 Ports** (100GbE-2-Port-OCP: ab Werk 2× iSCSI); ab OS **10.6** bis zu **10 Frontend-Ethernet-Ports** einzeln als iSCSI **oder** NVMe/TCP | **nein** |

**Warum die Port-Zahlen zählen:** FC bzw. NVMe/FC stellt die Array mit bis zu **12 Ports pro Node** bereit; auf der Ethernet-Seite gilt: Ethernet je Adapter **4 Ports** (10/25GbE-4-Port-HBA: ab Werk 2× iSCSI + 2× NVMe/TCP) bzw. **2 Ports** (100GbE-2-Port-OCP: ab Werk 2× iSCSI); ab OS **10.6** bis zu **10 Frontend-Ethernet-Ports** einzeln als iSCSI **oder** NVMe/TCP. Für Dual-Fabric plus Pfadredundanz über viele Hosts ist die FC-Seite der Array also deutlich großzügiger; auf der Ethernet-Seite müssen die Pfade eingeteilt werden. (Adapter-Bestückung im QuickSpecs prüfen.)

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
| ⚠️ **Port-Personas sind ab Werk gemischt:** 10/25GbE-4-Port-HBA = Port 1+2 **iSCSI**, Port 3+4 **NVMe/TCP**; 100GbE-2-Port-OCP = 2× iSCSI. Ab **10.6** sind alle 10 Frontend-Ethernet-Ports einzeln als iSCSI **oder** NVMe/TCP konfigurierbar (vor 10.6 mit System-Reboot) | die Trennung der LUN-Klassen ist **portscharf** möglich — genau der Hebel für [4.1.2](#412-der-metro-paar-fallstrick) |
| Max. Sessions pro Array: **3072** (2 Nodes) / **6144** (4 Nodes); **256 pro Port**, von allen VLANs auf dem Port gemeinsam genutzt | Planungsgröße — die früher genannten 2048/4096 sind der **alte** Stand vor der Erhöhung |
| Ethernet-MTU: **1280–9000 Byte** (Linux-Guide); die ESXi-Anleitung nennt 1500 und 9000 als unterstützte Werte | Jumbo Frames 9000 möglich — end-to-end konsistent setzen |
| ⚠️ **Boot from SAN und Direct Connect sind protokollabhängig** — über **FC ist beides unterstützt** (SAN-Boot mit eigener Prozedur im HPE-Guide; Direct Connect nur mit bestimmten Host-Adaptern ab 10.3.0, Punkt-zu-Punkt 16/32 Gbps), über **iSCSI und NVMe/TCP ist beides NICHT unterstützt** | Boot-Volumes dieser Architektur bleiben lokal — das ist eine **Entwurfsentscheidung**, keine Array-Grenze |
| DHCP und iSNS werden nicht unterstützt | Storage-Ports fest adressieren |
| Auto-Negotiation wird nicht unterstützt | Switch-Port-Speed manuell fixieren, SFP-Speed muss passen |
| CHAP uni- **und** bidirektional unterstützt — **nicht für Discovery-Sessions**; NVMe/TCP-In-Band-Auth verlangt RHEL ≥ 9.4 (also einen Kernel/`nvme-cli` mit In-Band-Auth) | bei NVMe/TCP-CHAP die Host-Unterstützung vorher prüfen |
| Ethernet-Pause und PFC (DCBX) mit NVMe/TCP unterstützt | Lossless-Option vorhanden |

#### 2.4.3 Bewertung im Kontext dieses Setups
- **NVMe/FC** ist die technisch stärkste Option: HBA-Offload, bis zu 12 Ports/Node auf der Array, hohe Reife. Preis: ein FC-Fabric muss da sein.
- **NVMe/TCP** hat die niedrigste Einstiegshürde (vorhandenes Ethernet), kostet aber Host-CPU, ist auf der Array an die Ethernet-Ports der Adapter gebunden (**2 bzw. 4 Ports**, ab 10.6 bis 10 einzeln konfigurierbar) und trifft mit dem NQN-Fallstrick ([4.1.2](#412-der-metro-paar-fallstrick)) genau die geplante Doppelnutzung der Arrays.
- In der Bewertungstabelle unten sind beide deshalb **getrennt** geführt.

> **Einbindung in Proxmox VE** und die **Pflicht-Vorprüfung** (Metro-Paar-Fallstrick) stehen in der Detailanalyse der empfohlenen Option: [§4.1](#41-nvme-of--fc--iscsi--lvm-auf-hpe-alletra-b10000-klare-empfehlung) — dort auch die Diagnose-Befehle.

---

## 3. Bewertungstabelle Enterprise-Stretched-Cluster

**Szenario:** HPE Alletra B10000 + PBS

**Bewertungskriterien:** 1–10, höher = besser, unter Berücksichtigung des Szenarios.
**Reihenfolge:** absteigend nach *Gesamt-Eignung im Ziel-Szenario* — nicht nach Performance. Betriebsrisiko und Passung zur geplanten **Doppelnutzung der Arrays** (lokale *und* Metro-LUNs auf denselben Systemen) zählen gleichwertig mit. Wo eine Zeile fehlt (etwa „NVMe-oF/RDMA"), bietet die B10000 sie nicht an — siehe [2.4](#24-nvme-of-im-detail--die-transporte).

| Storage-Typ | Shared / Metro geeignet | Snapshots (Proxmox) | Performance | Komplexität | HA / Live-Migration | Resilienz bei Netzfehlern (Linux-VMs) | PBS-Integration | Gesamt-Eignung Enterprise Stretched | Empfehlung für dein Setup |
|---|---|---|---|---|---|---|---|---|---|
| **NVMe-oF/FC + LVM** | 10 | 4–7 ¹ | **10** | 6 | 10 | **10** (natives Multipath) | 8 | **9.7** | **Beste Performance** (HBA-Offload, bis 12 Ports/Node) |
| **iSCSI + LVM (Thick)** | 10 (Alletra nativ) | 4–7 ¹ | 9 | 6 | 10 | **9–10** (Multipath) | 8 | **9.5** | **Primär empfohlen** — robusteste Variante bei zwei LUN-Klassen ⁴ |
| **FC + LVM** | 10 | 4–7 ¹ | 9.5 | 6 | 10 | **9–10** | 8 | **9.5** | Sehr gut |
| **NVMe-oF/TCP + LVM** | 10 | 4–7 ¹ | 9.5 | **5** | 10 | **9.5** (natives Multipath) | 8 | **9.4** | Ohne FC-Fabric — Ethernet, mehr Host-CPU, wenige Array-Ethernet-Ports ³ |
| **NFS (Alletra File)** | 9 | 6–8 ² | 7–8 | **3** | 9 | 6–7 (weniger robust bei Path-Fail) | 9 | 7.5 | Gut für ISO/Templates |
| **ZFS over iSCSI** | 9 | **10** | 8 | 8 | 9 | 7–8 | 8 | 7.5 | Möglich, aber komplex |
| **Ceph RBD** | 8 (eigene Stretch-Mode) | **10** | 8–9 | 8–9 | 10 | 8 (eigene Replikation) | 9 | 7–8 | Nur wenn Hyperconverged |
| **CephFS** | 8 | 9 | 7 | 8 | 9 | 7 | 8 | 6.5 | Optional File |
| **ZFS lokal + Replication** | 3 | **10** | **9–10** | 5 | 4 (async) | 5 (kein Shared) | **10** | 5 | Nur ergänzend |
| **Directory / CIFS** | 2–7 | 5–7 | 5–7 | 2 | 2–7 | 4–6 | 9 | 4 | Nur ISO/Backup |
| **LVM-Thin lokal** | 1 | 9 | 9 | 3 | 1 | 3 | 8 | 3 | Nicht für HA — `lvmthin` ist **kein** shared Storage |
| **ZFS auf Shared-LUN** (NVMe-oF/iSCSI-LUN + `zpool`) | 1 | 10 | **9** | 6 | **1** | 3 | **10** | **2** | **Nein** — ZFS ist nicht cluster-aware, siehe [4.4](#44-zfs-lokal--replication--und-warum-nvme-of--zfs-kein-shared-storage-ist) |
| **PBS** | ja (Backup) | n/a | – | 3 | n/a | n/a | **10** | n/a | **Obligatorisch** |

**Legende:**

- ¹ Mit neueren Proxmox-Versionen (Volume Chains / qcow2-on-LVM) besser; ansonsten Array-Snapshots (Alletra) nutzen.
- ² qcow2 oder Array-seitige Snapshots.
- ³ Ethernet-Seite der Array: Ethernet je Adapter **4 Ports** (10/25GbE-4-Port-HBA: ab Werk 2× iSCSI + 2× NVMe/TCP) bzw. **2 Ports** (100GbE-2-Port-OCP: ab Werk 2× iSCSI); ab OS **10.6** bis zu **10 Frontend-Ethernet-Ports** einzeln als iSCSI **oder** NVMe/TCP — also deutlich weniger als die bis zu 12 FC-Ports/Node. Dazu mehr Host-CPU-Last als FC **und** der NQN-Fallstrick bei zwei LUN-Klassen auf denselben Arrays — siehe [4.1.2](#412-der-metro-paar-fallstrick). **NVMe/RDMA (RoCE) bietet die B10000 nicht.**
- ⁴ **Warum iSCSI (9,5) knapp vor NVMe/TCP (9,4) steht**, obwohl NVMe/TCP die bessere Latenz und nativen Multipath hat: Auf der B10000 teilen sich beide **dieselben Ethernet-Ports der Array** (kein Port-Vorteil zueinander), und der **NQN/NDSID-Fallstrick tritt nur bei NVMe auf** — bei zwei LUN-Klassen auf denselben Arrays ist iSCSI das risikoärmere Protokoll. Wer den Fallstrick sauber löst (getrennte Port-Sets/NQNs, Test nach [4.1.2](#412-der-metro-paar-fallstrick)), fährt mit NVMe/TCP technisch besser. Der Abstand ist bewusst klein — begründete Abwägung, keine Messung.

---

## 4. Detaillierte Analyse der relevanten Optionen

### 4.1 NVMe-oF / FC / iSCSI + LVM auf HPE Alletra B10000 (klare Empfehlung)

- Alletra als Metro-Paar (Peer Persistence) präsentiert denselben LUN an beiden Standorten mit transparentem Failover.
- **Transport bewusst wählen** — auf der B10000 stehen **NVMe/FC** und **NVMe/TCP**, **kein** NVMe/RDMA ([2.4](#24-nvme-of-im-detail--die-transporte)):
  - **NVMe/FC** = technisch stärkste Variante (HBA-Offload, bis 12 Ports/Node, etabliertes Zoning) — braucht ein FC-Fabric.
  - **NVMe/TCP** = nutzt die Ethernet-Infrastruktur, dafür Host-CPU-Last und geteilte Array-Ethernet-Ports (2 bzw. 4 pro Adapter); bei zwei LUN-Klassen auf denselben Arrays ist der NQN-Fallstrick (4.1.2) Pflicht-Prüfpunkt.
  - **iSCSI/FC ohne NVMe** = gleichwertiger Fallback, wenn Kompatibilität wichtiger ist als Latenz.
- Proxmox: **NVMe-oF** per CLI (`nvme-cli`), **iSCSI** über den Storage-Typ `iscsi` ([4.1.1](#411-einbindung-in-proxmox-ve)) → LVM-Volume-Group auf dem Multipath-Device → als **shared** markieren.

#### 4.1.1 Einbindung in Proxmox VE

Zwei Wege — sie unterscheiden sich darin, **ob Proxmox das Protokoll selbst kennt**:

| Transport | Proxmox-Storage-Typ | Wer baut die Verbindung auf? |
|---|---|---|
| **NVMe-oF/FC · NVMe/TCP** | **keiner** — CLI + LVM | `nvme-cli` am Host |
| **iSCSI** | **`iscsi`** (GUI/CLI) | Proxmox (`open-iscsi`) |
| **FC/SAS** | **keiner** — HBA + Zoning + LVM | Kernel/HBA |

In beiden Fällen endet es gleich: LUN bzw. Multipath-Device → **LVM** → Proxmox-Storage als *shared*.

**Track A — NVMe-oF (FC oder TCP):** Proxmox hat hier **keinen** Storage-Typ, die Verbindung entsteht per CLI am Host:

```bash
apt update && apt -y install nvme-cli
modprobe nvme_tcp
echo "nvme_tcp" > /etc/modules-load.d/nvme_tcp.conf
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

**Track B — iSCSI (Open-iSCSI):** hier kennt Proxmox das Protokoll selbst — Storage-Typ `iscsi`.

```bash
apt -y install open-iscsi                    # nicht vorinstalliert
pvesm scan iscsi <portal-ip>                 # Ziele am Portal auflisten
pvesm add iscsi <storage-id> --portal <portal-ip> --target <iqn> --content none
```

- **`content none` ist der entscheidende Teil.** Die Doku empfiehlt es ausdrücklich für den LVM-Fall: *„If you want to use LVM on top of iSCSI, it make sense to set content none. That way it is not possible to create VMs using iSCSI LUNs directly."* Auf `images` gestellt könnte PVE ein ganzes LUN an **eine** VM geben (LUN-direkt, ein LUN pro VM) — genau das, was den Shared-Fall kaputt macht.
- Prinzipiell sagt die Doku dasselbe: *„iSCSI is a block level type storage, and provides no management interface. So it is usually best to **export one big LUN, and setup LVM on top of that LUN**."*
- Der Typ `iscsi` allein kann **keine Snapshots und keine Klone**, Image-Format nur `raw` — deshalb liegt die Verwaltung bei LVM darüber (Shared = *yes*).
- ⚠️ **Nicht `iscsidirect` (User-Mode) verwenden**, wenn LVM darüber soll: *„you cannot use LVM on top of such iSCSI LUN."* Dieses Backend ist nur für den LUN-direkt-Fall gedacht.
- **Multipath:** bei iSCSI über `dm-multipath` (`multipath -ll`), anders als beim nativen NVMe-Multipath.
- **Diagnose:** `iscsiadm -m discovery -t sendtargets -p <ip>:3260`, `iscsiadm -m node -l`, `iscsiadm -m session`; CHAP in der Storage-Definition bzw. im iSCSI-Knoten.
- **LVM-Property `base`** — laut Doku: *„Base volume. This volume is automatically activated before accessing the storage. This is mostly useful when the LVM volume group resides on a remote iSCSI server."* Für ein VG auf einem iSCSI-LUN ist das der passende Hebel.

**Snapshots auf LVM (PVE 9):** Der LVM-`snapshot-as-volume-chain`-Modus (*„vendor-agnostic support for snapshots on any storage system that supports block storage. This includes iSCSI and Fibre Channel-attached SANs"*) verlangt laut Doku **thin-provisioning *und* discard** im Unterbau und ist derzeit eine **Technologie-Vorschau**. → Für Snapshots auf dem Metro-LUN ist deshalb die dünne LUN-Klasse aus der Array die Voraussetzung, nicht nur „nice to have".

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

### 4.4 ZFS lokal + Replication — und warum „NVMe-oF + ZFS" kein Shared Storage ist

- Exzellente Performance und Datenintegrität, aber **kein** echtes Shared Storage → Live-Migration nur mit Downtime oder nach Replikation.
- Gut als lokaler Cache oder für besonders I/O-intensive VMs + PBS-Replikation.
- **„NVMe-oF + ZFS" funktioniert technisch** — `zpool create` auf einem NVMe-oF-Namespace, darüber der Proxmox-Typ `zfspool` — **ist aber kein HA-Storage:** ZFS ist **nicht cluster-aware**. Ein Pool auf einem *geteilten* LUN lässt sich nur von **einem** Host importieren, die anderen sehen ihn nicht. Damit fallen Live-Migration und HA weg; es ist dieselbe Klasse wie „ZFS lokal" (in der Matrix als eigene Zeile „ZFS auf Shared-LUN", Gesamt-Eignung 2).
- Der **einzige von Proxmox unterstützte** „ZFS auf Shared Storage"-Weg ist **ZFS over iSCSI**: Der Pool liegt auf einem *entfernten* ZFS-Host, der zvols exportiert; die Proxmox-Nodes konsumieren nur. Ein Pendant **„ZFS over NVMe-oF" gibt es als Storage-Typ nicht** — man müsste es von Hand bauen (zvol → `nvmet` am ZFS-Host → LVM am Konsumenten) und verlöre die Proxmox-Integration für Snapshots/Klone.
- **Fazit:** ZFS gehört auf **lokale** NVMe (`zfspool`); der **geteilte** Block-Storage bleibt bei LVM auf dem Multipath-Device, mit Snapshots/Thin auf der Array.

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
| 5 | **Netzwerk** | • Dediziertes, redundantes Storage-Netz (Multipath / dual Fabric)<br>• **Multipath statt Bonding** — Multipath ist netzwerk-agnostisch und der bevorzugte Weg; wird gebondet, muss **beide Seiten** identisch gebondet sein<br>• **Getrennte Subnetze** je Pfad-Gruppe bzw. LUN-Klasse (Hersteller-Praxis) — ersetzt den `arp_filter`-Workaround für mehrere NICs im selben Netz<br>• Separates Corosync-Netz (idealerweise 2 Links)<br>• < 5 ms RTT ist grünes Licht |

> **Konkrete Belegung** — welche Klasse auf welchem Protokoll, welcher Port-Persona, mit welcher CPG und welchem Host-Set: siehe **Design-Vorlage** in [`checkliste-storage.md`](checkliste-storage.md).

---

> **Umsetzung:** Die Abhakliste von der Erstinstallation der Arrays bis zur ersten VM — inklusive **Design-Vorlage** (Protokolle, Port-Personas, CPGs, Host-Sets), Protokoll-/Port-Setup, CPG- und TPVV-Anlage, lokale vs. Metro-LUN-Klasse, NVMe/TCP- und iSCSI-Settings, Shared-LVM, `discard`-Nachweis und Failover-Tests — steht in [`checkliste-storage.md`](checkliste-storage.md).

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

**Transporte.** Das Suffix benennt den Transport: **NVMe/FC** (FC-Fabric, HBA-Offload, bis 12 Ports/Node), **NVMe/TCP** (Standard-Ethernet, mehr Host-CPU, teilt die Array-Ethernet-Ports mit iSCSI), **NVMe/RDMA** (RoCEv2/InfiniBand, verlustfreies Ethernet nötig — von der B10000 **nicht** angeboten). Vollständiger Vergleich, die HPE-Randbedingungen und der Metro-Paar-Fallstrick: [2.4](#24-nvme-of-im-detail--die-transporte).

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

### Schichten: LUN, Volume-Manager, Dateisystem

**„LVM" ist kein Dateisystem**, sondern ein **Volume-Manager** (blockbasiert) — im ganzen Dokument ist es so gemeint. Das „+ LVM" in den Block-Optionen bezeichnet den **Proxmox-Storage-Typ** `lvm`/`lvmthin`; Proxmox legt die VM-Disk **roh** in ein Logical Volume, auf der VM-Disk liegt also *kein* Host-Dateisystem. Ein Dateisystem kommt erst bei File-Storages ins Spiel (`dir` mit ext4/XFS, `nfs`, `cifs`, `cephfs`) bzw. als Pool-Dateisystem (`ZFS`, `Btrfs`).

| Schicht | Beispiele | Rolle |
|---|---|---|
| **Fabric** | LUN aus der Array, per iSCSI/FC/NVMe-oF | liefert das Blockgerät |
| **Volume-Manager** | LVM, LVM-thin, ZFS-zpool (`zfspool`), Ceph RBD | zerlegt Blöcke, macht Snapshots und Dünnheit |
| **Dateisystem (Host)** | ext4, XFS, Btrfs, ZFS | nur bei File-Storage |
| **Dateisystem (Gast)** | das Dateisystem **der VM** | liegt im rohen LV oder in der qcow2-Datei |

**Warum die Matrix auf LVM führt:** Bei geteiltem Block-Storage ist LVM der von Proxmox **unterstützte** Weg, ein LUN in einzelne VM-Disks zu zerlegen. Die Doku sagt das explizit: *„With iSCSI, FibreChannel (FC), or SAS block storage as shared storage in a cluster, **LVM is used to split the LUN into virtual disks**"* (Admin Guide, Fußnote zur Storage-Matrix). Die Alternativen (ZFS-Pool, LVM-thin) scheiden für **shared** aus — es ist keine Vorliebe für LVM, sondern eine Support-Grenze.

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
