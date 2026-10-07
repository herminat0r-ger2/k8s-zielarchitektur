# Standort-Failover & Split-Brain — Hauptarchitektur

Anforderung, Mechanik und Entscheidungen für die **sofortige Übernahme durch Standort B**.
Dieses Dokument gehört zur Hauptarchitektur (nicht zum Backup-Konzept) — Backup ist das Sicherheitsnetz gegen Datenverlust, **kein Übernahme-Pfad**.

> **Status (revidiert 2026-10-07).** Es gibt **drei** Proxmox-Cluster: je einen eigenständigen in Standort A und in Standort B (lokaler Alletra-Storage, **kein** Sync zwischen den Systemen) **plus** einen **gestreckten** Cluster über beide Standorte auf dem Alletra-Metro-Paar — siehe **§8**.
> Der gestreckte Cluster kommt **zusätzlich** zu den beiden standorteigenen Clustern, nicht statt ihrer. Für ihn ist die dritte Stimme der **Corosync-QDevice** (§9.5); die Abschnitte **§5** und **§7** beschreiben den **externen Witness** als Beobachter über getrennte Cluster — das ist nicht mehr der Steuerungspfad, die Down-Detection-Checkliste bleibt als Monitoring nützlich.
> Die Mechanik von Split-Brain und Failover (§4, §6) gilt unverändert.

## 1. Anforderung (verbindlich)

Standort B übernimmt **immer sofort** — als Hot Standby oder Active/Active. Ein Restore aus dem Backup ist kein Übernahme-Pfad (nur Sicherheitsnetz gegen Datenverlust/Korruption). Konsequenz: **Jede** Datenbank braucht Replikation nach B (**CloudNativePG** für DBs in Kubernetes, Patroni/DB-eigene Replikation für DB-VMs), auch "nur eine Instanz" ohne HA im Normalbetrieb. Unterschied nur Automatisierungsgrad:

| Übernahme | Mechanismus | RTO |
|---|---|---|
| automatisch (Hot Standby) | CloudNativePG / Patroni / Witness-gesteuerter VM-Start | Sekunden–Minuten |
| manuell per Runbook | Replica läuft in B, Promotion per Runbook | Minuten (RTO = Mensch) |

**Topologie (drei Cluster).** In Standort A und B läuft je ein **eigenständiger** Proxmox-Cluster auf dem lokalen Alletra-Storage (kein Storage-Sync zwischen den Systemen); darin lebt je ein Kubernetes-Cluster, dessen DBs per **CloudNativePG** zur Gegenseite replizieren. **Zusätzlich** läuft ein **gestreckter** Proxmox-Cluster über beide Standorte auf dem Alletra-Metro-Paar; er trägt VMs und einen weiteren Kubernetes-Cluster. Die Übernahme-Anforderung oben gilt für **beide** Formen.

## 2. Heutiges Verhalten (vSphere-Stretched-Cluster) als Referenz

vSphere HA startet bei Ausfall von Standort A die VMs auf Hosts in B **neu** (Restart, keine Live-Migration). Daten sind da, weil der Storage synchron gespiegelt ist. **RPO ≈ 0, RTO = Boot + Recovery.** Es ist ein Neustart-Szenario — keine unterbrechungsfreie Übernahme, DBs machen beim Start Crash-Recovery.

## 3. Failover-Ebenen

| Ebene | Mechanismus | Konfiguration |
|---|---|---|
| Node-Failover (Host stirbt) | Proxmox HA (`ha-manager`) | Einstellung, kein Skript |
| Standortausfall, **lokale** Cluster | Der Cluster der Gegenseite läuft unverändert weiter; DB-Promotion per CloudNativePG bzw. Patroni | Runbook — kein Cluster-Failover nötig |
| Standortausfall, **gestreckter** Cluster | Alletra-Metro (Daten liegen synchron im Rest-Standort) + Start der VMs dort | Runbook + Down-Detection, QDevice-Freigabe abwarten |
| Standortausfall, **etcd** des gestreckten K8s-Clusters | etcd-VMs im Rest-Standort starten — bei Disk-Ablage *lokal* nur per Snapshot, bei *Metro-LUN* liegen die Daten bereits vor | Runbook (Ablage: offene Entscheidung) |

