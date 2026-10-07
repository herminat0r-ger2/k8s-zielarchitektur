# Backup-Architektur — Proxmox VE + PBS + Kubernetes (KRITIS/ISO 27001)

Zielbild für die neue Architektur (ersetzt Veeam-BfSS-Ansatz, Muster bleibt):

> **Einmal zentral konfigurieren, automatisch für alle (auch neue) Instanzen wirken — ohne jede VM oder jeden Pod einzeln anzufassen.**

Es gibt **keine** Lösung, die *null* Eingriff braucht: App-konsistente Backups erfordern definitionsgemäß App-Kooperation (Lock, Checkpoint, Dump). Aber diese Kooperation wird **einmal zentral ausgerollt** (via Uyuni/Salt für VMs, via Label-Selektor/Operatoren für K8s) und wirkt danach automatisch.

---

## 1. Die drei Sicherungsebenen

| Ebene | Werkzeug | Sichert | Restore-Ziel |
|---|---|---|---|
| VM-Image | Proxmox Backup Server | komplette VM (OS, Apps, Daten auf der VM-Disk) | ganze VM (Standort A oder B) |
| K8s-Objekte + PVs | Velero → MinIO (S3) | Deployments, Secrets, ConfigMaps, CRDs, PVC-Inhalte (via CSI-Snapshot/Restic) | gezielter Namespace/App in beliebigem Cluster |
| DB-Konsistenz | pre-freeze/post-thaw-Skripte (VMs) + DB-Operatoren/Stash (K8s) | konsistenter DB-Zustand (Lock/Checkpoint/Dump) | DB mit sauberem Abbild, ohne Recovery-Überraschungen |

**Warum drei Ebenen?** PBS sichert die VM-Disk. Die Nutzdaten von K8s-Workloads (PVCs via HPE CSI Driver) liegen aber in eigenen LUNs auf dem Alletra-Metro-Paar — **nicht** in der Node-VM-Disk. Ein PBS-Restore stellt Nodes wieder her, aber weder PVCs noch den konsistenten DB-Zustand. Velero deckt die K8s-Ebene ab, die Skripte/Operatoren die DB-Konsistenz.

## 2. VM-Ebene: PBS + Uyuni + PVE-Hook

