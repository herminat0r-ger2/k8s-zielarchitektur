# Standort-Failover & Split-Brain — Hauptarchitektur

Anforderung, Mechanik und Entscheidungen für die **sofortige Übernahme durch Standort B**.
Dieses Dokument gehört zur Hauptarchitektur (nicht zum Backup-Konzept) — Backup ist das Sicherheitsnetz gegen Datenverlust, **kein Übernahme-Pfad**.

## 1. Anforderung (verbindlich)

Standort B übernimmt **immer sofort** — als Hot Standby oder Active/Active. Ein Restore aus dem Backup ist kein Übernahme-Pfad (nur Sicherheitsnetz gegen Datenverlust/Korruption). Konsequenz: **Jede** Datenbank braucht Replikation nach B (Patroni/DB-eigene Replikation), auch "nur eine Instanz" ohne HA im Normalbetrieb. Unterschied nur Automatisierungsgrad:

| Übernahme | Mechanismus | RTO |
|---|---|---|
| automatisch (Hot Standby) | Patroni / DB-Operator / Witness-gesteuerter VM-Start | Sekunden–Minuten |
| manuell per Runbook | Replica läuft in B, Promotion per Runbook | Minuten (RTO = Mensch) |

## 2. Heutiges Verhalten (vSphere-Stretched-Cluster) als Referenz

vSphere HA startet bei Ausfall von Standort A die VMs auf Hosts in B **neu** (Restart, keine Live-Migration). Daten sind da, weil der Storage synchron gespiegelt ist. **RPO ≈ 0, RTO = Boot + Recovery.** Es ist ein Neustart-Szenario — keine unterbrechungsfreie Übernahme, DBs machen beim Start Crash-Recovery.

## 3. Zwei Failover-Ebenen

| Ebene | Mechanismus | Konfiguration |
|---|---|---|
| Node-Failover (Host in A stirbt) | Proxmox HA (`ha-manager`) | Einstellung, kein Skript |
| Standort-Failover (ganzes DC A down) | RBD-Mirror (Daten in B) + Start der VMs in B | Failover-Skript/Runbook + Down-Detection nötig |

## 4. Split-Brain — das Kernproblem

Ohne Quorum weiß B nicht, ob A down ist oder nur der Link A–B. Falscher Automatismus: B startet VMs, obwohl A nach außen weiter funktioniert → beide Standorte schreiben → beim Wiederverbinden überschreibt einer den anderen (Datenverlust).

**Lokaler Ceph vermeidet nur das Storage-Split-Brain** (kein gemeinsamer Speicherzustand über die DCs; fail-safe: ohne Quorum schreibt nur einer oder keiner). Die **Failover-Entscheidung selbst** (DB-Promotion, VM-Start in B) braucht trotzdem eine unabhängige 3. Instanz — Witness = Quorum = Tie-Breaker, nur auf anderer Ebene.

## 5. Der Witness (3. Instanz) — was er prüft

**Der Witness prüft keine Anwendungen, keine einzelnen VMs und nicht "das iLO eines Servers".** Er prüft die Infrastruktur-Ebenen von Standort A, mehrfach, über einen unabhängigen Pfad:

| Ebene | Check |
|---|---|
| Management | Proxmox-Cluster-API erreichbar (HTTPS gegen 2–3 Nodes, nicht eine IP) |
| Storage | Ceph-Cluster-A Health (Monitore/Manager via API) |
| Netzwerk | Gateway/Router/Leaf-Spine in A (ICMP + API) |
| Hardware (optional) | iLO/BMC mehrerer Nodes (zu eng als einziges Kriterium) |

**Zwei entscheidende Regeln:**

1. **Unabhängiger Pfad:** Der Witness erreicht A über einen Weg, der **nicht durch den A–B-Link** geht (Internet/MPLS/externe Anbindung). Sonst hat er dasselbe Sichtproblem wie B und ist wertlos.
2. **Konsistenz über Zeit und Quellen:** "Down" erst, wenn z. B. 3 von 4 Checks über 30–60 Sekunden stabil fehlschlagen. Ein einzelner Timeout ist Rauschen, kein Standortausfall.

**Bewusst NICHT geprüft:** Die 500 Anwendungen (eine App down ≠ DC down; keine einzelne App repräsentiert ein DC), einzelne VM-IPs, ein einzelnes iLO.

**Abgrenzung:** Der Witness ist **kein Corosync-QDevice** eines gestreckten Proxmox-Clusters (das wäre Voting innerhalb eines Clusters). Er ist eine eigenständige externe Instanz mit eigener Check-Logik, die die getrennten Cluster beobachtet. Gleiches Prinzip, andere Implementierung.

## 6. Drei Regeln für den Failover

1. **Single-Primary:** Nur ein Standort schreibt. B ist Replica (Patroni/DB-eigene Replikation) — "beide schreiben" entsteht gar nicht erst.
2. **Quorum/Witness:** Automatischer Failover nur mit Bestätigung durch die 3. Instanz. A lebt + Link down → kein Failover. A wirklich down → B failovert.
3. **Fencing bei Rückkehr:** A kommt nach Failover als Replica zurück (DBs: Patroni/DCS macht das automatisch). Legacy-VMs: Spiegel-Richtung umkehren (B → A), sonst überschreibt A den neueren Stand.

## 7. Entscheidung (offen — gehört in die Zielarchitektur)

| Option | Konsequenz |
|---|---|
| **Automatisch** → Witness an Standort C (kleine VM) | RTO automatisch; Witness muss ins Diagramm + betrieben werden |
| **Manuell per Runbook** | kein Witness nötig; RTO = Mensch (Minuten–Stunden) |

Anforderung "B übernimmt sofort" → automatisch → **Witness aufnehmen** (Standort C, inkl. Down-Detection-Check-Matrix aus Abschnitt 5).

## 8. Warum KEIN gestreckter Proxmox-Cluster

- **Corosync-Latenz über den Metro-Link:** Die offizielle Doku nennt **kein hartes Node-Limit** ("no explicit limit", Praxis 50+ Nodes möglich) — der begrenzende Faktor ist **Corosync-PPS/Latenz**. Ein gestreckter Cluster müsste die Cluster-Kommunikation über den Metro-Link laufen lassen (höhere Latenz als LAN) → Token-Timeout-/Quorum-Risiko, insbesondere bei Link-Flackern.
- **Skala:** 60–80 Hosts in einem Cluster sind praktisch riskant und unüblich; konservativ plant man 16–24 Nodes je Cluster → mehrere Cluster pro DC.
- Ohne gestrecktes Ceph bringt ein gestreckter Proxmox-Cluster nichts (VM-Disks nicht in B) — und gestrecktes Ceph = Metro-Probleme (Split-Brain im Storage, Tie-Breaker, Blast-Radius, RBD single-writer).
- Fencing bei Link-Flackern ist ein echtes Risiko (ein Standort killt den anderen bei kurzem Aussetzer).
- Blast-Radius: Ein Konfigurationsfehler/Bug betrifft beide Standorte gleichzeitig.

Die getrennten Cluster + Witness auf externer Ebene liefern dieselbe Übernahmequalität ohne diese Risiken — gegen den Preis eines kleinen, gut getesteten Failover-Mechanismus.