## 4. Split-Brain — das Kernproblem

Ohne Quorum weiß B nicht, ob A down ist oder nur der Link A–B. Falscher Automatismus: B startet VMs, obwohl A nach außen weiter funktioniert → beide Standorte schreiben → beim Wiederverbinden überschreibt einer den anderen (Datenverlust).

**Die Storage-Ebene beantwortet das Array, nicht der Cluster.** Das Alletra-Metro-Paar hält den gemeinsamen Speicherzustand; die **array-eigene Quorum-Witness** entscheidet, welches System präsentiert (fail-safe: ohne Bestätigung schreibt nur einer oder keiner). Die **Failover-Entscheidung selbst** (DB-Promotion, VM-Start in B) braucht trotzdem eine unabhängige 3. Instanz — Witness = Quorum = Tie-Breaker, nur auf anderer Ebene.

## 5. Der Witness (3. Instanz) — was er prüft

> Konzept für eine **externe** dritte Instanz. Stand 2026-10-07: Der gestreckte Cluster nutzt dafür den **Corosync-QDevice** (§9.5); die beiden **lokalen** Cluster brauchen keine dritte Instanz, weil ihre Übernahme auf Anwendungsebene läuft (CloudNativePG/Patroni). Die Check-Matrix bleibt als **Monitoring-Checkliste** sinnvoll.

**Der Witness prüft keine Anwendungen, keine einzelnen VMs und nicht "das iLO eines Servers".** Er prüft die Infrastruktur-Ebenen von Standort A, mehrfach, über einen unabhängigen Pfad:

| Ebene | Check |
|---|---|
| Management | Proxmox-Cluster-API erreichbar (HTTPS gegen 2–3 Nodes, nicht eine IP) |
| Storage | Alletra-Metro-Paar erreichbar + Quorum-Witness (Array-API) |
| Netzwerk | Gateway/Router/Leaf-Spine in A (ICMP + API) |
| Hardware (optional) | iLO/BMC mehrerer Nodes (zu eng als einziges Kriterium) |

**Zwei entscheidende Regeln:**

1. **Unabhängiger Pfad:** Der Witness erreicht A über einen Weg, der **nicht durch den A–B-Link** geht (Internet/MPLS/externe Anbindung). Sonst hat er dasselbe Sichtproblem wie B und ist wertlos.
2. **Konsistenz über Zeit und Quellen:** "Down" erst, wenn z. B. 3 von 4 Checks über 30–60 Sekunden stabil fehlschlagen. Ein einzelner Timeout ist Rauschen, kein Standortausfall.

**Bewusst NICHT geprüft:** Die 500 Anwendungen (eine App down ≠ DC down; keine einzelne App repräsentiert ein DC), einzelne VM-IPs, ein einzelnes iLO.

**Abgrenzung:** Der Witness ist **kein Corosync-QDevice** eines gestreckten Proxmox-Clusters (das wäre Voting innerhalb eines Clusters). Er ist eine eigenständige externe Instanz mit eigener Check-Logik, die die getrennten Cluster beobachtet. Gleiches Prinzip, andere Implementierung.

## 6. Drei Regeln für den Failover

1. **Single-Primary:** Nur ein Standort schreibt. B ist Replica (CloudNativePG bzw. Patroni/DB-eigene Replikation) — "beide schreiben" entsteht gar nicht erst.
2. **Quorum/Witness:** Automatischer Failover nur mit Bestätigung durch die 3. Instanz. A lebt + Link down → kein Failover. A wirklich down → B failovert.
3. **Fencing bei Rückkehr:** A kommt nach Failover als Replica zurück (DBs: CloudNativePG/Patroni/DCS machen das automatisch). Legacy-VMs: Spiegel-Richtung umkehren (B → A), sonst überschreibt A den neueren Stand.

## 7. Entscheidung: braucht es eine externe dritte Instanz?

> Diese Abwägung betrifft den **externen Witness** (Beobachter über getrennte Cluster). Stand 2026-10-07: Der gestreckte Cluster nutzt stattdessen den **Corosync-QDevice** (§9.5); für die beiden lokalen Cluster ist keine dritte Instanz nötig — ihre Übernahme regelt CloudNativePG/Patroni.

