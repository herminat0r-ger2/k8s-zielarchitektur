# Inbetriebnahme-Checkliste: HPE Alletra MP B10000 → Proxmox VE

Run-Book von der Erstinstallation der Arrays bis zur ersten produktiven VM. Ablauf- und
Entscheidungsgrundlagen stehen in [`storage.md`](storage.md) — dieses Dokument ist die
Abhakliste dafür.

**Ziel-Topologie** (siehe [`storage.md`](storage.md) §1 und [`index.html`](index.html)):
drei Proxmox-Cluster — je einer lokal in A und B (standorteigener Storage, kein Sync) und
**ein gestreckter** Cluster über beide Standorte auf dem Alletra-Metro-Paar.

**Zwei LUN-Klassen auf denselben Arrays** (der rote Faden dieser Checkliste):

| Klasse | Versorgt | Replikation |
|---|---|---|
| **lokal-only** | den standorteigenen Proxmox-Cluster A bzw. B | keine — bleibt bei Standortausfall weg |
| **Metro** | den gestreckten Cluster | Peer Persistence, synchron gespiegelt |

> **Konvention:** `- [ ]` = offener Punkt. `<...>` = umgebungsspezifischer Platzhalter.
> Befehle stammen aus der HPE-Doku (B10000 CLI-Referenz, RHEL/Oracle- bzw. ESXi-Implementation-Guide)
> und dem Proxmox VE Admin Guide — am Testsystem verifizieren, bevor sie produktiv laufen.

---

## Phase 0 — Entscheidungen, bevor ein Kabel steckt