```
┌────────────────────────────────────────────────────────────────────┐
│                     PROXMOX VE (PVE-Host)                          │
│                                                                     │
│  ┌─────────────────────────────┐   ┌─────────────────────────────┐  │
│  │  PBS-Backup-Job             │   │  hook-backup-db.sh (Hook)   │  │
│  │  (Snapshot-Mode, ZSTD)      │   │  pre-start  → guest exec    │  │
│  └──────────────┬──────────────┘   │               pre-freeze    │  │
│                 │                  │  post-stop  → guest exec    │  │
│                 │                  │               post-thaw     │  │
│                 │                  └──────────────┬──────────────┘  │
│                 ▼                                 │ QEMU-GA         │
│  ┌────────────────────────────────────────────────▼──────────────┐  │
│  │              LINUX VM (Datenbank)                              │  │
│  │  qemu-guest-agent + /usr/sbin/pre-freeze-script               │  │
│  │  + /usr/sbin/post-thaw-script  (via Uyuni deployed)           │  │
│  │    • MariaDB/MySQL: FLUSH TABLES WITH READ LOCK               │  │
│  │    • PostgreSQL:   CHECKPOINT                                  │  │
│  │    • MS SQL:       CHECKPOINT (via sqlcmd)                     │  │
│  └───────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

Ablauf eines Backups:

| Schritt | Vorgang |
|---|---|
| T0 | PBS-Backup-Job startet (Snapshot-Mode) |
| T1 | PVE-Hook `pre-start`: `qm guest exec <VMID> -- /usr/sbin/pre-freeze-script` → DB in konsistenten Zustand (Lock/Checkpoint) |
| T2 | PBS erstellt VM-Snapshot (QEMU-GA fsfreeze friert zusätzlich das Dateisystem ein) |
| T3 | PVE-Hook `post-stop`: `qm guest exec <VMID> -- /usr/sbin/post-thaw-script` → Locks freigeben |
| T4 | Backup-Daten nach PBS (dedupliziert, verschlüsselt); Restore-Tests terminieren (ISO 27001) |

**PBS kann selbst keine App-konsistenten DB-Backups** (kein VSS-Äquivalent). Die Konsistenz kommt aus den Skripten — genau wie im Veeam-Repo, nur mit anderem Trigger (QEMU-GA statt VMware Tools). Die Skripte sind DB-agnostisch und erkennen selbst, welche DB läuft.

**Verteilung via Uyuni (Salt) — keine Einzelanfassung:**
- State `pbs_consistency.sls` → installiert `qemu-guest-agent` + die Skripte auf allen DB-VMs (Systemgruppe `grp_db_backup_pbs`, analog zum heutigen `grp_db_backup_veeam`)
- State `pbs_log_cleanup.sls` → deployt `db_log_cleanup.sh` + gestaffelten Cron (hash der Minion-ID, 01:00–03:59)
- Neue DB-VM → Gruppe zuweisen, fertig.

**Ablage im Uyuni/Salt-Master:**
1. `salt/pbs_consistency.sls` und `salt/pbs_log_cleanup.sls` nach `/srv/salt/` kopieren
2. `/srv/salt/pbs/files/` anlegen und die Skripte aus `scripts/` dorthin kopieren (`pre-freeze-script`, `post-thaw-script`, `db_log_cleanup.sh`)
3. In der Uyuni-Weboberfläche der Systemgruppe `grp_db_backup_pbs` zuweisen
4. **Apply Actions** ausführen — Konfiguration läuft parallel auf allen VMs

**Voraussetzung PVE-Hook:**
- Hook-Skript liegt auf dem PVE-Host (z. B. `/var/lib/vz/snippets/hook-backup-db.sh`)
- Pro VM aktivieren: `qm set <VMID> --hookscript local:snippets/hook-backup-db.sh`
- Oder im Backup-Job pro VM hinterlegen (Proxmox-GUI: VM → Optionen → Hook-Skript).
- **Testhinweis:** Die genaue Phasen-Reihenfolge (`pre-start` → QEMU-GA-freeze → Snapshot → `post-stop`) im Zielkontext verifizieren — die Skripte selbst unverändert im Gast testen (siehe `scripts/`).

## 3. VM-Failover & Split-Brain

→ Siehe **[failover.md](../failover.md)** — Anforderung "Standort B übernimmt sofort", Witness/Down-Detection und Split-Brain-Regeln gehören zur Hauptarchitektur, nicht zum Backup-Konzept.

## 4. K8s-Ebene: Velero + DB-Konsistenz

Ausführlich dokumentiert in **[k8s/README.md](k8s/README.md)** mit Ablauf-Bild ([ablauf-k8s-db-backup.svg](k8s/ablauf-k8s-db-backup.svg)).

Kurzfassung:

> **Verbindliche Anforderung:** Standort B übernimmt **immer sofort** (Hot Standby / Active-Active). Replikation nach B ist für alle Daten Pflicht; Restore ist nur Sicherheitsnetz gegen Datenverlust, **kein Übernahme-Pfad**. Details: [k8s/README.md](k8s/README.md) Abschnitt 3.

- **Velero** sichert K8s-Objekte + PV-Inhalte nach MinIO/S3 — als Backup-Sicherheitsnetz, nicht als Übernahme-Mechanismus.
- **DB-Konsistenz** in K8s auf drei Wegen — in aufsteigender Automatisierung:
  1. **Velero + Pre/Post-Hooks** (kein Operator nötig): zentrales Backup definiert Exec-Hooks in die DB-Pods (`pg_dump`-artig oder Backup-Modus). Funktioniert ohne Zusatz-Installation, Hooks sind zentral pro Backup definiert.
  2. **Stash (AppsCode)**: Sidecar-Injektion per Label-Selektor (`backup: database`) — einmalige zentrale `BackupConfiguration`, dann automatisch für alle (auch neue) Pods mit dem Label. Konsistente Dumps für PostgreSQL/MySQL/MongoDB/Redis → S3/MinIO.
  3. **DB-Operatoren** (optional, Empfehlung bei HA-Anforderung): CloudNativePG (PostgreSQL), Percona (MySQL), KubeDB (multi-DB). Der Operator übernimmt HA/Failover/Upgrades **und** konsistente, geplante Backups selbst.

## 5. DB-Operatoren — brauche ich sie oder nicht?

**Kurz:** Sie sind **optional**. Was sie dir geben: HA + Failover + Upgrades + konsistente Backups als *eine* deklarierte Ressource, statt selbst zu bauen. Was sie kosten: eine zusätzliche, selbst zu wartende Komponente im Cluster.

| Frage | Ohne Operator (Velero + Hooks / Stash) | Mit Operator (z. B. CloudNativePG) |
|---|---|---|
| Konsistentes Backup | ✅ ja (Dump via Hook/Sidecar) | ✅ ja (eingebaut, scheduled, S3) |
| HA / automatisches Failover | ❌ selbst bauen (Patroni als extra Deployment) | ✅ eingebaut |
| Upgrades / Major-Versionen | manuell | ✅ Operator-geführt |
| Betriebsmodell | transparent, klassisch | deklarativ (CRD), ein Betriebsmodell mehr im Cluster |
| Wann sinnvoll | Single-Instanz-DBs, manuelle Promotion in B reicht | DBs mit automatischem Failover oder viele gleichartige DBs |

Empfehlung für die Zielarchitektur: **Single-Instanz-DBs (manuelle Promotion in B reicht) → Replica in B + Velero + Hooks (oder Stash). Automatisches Failover gefordert → Operator** (CloudNativePG für PostgreSQL). Beides kann parallel laufen; der Operator ersetzt die Hooks für seine DBs, Velero sichert weiterhin Objekte + PVs aller Workloads.

## 6. Verzeichnisstruktur

```
backup/
├── README.md                  # dieses Dokument
├── scripts/
│   ├── pre-freeze-script      # DB-Konsistenz VOR dem Snapshot (Gast)
│   ├── post-thaw-script       # Locks NACH dem Snapshot freigeben (Gast)
│   └── db_log_cleanup.sh      # tägliche Log-Bereinigung (Cron)
├── salt/
│   ├── pbs_consistency.sls    # Uyuni: qemu-guest-agent + Konsistenz-Skripte
│   └── pbs_log_cleanup.sls    # Uyuni: Cleanup-Skript + gestaffelter Cron
├── pve/
│   └── hook-backup-db.sh      # PVE-Hook: triggert pre/post-freeze via QEMU-GA
└── k8s/
    ├── README.md              # K8s-Backup genau erklärt
    └── ablauf-k8s-db-backup.svg
```