| Option | Konsequenz |
|---|---|
| **Automatisch** → Witness an Standort C (kleine VM) | RTO automatisch; Witness muss ins Diagramm + betrieben werden |
| **Manuell per Runbook** | kein Witness nötig; RTO = Mensch (Minuten–Stunden) |

Anforderung "B übernimmt sofort" → automatisch → **Witness aufnehmen** (Standort C, inkl. Down-Detection-Check-Matrix aus Abschnitt 5).

## 8. Entscheidung: gestreckter Proxmox-Cluster (revidiert 2026-10-07)

**Entscheidung.** Es gibt **drei** Proxmox-Cluster:

| Cluster | Standort | Storage | Anmerkung |
|---|---|---|---|
| Proxmox-Cluster A | nur A | Alletra A, LUNs *lokal-only* | eigenes Quorum, nicht gestreckt |
| Proxmox-Cluster B | nur B | Alletra B, LUNs *lokal-only* | eigenes Quorum, nicht gestreckt |
| **Gestreckter Cluster** | A + B | Alletra-Metro-Paar (synchron) | VMs **und** ein Kubernetes-Cluster |

Die frühere Fassung dieses Abschnitts ("Warum KEIN gestreckter Proxmox-Cluster") ist damit **überholt** — aber nicht in ihr Gegenteil verkehrt: Der gestreckte Cluster kommt **zusätzlich** zu den beiden standorteigenen Clustern, **nicht statt** ihrer. Die lokalen Cluster tragen die Workloads, die keinen Metro-Storage brauchen; der gestreckte Cluster trägt die, die ihn brauchen.

### 8.1 Warum die frühere Begründung nicht mehr trägt

Die alte Fassung lehnte den gestreckten Cluster unter anderem so ab:

> "Ohne gestrecktes Ceph bringt ein gestreckter Proxmox-Cluster nichts (VM-Disks nicht in B) — und gestrecktes Ceph = Metro-Probleme (Split-Brain im Storage, Tie-Breaker, Blast-Radius, RBD single-writer)."

Diese Prämisse setzt **hyperkonvergentes Ceph als Storage der Proxmox-VM-Disks** voraus. Im Zielbild liegt diese Ebene aber auf einer **externen Array**:

| Annahme der alten Fassung | Tatsächliches Zielbild (Proxmox-VM-Storage) |
|---|---|
| Storage = hyperkonvergentes Ceph, im Cluster verteilt | Storage = externe **HPE Alletra MP B10000**, Metro-Cluster (Peer Persistence) |
| VM-Disks wären ohne gestrecktes Ceph nicht in B | Die Disks sind **ohne Ceph** in beiden Standorten (Array-seitige Metro-Replikation) |
| Storage-Split-Brain / RBD single-writer im Cluster | **Entfällt** — die Array-eigene Quorum-Witness entscheidet, nicht der Cluster |
| "gestreckter Cluster bringt nichts" | **Trifft hier nicht zu** — der Cluster profitiert direkt vom Metro-Storage (Live-Migration und HA über beide Standorte) |

Damit fällt das stärkste Gegenargument weg.

> **Nicht berührt:** Die Anforderung aus §1 bleibt in vollem Umfang bestehen. Die Array-Metro-Replikation ersetzt **nicht** die Replikation auf Anwendungsebene — **CloudNativePG** (Postgres in Kubernetes) bzw. Patroni/DB-eigene Replikation (DB-VMs) bleiben **Pflicht**. Die Alletra macht das Storage hochverfügbar; sie macht eine Datenbank nicht konsistent über zwei Standorte.

### 8.2 Das Node-Skala-Argument ist ein Artefakt des alten Timeouts

Die alte Fassung nannte "16–24 Nodes je Cluster" als konservative Planungsgröße. Diese Zahl war **nicht willkürlich** — sie traf genau den Punkt, an dem die Corosync-Timeouts mit dem damaligen `token_coefficient` von 650 ms die 30-s-Marke reißen (ab 19 Nodes). Seit **Proxmox VE 9.2** bekommen neue Cluster explizit `token_coefficient: 125`; damit verschiebt sich die Grenze auf ~88 Nodes. Formel, Schwellen und Messwerte: **§9.2**.