- [ ] **Transport je Host festlegen.** Auf der B10000 verfügbar: FC, NVMe-oF/FC, NVMe-oF/TCP, iSCSI. **NVMe/RDMA (RoCE) gibt es nicht.**
- [ ] ⚠️ **Pro Host genau ein NVMe-oF-Transport:** NVMe/TCP und NVMe/FC können **nicht** auf demselben Host koexistieren (auf dem System/der Array schon).
- [ ] iSCSI **kann** auf derselben Array neben NVMe/TCP betrieben werden (*„due to additional slot support"*). Für die Kombination **auf demselben Host** macht die HPE-Doku keine Aussage — und laut Design-Vorlage unten braucht kein Host beide.
- [ ] **Port-Budget prüfen:** FC/NVMe/FC bis **12 Ports/Node**; auf der Ethernet-Seite Ethernet je Adapter **4 Ports** (10/25GbE-4-Port-HBA: ab Werk 2× iSCSI + 2× NVMe/TCP) bzw. **2 Ports** (100GbE-2-Port-OCP: ab Werk 2× iSCSI); ab OS **10.6** bis zu **10 Frontend-Ethernet-Ports** einzeln als iSCSI **oder** NVMe/TCP. Bei vielen Hosts ist die FC-Seite großzügiger — und die Port-Personas trennen die LUN-Klassen portscharf.
- [ ] **LUN-Klassen-Plan** aufschreiben: welche VM/Cluster-Gruppe nutzt lokal-only, welche Metro? Eigene **CPG je Klasse**.
- [ ] **Kapazitätsplan** inkl. Overcommit-Faktor: LUN-Größen (logisch) vs. real verfügbare CPG-Kapazität, plus Reserve für Snapshots.
- [ ] **Netzplan:** Storage-Netz getrennt vom Corosync-Netz (⚠️ *„Storage communication should never be on the same network as corosync"*), MTU-Konzept (Jumbo 9000 oder 1500 — **end-to-end konsistent**), VLANs, Adressen je Array-Node.
- [ ] **Naming-Konvention** festlegen: CPG, Volumes (`<site>-<klasse>-<zweck>`), Host-Definitionen, Host-Gruppen.
- [ ] **Firmware-Ziel:** ≥ **10.5.50** (siehe Phase 1) — **Pflicht-Gate**, sobald ein NVMe-Transport im Spiel ist (FC-NVMe **und** NVMe/TCP; Advisory a00150116).

---

## Design-Vorlage: Protokolle, Ports, CPGs, Host-Sets

> Der Input für Phase 1–5. Sie setzt die **Port-Personas** und die Trennung der LUN-Klassen in eine konkrete Belegung um — und macht den NDSID/NQN-Fallstrick (Phase 4.2) **strukturell** unmöglich, weil sich die Klassen weder Transport noch Ziel-Ports noch Host-Identität teilen.

**Grundprinzip:** *Eine Klasse = ein Protokoll = ein Port-Set = eine Host-Gruppe = eine eigene NQN/IQN = eine eigene CPG.* Dazu die entscheidende Beobachtung: **Jeder Host gehört genau einem Cluster an** — ein Node des standortlokalen Clusters braucht nur die LOCAL-LUNs, ein Node des gestreckten Clusters nur die METRO-LUNs. Damit braucht **kein Host zwei Protokolle**.

### Variante 1 (bevorzugt): Protokoll-Split über die Port-Personas

| | Klasse **LOCAL** (Clusters A / B) | Klasse **METRO** (gestreckter Cluster) |
|---|---|---|
| Protokoll | **iSCSI** | **NVMe/TCP** |
| Array-Ports | 10/25GbE-HBA **Port 1+2** (ab Werk iSCSI) | 10/25GbE-HBA **Port 3+4** (ab Werk NVMe/TCP) |
| Subnetz | eigenes Storage-Netz je Standort | eigenes Storage-Netz |
| Host-Identität | **IQN** je Node (Cluster A bzw. B) | **NQN** je Node (gestreckter Cluster) |
| Host-Set (Array A) | `HG-A-LOCAL` | `HG-A-METRO` (gestreckte Nodes an Standort A) |
| Host-Set (Array B) | `HG-B-LOCAL` | `HG-B-METRO` (gestreckte Nodes an Standort B) |
| CPG (Array A / B) | `CPG-LOCAL-A` / `CPG-LOCAL-B` | `CPG-METRO` (auf **beiden** Arrays) |
| Volume-Namen | `A-local-vmstore-01`, `B-local-vmstore-01` | `metro-vmstore-01`, … |
| Replikation | keine | Peer Persistence, RC-Gruppe **synchron** |
| Proxmox-Storage | Typ `lvm`, **Shared**, `discard=on` | Typ `lvm`, **Shared**, `discard=on` |
| Host-Pfade | `dm-multipath`, 2 Pfade über Port 1+2 | **nativer** NVMe-Multipath über Port 3+4 |

**Metro in der Remote-Copy-Gruppe:** Die Metro-Volumes bilden **eine** RC-Gruppe (Modus synchron); die Host-Sets beider Standorte werden über die `admitrcopy*`-Befehle (`admitrcopyhost`, `admitrcopyvv`) aufgenommen. Nur so sehen die Nodes **beider** Standorte dasselbe Volume — jeweils über ihr **lokales** Array.

*Warum das trägt:* iSCSI und NVMe/TCP dürfen auf derselben Array koexistieren (die Doku nennt ausdrücklich die zusätzliche Slot-Unterstützung), die Klassen laufen aber auf **getrennten Port-Personas**. Ein Host sieht damit nie zwei Subsysteme mit gleicher NDSID — per Konstruktion, nicht per Sorgfalt.

### Variante 2 (Fallback): ein Protokoll für beide Klassen

Wenn alles über dasselbe Protokoll laufen soll (z. B. NVMe/TCP durchgängig, oder iSCSI-only bei Bestückung mit dem 100GbE-2-Port-OCP, dessen beide Ports ab Werk iSCSI sind):

| | LOCAL | METRO |
|---|---|---|
| Ports | Port-Set 1 (10/25GbE Port 1 bzw. 100GbE Port 1) | Port-Set 2 (10/25GbE Port 2 bzw. Port 3+4) |
| VLAN / Subnetz | getrennt | getrennt |
| Host-NQN / IQN | eigene Identität je Klasse | eigene Identität je Klasse |
| Host-Set / CPG | getrennt | getrennt |

- **NVMe/TCP für beide Klassen:** der NQN/NDSID-Fallstrick bleibt relevant → Trennung über Port-Set **und** Host-NQN ist Pflicht, nicht Kosmetik.
- **iSCSI für beide Klassen:** das NDSID/NQN-Problem gibt es nicht (SCSI-Namespace) — die Trennung dient dann der Fehlerdomäne und der Host-Zuordnung.

### Sitzungs-Budget nachrechnen

- **256 Sessions pro Port** (von allen VLANs am Port gemeinsam genutzt), **3072 pro Array** (2 Nodes) / 6144 (4).
- Daumenformel: `Nodes × Pfade pro Port × Reserve ≤ 256`. Beispiel: 12 Nodes × 2 Pfade = 24 → unkritisch.

### Was hier nicht hingehört

- **Kein ZFS** auf einem geteilten LUN (siehe [`storage.md`](storage.md) §4.4).
- **Kein `lvmthin`** für die geteilte Klasse — Thin kommt aus der **CPG** (siehe [`storage.md`](storage.md) §2.5).
- **Boot-Volumes nicht auf diese LUNs:** Boot bleibt lokal; über iSCSI und NVMe/TCP ist SAN-Boot ohnehin nicht unterstützt.
- **PBS nicht auf den Metro-LUN** — eigenes Ziel pro Standort bzw. mit Sync.

---

## Phase 1 — Alletra: Basis, Protokolle, Quorum

### 1.1 Firmware & Lizenzen

- [ ] Firmware-/OS-Stand **beider** Arrays prüfen (CLI: `showversion`; sonst Data Ops Manager / SSMC → Systems).
- [ ] ⚠️ **Ziel ≥ 10.5.50** — behebt das NVMe-Deallocate-Größenlimit (HPE Advisory **a00150116**): ab 10.5.x kündigt die Array max. **32 MB pro Deallocate-Request** an, größere Requests werden abgelehnt und der Platz bleibt *„stranded within the current namespace"* (nutzbar für dieses Volume, **nicht** an andere vergebbar) → schleichend steigende Auslastung.
- [ ] Lizenz für **Remote Copy / Peer Persistence** vorhanden?
- [ ] **Quorum Witness (Tie-Breaker)** für das Metro-Paar planen und platzieren — **nicht** auf einem der Cluster-Nodes, sondern an einem dritten Ort.

### 1.2 Ports & Fabrics

- [ ] FC: HBAs/Ports laut Support-Matrix (SPOCK), **Zoning** beidseitig (Single-Initiator/Single-Target), Fabric-Logins sichtbar (`showport`, Switch `zoneshow`).
- [ ] Ethernet (iSCSI / NVMe/TCP): IPs je Array-Node, **VLAN-Tagging**, Gateway nur wenn nötig.
- [ ] ⚠️ **MTU: 1280–9000 Byte** laut Linux-Implementation-Guide (die ESXi-Anleitung nennt 1500 und 9000) — und **identisch** auf Host-NIC, Switch und Array-Port setzen. Halb konfigurierte Jumbo Frames sind die häufigste stille Bremse.
- [ ] ⚠️ **Port-Personas prüfen:** ab Werk ist gemischt — 10/25GbE-4-Port-HBA = Port 1+2 **iSCSI**, Port 3+4 **NVMe/TCP**; 100GbE-2-Port-OCP = **2× iSCSI**. Ab 10.6 sind alle 10 Frontend-Ports einzeln als iSCSI **oder** NVMe/TCP konfigurierbar (vor 10.6 mit Reboot). Genau hier lässt sich die Trennung der LUN-Klassen **portscharf** umsetzen (Phase 4.2).
- [ ] **DHCP/iSNS werden nicht unterstützt** → alle Storage-Ports fest adressieren.
- [ ] ⚠️ **Auto-Negotiation wird nicht unterstützt** → Switch-Port-**Speed manuell fixieren**, SFP-Speed muss passen.
- [ ] Optional: **PFC/DCBX** (Ethernet-Pause) für NVMe/TCP aktivieren.
- [ ] Ab ArcusOS **10.6**: alle 10 Frontend-Ethernet-Ports einzeln als iSCSI **oder** NVMe/TCP konfigurierbar — Port-Aufteilung danach planen.

### 1.3 CPGs & Host-Definitionen

- [ ] **CPG für `lokal-only`** je Standort anlegen (getrennte Kapazität, damit ein vollgelaufener Pool nicht beide Klassen mitnimmt).
- [ ] **CPG für `Metro`** anlegen (auf beiden Arrays des Paares).
- [ ] **Host-Definitionen** je Host und **je LUN-Klasse** anlegen:
  - FC: WWPNs
  - iSCSI: **IQN** (⚠️ HPE: *„iSCSI presentation model changes to single IQN at array level"*) + CHAP
  - NVMe/TCP: **NQN**
- [ ] ⚠️ **Getrennte Host-NQNs/IQNs bzw. Host-Einträge für die lokale und die Metro-Anbindung** — siehe Phase 4.2 (NDSID-Kollision).
- [ ] **Host-Gruppen/Host-Sets** bilden — je LUN-Klasse eine eigene, damit ein Volume nicht versehentlich beiden Klassen präsentiert wird.
- [ ] Sichtprüfung: `showhost`, `showhostset` (Host-Definitionen) und `showvlun` (Präsentationen).

---

## Phase 2 — LUNs anlegen (Thin) und präsentieren

Pro Volume/Klasse. Thin ist auf der B10000 der **Default** (`tpvv`); Details in [`storage.md`](storage.md) §2.5.1.

- [ ] **Volume anlegen** (TPVV aus der CPG der jeweiligen Klasse):

  ```bash
  # Beispiel: 2 TB dünn, Warnung ab 50 %, hartes Limit bei 75 % der virtuellen Größe
  createvv -tpvv -usr_aw 50 -usr_al 75 <cpg-lokal-a> lokal-a-vmstore 2048g
  ```

- [ ] **Schwellen bewusst setzen** (`-usr_aw`/`-usr_al`): Überschreitung erzeugt die *Thin Provisioning Soft Threshold Reached* Check Condition — das ist die Frühwarnung, bevor der Pool volläuft.
- [ ] Optional **Mindest-Allokationsgröße** (`-minalloc`, MB) — verhindert I/O-Verzögerungen durch Volumenwachstum; die Array alloziert dadurch bewusst mehr als gebraucht (`Tot_Rsvd` > `Used`).
- [ ] Optional **Dedup + Kompression**: `createvv -reduce <cpg> <name> <size>`.
- [ ] **Präsentieren** an die **richtige Host-Gruppe** — Kontrolle mit `showvlun` (Präsentation; HPE nennt den Export „VLUN") sowie `showvv -s -host <host>` (Platzverbrauch je Host, gültige Kombination laut CLI-Referenz).
- [ ] **Boot-Volume bleibt lokal** — das ist eine **Entwurfsentscheidung**, keine Array-Grenze: Über **FC** unterstützt die B10000 SAN-Boot (eigene Prozedur) und Direct Connect (bestimmte Adapter, ab 10.3.0), über **iSCSI und NVMe/TCP** ist beides ausdrücklich **nicht** unterstützt.
- [ ] **CHAP** vorbereiten: uni- und bidirektional möglich, aber **nicht für Discovery-Sessions** — und NVMe/TCP-In-Band-Auth verlangt RHEL ≥ 9.4, also einen Kernel/`nvme-cli` mit In-Band-Auth (auf Proxmox/Debian vorher prüfen).

### 2.1 Metro-Klasse zusätzlich

- [ ] **Peer-Persistence-Paar** bilden: Remote-Copy-Gruppe mit den Metro-Volumes, Modus **synchron**.
- [ ] **Quorum Witness** der Gruppe zuweisen (aus Phase 1.1).
- [ ] Zustand prüfen: `showrcopy` (Status), `showrcopy -d` (detaillierter) und **`showrcopy -qw`** (Peer-Persistence-spezifische Zielkonfiguration) — Gruppe **synchron/aktiv**, kein „stale"/„new" Volume.
- [ ] ⚠️ Kapazität auf **beiden** Arrays gleich planen — gespiegelte Volumes belegen auf beiden Seiten Platz.

---

## Phase 3 — Proxmox: Cluster und Storage-Netz

### 3.1 Cluster

- [ ] Cluster A, Cluster B und den **gestreckten** Cluster aufsetzen (jeweils eigenes Quorum).
- [ ] **Corosync-Netz** separat und redundant (idealerweise 2 Links) — niemals auf dem Storage-Netz.
- [ ] **QDevice** für den gestreckten Cluster installieren (dritte Stimme außerhalb A/B).
- [ ] ⚠️ Corosync-Timeouts an Node-Zahl und Strecke anpassen (Details: [`failover.md`](failover.md) §8/§9).

### 3.2 Storage-Netz & Multipath

- [ ] Dedizierte Storage-NICs/VLANs, MTU wie in Phase 1.2 (konsistent!), getrennt von Management und Corosync.
- [ ] **Getrennte Subnetze je Pfad-Gruppe/Klasse** statt eines gemeinsamen Netzes — das ist die verbreitete Empfehlung der Storage-Hersteller und ersetzt den `arp_filter`-Workaround für mehrere NICs im selben Subnetz.
- [ ] ⚠️ **Multipath statt Bonding.** Multipath ist netzwerk-agnostisch und der bevorzugte Weg; wenn gebondet wird, muss **beide Seiten** (Host und Array/Switch) identisch gebondet sein.
- [ ] **iSCSI-Track:** `iscsid` aktiv; ⚠️ HPE-Empfehlung für Hosts mit **mehreren NICs im selben Subnetz**: `net.ipv4.conf.all.arp_filter=1`.
- [ ] **NVMe/Track:** Modul laden und Multipath sicherstellen:

  ```bash
  echo nvme_tcp > /etc/modules-load.d/nvme_tcp.conf   # bei NVMe/FC nicht nötig
  # nativer Kernel-Multipath (kein multipath-tools):
  grep -r nvme_core.multipath /etc/default/grub /etc/modprobe.d/   # muss auf Y stehen
  ```

- [ ] **FC-Track:** HBA-Treiber/Firmware laut SPOCK, Zoning verifiziert.

---

## Phase 4 — Storage in Proxmox einbinden

### 4.1 Track A — NVMe/TCP (oder NVMe/FC)

Proxmox hat **keinen NVMe-oF-Storage-Typ in der GUI** — die Verbindung entsteht per CLI am Host.

```bash
apt update && apt -y install nvme-cli
modprobe nvme_tcp

nvme discover -t tcp -a <array-node-ip-1> -s 4420
nvme connect  -t tcp -n <nqn> -a <array-node-ip-1> -s 4420
# ... für jeden weiteren Ziel-Port wiederholen (Pfade für Multipath)

nvme list            # -> /dev/nvmeXnY
nvme list-subsys     # je Pfad "live optimized" erwartet
nvme list -v         # NQN, NDSID, Controller, Pfad-Zustand
```

- [ ] **Persistenz über Reboot:** Eintrag in `/etc/nvme/discovery.conf` **+** `systemctl enable --now nvmf-autoconnect.service` (Alternative: `nvme-stas`).
- [ ] Bei **NVMe/FC** entfällt `nvme connect` — hier genügt HBA-Zoning.
- [ ] Reboot-Test: nach Neustart sind **alle** Pfade wieder da (`nvme list-subsys`).

### 4.2 ⚠️ Metro-Paar: NDSID/NQN-Prüfung, bevor VMs umziehen

Genau die Kombination aus dieser Checkliste (zwei LUN-Klassen auf aktiv-aktiv gespiegelten Arrays) hat in einem dokumentierten Proxmox-Fall zum Symptom *„IDs don't match for shared namespace"* geführt: Das zum **Master** promotete Array exponiert auch die **nicht** gespiegelten Volumes des Partner-Arrays — mit **dessen** NQN → **identische NDSID, verschiedene NQN** → der Kernel lehnt das Namespace ab, Volumes sind auf einem Host unsichtbar. `nvme disconnect`/`ns-rescan` hilft nicht.

- [ ] **Beide LUN-Klassen gleichzeitig an EINEM Testhost** verbinden.
- [ ] `nvme list -v` prüfen: kein Volume erscheint zweimal mit unterschiedlicher NQN/gleicher NDSID.
- [ ] Gegenmaßnahmen vorbereitet: **getrennte Ziel-Ports/Port-Sets**, **getrennte Host-Gruppen**, **getrennte Host-NQNs** je Klasse — oder Klassen protokollarisch trennen (lokal über iSCSI/FC, Metro über NVMe-oF).
- [ ] Erst nach grüner Prüfung die VMs umziehen.

### 4.3 Track B — iSCSI

Hier kennt Proxmox das Protokoll selbst (Storage-Typ `iscsi`) — der native Weg:

```bash
apt -y install open-iscsi
pvesm scan iscsi <portal-ip>                 # Ziele am Portal auflisten
pvesm add iscsi <storage-id> --portal <portal-ip> --target <iqn> --content none
```

- [ ] ⚠️ **`content none`** setzen, wenn LVM darüber kommt — sonst könnte PVE ein ganzes LUN direkt an **eine** VM geben (LUN-direkt), und der Shared-Fall wäre kaputt (Doku-Tip zum `iscsi`-Backend).
- [ ] ⚠️ **Nicht `iscsidirect` (User-Mode)** verwenden: dort gilt *zitat: you cannot use LVM on top of such iSCSI LUN*.
- [ ] Der Typ `iscsi` allein kann **keine** Snapshots/Klone, Format nur `raw` → die Verwaltung liegt bei LVM darüber.

Low-Level-Weg (manuelles Setup und Diagnose) über `iscsiadm`:

```bash
iscsiadm -m discovery -t sendtargets -p <array-node-ip>:3260
iscsiadm -m node -l
iscsiadm -m session
multipath -ll                      # alle Pfade active/ready
```

- [ ] **CHAP** konfigurieren (uni- oder bidirektional) und am Array verifizieren: `showiscsisession`, `showiscsisession -d`.
- [ ] `node.startup` auf `automatic`, damit Sessions den Reboot überstehen.
- [ ] ⚠️ Multipath braucht bei iSCSI/FC **`dm-multipath`** (Konfiguration HPE-konform, `no_path_retry`, `polling_interval`, `path_checker`), bei NVMe-oF den **nativen Kernel-Multipath**.

---

## Phase 5 — LVM und die Proxmox-Storage-Definition

```bash
# NUR von EINEM Node aus! (ein geteiltes VG darf nicht mehrfach angelegt werden)
pvcreate /dev/mapper/<mpath-device>
vgcreate vg_metro /dev/mapper/<mpath-device>
```

- [ ] In der PVE-GUI: **Datacenter → Storage → Add → LVM**
  - „Existing volume groups" → `vg_metro`
  - **Nodes: alle** Cluster-Nodes auswählen
  - ⚠️ **„Shared" aktivieren** — sonst ist Live-Migration/HA unmöglich
  - Content: *Disk image* (Snapshots optional); **keine** ISOs/Templates aufs Block-Storage
- [ ] ⚠️ **LVM-thin (`lvmthin`) ist als shared Storage nicht unterstützt** (Proxmox Feature-Matrix: *Shared = no*). Für den gestreckten Cluster: **LVM (thick) auf dem Multipath-Device**, Thin kommt aus der **Array** (§2.5.1).
- [ ] Verifizieren: `pvesm status` zeigt das Storage auf **allen** Nodes als `active`; auf einem Node eine Test-LV anlegen, auf einem anderen sichtbar.
- [ ] Optional die LVM-Property **`base`** setzen (Doku: *volume that is automatically activated before accessing the storage — mostly useful when the LVM volume group resides on a remote iSCSI server*). Genau der Fall bei einem VG auf dem iSCSI-LUN.
- [ ] Zweiten Storage-Eintrag für die **lokal-only**-Klasse (`vg_lokal_a`/`_b`) — **ohne** Shared, nur die Nodes des jeweiligen Clusters.

---

## Phase 6 — Ergänzender Storage

- [ ] **ISO / Templates / Snippets**: NFS vom Alletra File-Service **oder** lokales `Directory` — File-Storage erlaubt alle Content-Typen.
- [ ] **Lokale Pools** (standortgebundene VMs): `zfspool` oder `lvmthin` — ⚠️ **nur lokal**, nicht als shared markieren.
- [ ] **Proxmox Backup Server (PBS)** als eigenes Backup-Ziel, möglichst an beiden Standorten bzw. mit PBS-Sync; **nicht** auf dem Metro-LUN.
- [ ] ⚠️ **ZFS gehört nicht auf einen geteilten LUN** — ZFS ist nicht cluster-aware, ein Pool wäre nur von einem Host importierbar (kein HA/Live-Migration). Siehe [`storage.md`](storage.md) §4.4.

---

## Phase 7 — Erste VM (und der Reclaim-Nachweis)

- [ ] VM anlegen, Disk auf dem **shared LVM**-Storage (`vg_metro`).
- [ ] Controller **virtio-scsi-single** + iothread (Performance), ggf. SSD-Emulation.
- [ ] ⚠️ **Disk-Option `discard` aktivieren.** Ohne sie wächst das dünne LUN nur noch — der Array-Thin-Vorteil verpufft still. (In der GUI: Disk → *Advanced* → *Discard*.)
- [ ] **Im Gast** `fstrim.timer` aktiv lassen (systemd) bzw. das Dateisystem mit `discard`-Mountoption — sonst kommt die Kette nie in Gang:

  ```
  Gast-FS (fstrim/TRIM) → virtio-scsi (discard) → QEMU Discard auf das LV
     → SCSI: UNMAP  |  NVMe: DSM Deallocate  →  Blöcke zurück in die CPG
  ```

- [ ] **Reclaim nachweisen** (Vorher/Nachher, ⚠️ **nicht sofort** — HPE: *„space-reclaim and defrag operations … reclaiming space over an interval of time and **not** after receiving the UNMAP command"*):

  ```bash
  cli% showvv -s <vv>            # Usr Used / %VSize / Tot_Rsvd / Snap  -- vorher
  # im Gast: große Datei schreiben, löschen, fstrim -av
  cli% showvv -s <vv>            # nach einigen Intervallen erneut vergleichen
  ```

- [ ] **Live-Migration** der VM zwischen zwei Nodes testen — der eigentliche Beweis für funktionierenden Shared-Storage.
- [ ] Erste **Snapshot-Kette** (PVE 9: Volume-Chain) testen und danach Reclaim erneut prüfen.

⚠️ **`Used` ≠ `df -k`** im Gast — Fragmentierung und Inode-Tabelle; die Zahlen werden nie identisch (HPE-Doku).

---

## Phase 8 — Abnahme, Failover, Monitoring, Dokumentation

### 8.1 Failover-Tests

- [ ] **Pfad-Failover**: Storage-Kabel/Port ziehen → `multipath -ll` bzw. `nvme list-subsys` prüfen, I/O läuft ohne Unterbrechung weiter.
- [ ] **Site-Trennung** des gestreckten Clusters: Quorum-Witness und QDevice müssen entscheiden; laufende VMs dürfen nicht einfrieren.
- [ ] **Failback** des Metro-Paares testen (Peer Persistence zurück).
- [ ] **Node-Neustart** mit laufenden VMs auf dem shared Storage (Pfade kommen automatisch wieder).

### 8.2 Monitoring

- [ ] **Array-Seite:** `showvv -s` (Usr Used, %VSize, Tot_Rsvd, Snap-Anteil), **CPG-Auslastung**, Snapshot-Platz, Warn-/Limitschwellen (`-usr_aw`/`-usr_al`).
- [ ] ⚠️ Die **Proxmox-Belegung sagt nichts über die Pool-Auslastung** — beide Seiten getrennt überwachen.
- [ ] **Host-Seite:** `pvesm status`, Multipath-/NVMe-Pfadzustand, Storage-Latenz.
- [ ] Bei NVMe/TCP: Deallocate-Verhalten nach mehreren Laufzeittagen erneut prüfen (Advisory a00150116).
- [ ] Alarmierung an den **Agenten** (Alert-Queue), nicht als Nachricht an den Nutzer.

### 8.3 Dokumentation

- [ ] Zuordnung **LUN → CPG → Klasse → Cluster** festhalten.
- [ ] **NQNs / IQNs / WWPNs** je Host und **Port-Sets** dokumentieren.
- [ ] Multipath-Konfiguration und Discovery-Dateien archivieren (`/etc/multipath.conf`, `/etc/nvme/discovery.conf`).
- [ ] Firmware-Stände beider Arrays notieren.

---

## Die sechs harten Regeln auf einer Seite

| # | Regel | Konsequenz bei Verstoß |
|---|---|---|
| 1 | Pro Host **ein** NVMe-oF-Transport (NVMe/TCP und NVMe/FC nie mischen) | Verbindung nicht unterstützt |
| 2 | Beide LUN-Klassen auf **getrennten NDSIDs/NQNs** (eigene Port-Sets, Host-NQNs) | *„IDs don't match for shared namespace"* → Volumes unsichtbar |
| 3 | **`lvmthin` nie als shared** Storage | nicht unterstützt → für den gestreckten Cluster unbrauchbar |
| 4 | **`discard`-Option** auf jeder VM-Disk + fstrim im Gast | dünne LUNs wachsen nur, Array-Vorteil verpufft |
| 5 | Firmware **≥ 10.5.50** bei NVMe-Anbindung | Deallocate-Rejects → „stranded" Platz, Auslastung steigt |
| 6 | Pool-/CPG-Auslastung **getrennt** von Proxmox überwachen | Storage voll → **alle** Gäste bekommen I/O-Fehler, FS-Inkonsistenz möglich |

---

## Anhang: CLI-Befehle und Belegstatus

**Definition:** *belegt* = in der HPE-CLI-Referenz (`sd00002409`, Stand 10.5.50) mit eigener Befehlsseite dokumentiert; die Beispiele stimmen wörtlich mit den hier gezeigten Aufrufen überein.

| Befehl | Zweck | Beleg | Status |
|---|---|---|---|
| `createvv -tpvv -usr_aw <n> -usr_al <n> <cpg> <name> <size>` | Thin-Volume mit Warn- und Limitschwelle | CLI-Ref `createvv` (Beispiel `createvv -tpvv -usr_aw 50 -usr_al 75 cpg1 tpvv1 10G`) | belegt |
| `createvv -tpvv -minalloc <MB> …` | Mindest-Allokationsgröße | CLI-Ref `createvv` (Beispiel `… -minalloc 2048 …`) | belegt |
| `createvv -reduce <cpg> <name> <size>` | Thin + Dedup + Kompression | CLI-Ref `createvv` (Beispiel `createvv -reduce cpg2 vv1 16g`) | belegt |
| `showversion` | Software-/OS-Stand des Arrays | CLI-Ref `showversion` | belegt |
| `showvv -s` (`-space`) | Platzverbrauch je Volume (Usr Used, %VSize, Tot_Rsvd, Snap) | CLI-Ref `showvv`; Beispielausgabe im RHEL-Implementation-Guide | belegt |
| `showvv -s -host <host>` | dito, nach Host gefiltert | CLI-Ref `showvv` (Beispiel `showvv -s -p -prov tp* -host hname`) | belegt |
| `showvlun` | Präsentationen (Export an Host/Host-Set) | CLI-Ref `showvlun` | belegt |
| `showhost`, `showhostset` | Host-Definitionen und Host-Gruppen | CLI-Ref `showhost`, `showhostset` | belegt |
| `showport` | Port-Zustand und Persona | CLI-Ref `showport` | belegt |
| `showiscsisession` (`-d` = Detail) | iSCSI-Sessions am Array | iSCSI Quick Connect (RHEL-Implementation-Guide) | belegt |
| `showrcopy` (`-d` = detaillierter) | Remote-Copy-/Peer-Persistence-Status | CLI-Ref `showrcopy` | belegt |
| `showrcopy -qw` | Peer-Persistence-spezifische Zielkonfiguration | CLI-Ref `showrcopy`, Option `-qw` | belegt |
| `admitrcopyhost`, `admitrcopyvv` | Host-Set bzw. Volume in die RC-Gruppe aufnehmen | CLI-Ref, Abschnitt *Admit Commands* (eigene Befehlsseiten) | belegt |

Nicht in dieser Liste: Proxmox-, Linux- und HPE-**Host**-Befehle (`nvme`, `iscsiadm`, `multipath`, `pvesm`, `pvcreate`, `vgcreate` …) — sie sind an ihrer Stelle im Ablauf belegt.

---

## Quellen

- HPE Alletra Storage MP B10000 — **CLI-Referenz** (`sd00002409`): `createvv`, `showvv`, `showvlun`, `showhost`, `showhostset`, `showport`, `showrcopy`, `showversion` — jeder Aufruf einzeln geprüft (siehe Anhang)
- HPE Alletra Storage MP B10000 — **Port-Limits** (`iSCSI`- und `NVMe/TCP target port limits and specifications`): Port-Personas, 256 Sessions/Port, 3072/6144 Sessions/Array, Boot-from-SAN/Direct-Connect-Status, DHCP/iSNS
- Proxmox-Forum, Thread *„Please help with Proxmox VE 9 Cluster and Alletra B10000 Via iSCSI"* (Sep 2025) — Praxisbezug: mehrere Subnetze, Multipath vs. Bonding, `LVM over iSCSI`; mit Verweis auf die Blockbridge-Notiz zu LVM-Shared-Storage in Proxmox
- HPE Alletra Storage MP B10000 — Implementation Guides (RHEL/Oracle Linux, SLES, VMware ESXi)
- HPE Advisory **a00150116** — Deallocation (Unmap) Issues bei NVMe-Verbindungen, behoben in 10.5.50
- Proxmox VE Admin Guide — Kapitel 7 *Storage* (Storage Types/Feature-Matrix, Thin Provisioning, Trim/Discard)
- Projektkontext: [`storage.md`](storage.md), [`failover.md`](failover.md)