Das offizielle Node-Limit ist ohnehin keines: *"There's no explicit limit for the number of nodes in a cluster … in practice, the actual possible node count may be limited by the host and network performance"* — in Produktion sind über 50 Nodes dokumentiert.

### 8.3 Verbleibende Risiken und ihre Gegenmaßnahme

| Risiko | Gegenmaßnahme | Wo |
|---|---|---|
| Corosync-Latenz und -Jitter über den Metro-Link | Latenz-Budget < 5 ms einhalten; Timeouts **messen** und austarieren | §9.1–§9.3 |
| Link-Flackern → falscher Ausschluss eines Standorts | Zwei Links auf **getrennten physischen Pfaden**, Prioritäten explizit gesetzt | §9.4 |
| Metro-Link als SPOF für Cluster-Traffic | Redundanter Metro-Pfad; Storage läuft getrennt über die dualen Fabrics | §9.4 |
| Gerade Stimmenzahl bei 2 Standorten → keine Mehrheit bei Trennung | **Corosync-QDevice** (`corosync-qnetd`) am dritten Standort — über TCP/IP, **nicht** an das 5-ms-Budget gebunden | §9.5 |
| Blast-Radius: ein Konfigurationsfehler trifft beide Standorte | Change Control, gestaffelte Rollouts — **nie** beide Standorte gleichzeitig aktualisieren | — |

### 8.4 Was sich für die übrigen Abschnitte ändert

- **§3 (Failover-Ebenen)** gilt unverändert.
- **§4 (Split-Brain)** gilt unverändert — die Storage-Ebene beantwortet jetzt das Array, die Cluster- und Anwendungsebene weiterhin das Quorum.
- **§5 und §7** beschreiben den **externen Witness** als Beobachter über getrennte Cluster. Für den **gestreckten** Cluster ist die dritte Stimme der **Corosync-QDevice** — bewusst ein anderes Konstrukt: eine Quorum-Stimme *innerhalb* eines Clusters. Für die **lokalen** Cluster ist weder Witness noch QDevice nötig: sie haben je ihr eigenes Quorum, und die Übernahme passiert auf Anwendungsebene (CloudNativePG/Patroni).

## 9. Corosync-Betrieb im gestreckten Cluster (Auflagen)

### 9.1 Latenz-Budget

Proxmox VE Administration Guide, *Cluster Network Requirements*:

> "The Proxmox VE cluster stack requires a reliable network with latencies under 5 milliseconds (LAN performance) between all nodes to operate stably. While on setups with a small node count a network with higher latencies *may* work, this is not guaranteed and gets rather unlikely with more than three nodes and latencies above around 10 ms."

Einordnung: Proxmox hat **kein eigenes "Stretched-Cluster"-Feature**. Die 5 ms sind die *allgemeine* Cluster-Anforderung — ein 2-Standort-Cluster ist zulässig, solange er sie erfüllt. Es gibt **keine Zusage für höhere Latenzen**; die 5 ms sind hartes Budget, kein Richtwert. Der Metro-Link ist damit Teil des Corosync-Rings, nicht nur Transportweg für Storage.

### 9.2 Timeout-Formel und Schwellen

Corosync nutzt Token-Passing; die Timeouts skalieren mit der Node-Zahl:

```
token     = 3000 + (number_of_nodes - 2) × token_coefficient   [ms]
consensus = 1.2 × token
```

Die Summe ist die Mindestzeit, bis nach einem Node-Ausfall eine neue Cluster-Mitgliedschaft steht. Die Doku nennt drei Schwellen:

- **> 30 s** — Optimierung empfohlen
- **> 40 s** — empfohlen
- **> 45 s** — **stark** empfohlen (der HA-Watchdog feuert bei **60 s** → Fencing-Risiko für einen *gesunden* Node)

Nach der Formel durchgerechnet:

| Nodes | 650 ms (Default vor PVE 9.2) | **125 ms** (PVE 9.2+) |
|---|---|---|
| 16 | 26,6 s ✓ | 10,4 s ✓ |
| 24 | 38,1 s ⚠️ | 12,7 s ✓ |
| 32 | 49,5 s ❌ | 14,9 s ✓ |
| 64 | 95,3 s ❌ | 23,6 s ✓ |
| **Summe > 30 s ab** | **19** Nodes | **88** Nodes |
| **Summe > 45 s ab** | **29** Nodes | **142** Nodes |

### 9.3 Messen statt schätzen

```bash
corosync-cmapctl | grep -Ew 'runtime.config.totem.token|runtime.config.totem.consensus'
pvecm status      # Transport: knet, Quorum, Expected votes
pvecm nodes
```

**Spannungsfeld im gestreckten Cluster.** Der Koeffizient ist kein Einbahnregler: kleiner = schnellere Mitgliedschaft, aber weniger Toleranz für Latenzspitzen über den Metro-Link; größer = toleranter, aber träger und näher am Watchdog. Über einen Metro-Link mit Jitter ist deshalb **gegen die gemessenen Werte** zu tunen, nicht nach Gefühl — und die Summe muss unter 45 s bleiben.

### 9.4 Links und Prioritäten

- "To provide useful failover, **every link should be on its own physical network connection**."
- **Höhere Zahl = höhere Priorität = aktiv.** Beispiel aus der Doku:
  ```bash
  pvecm create CLUSTERNAME --link0 10.10.10.1,priority=15 --link1 10.20.20.1,priority=20
  # -> link1 wird zuerst benutzt (höhere Priorität)
  ```
  Ohne manuelle Prioritäten gilt die **kleinere** Link-Nummer als höher priorisiert.
- Nur der Link mit der höchsten Priorität trägt Corosync-Traffic; alle anderen sind Standby. **Prioritäten dürfen nicht gemischt werden** — Links mit unterschiedlicher Priorität können nicht miteinander kommunizieren.
- Nützliche Strategie: VM- und Storage-Netze als **niedrigprioritären Fallback**-Link eintragen ("a higher latency or more congested connection might be better than no connection at all").
- Link zu einem **laufenden** Cluster hinzufügen: in `corosync.conf` pro Node ein `ringX_addr` im `nodelist` ergänzen (X für alle Nodes gleich, pro Node eindeutig), dann einen `interface`-Block mit passender `linknumber` im `totem`-Abschnitt.

### 9.5 Dritte Stimme: Corosync-QDevice

> "We support QDevices for clusters with an even number of nodes and recommend it for 2 node clusters."

- **QDevice Net** (`corosync-qnetd`) ist der derzeit einzige unterstützte externe Arbiter. Er gibt seine Stimme **nur einer** Partition — und nur, wenn diese danach wieder Quorum hat.
- **Der entscheidende Vorteil für den gestreckten Cluster:** "Unlike corosync itself, a QDevice connects to the cluster over TCP/IP. The daemon can also run outside the LAN of the cluster and isn't limited to the low latencies requirements of corosync." → Der QDevice darf an einem **dritten Standort über WAN** laufen und unterliegt **nicht** dem 5-ms-Budget aus §9.1.
- Bei **ungerader** Node-Zahl wird der QDevice derzeit **nicht** empfohlen.

### 9.6 Token-Koeffizient ändern

1. Netzwerk gegen die Anforderungen aus §9.1 prüfen (insbesondere Latenz und Jitter).
2. In `/etc/pve/corosync.conf` im `totem`-Abschnitt `token_coefficient: 125` setzen (falls nicht schon explizit vorhanden).
3. **`config_version` erhöhen** — Pflicht, sonst wird die Änderung nicht übernommen.
4. Reload prüfen: `systemctl status corosync`, `journalctl -b -u corosync`; falls nötig `systemctl restart corosync`.
5. "Test your setup thoroughly for stability!"

---

## Quellen (Proxmox-Doku)

- Proxmox VE Administration Guide, Kapitel 5 — *Cluster Manager*: `pvecm_cluster_network_requirements`, `pvecm_redundancy`, `pvecm_changing_token_coefficient`, `_corosync_external_vote_support`
- Proxmox VE Wiki — *Cluster Manager*: Cluster Network, Corosync Redundancy, QDevice
