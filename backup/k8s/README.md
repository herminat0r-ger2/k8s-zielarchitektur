# K8s-Backup — genau erklärt (Velero, DB-Operatoren, Stash)

Dieses Dokument erklärt, wie Datenbank-Backups in Kubernetes funktionieren,
warum es mehrere Bausteine gibt und wann ein DB-Operator nötig ist (oder nicht).
Ablauf-Bild: [ablauf-k8s-db-backup.svg](ablauf-k8s-db-backup.svg)

---

## 1. Das Grundproblem: zwei verschiedene "Dinge" müssen gesichert werden

In Kubernetes gibt es **zwei getrennte Sicherungsobjekte**, die unterschiedliche Werkzeuge brauchen:

| Was | Beispiele | Sichert |
|---|---|---|
| **K8s-Objekte** | Deployments, StatefulSets, Services, Secrets, ConfigMaps, CRDs | die *Beschreibung* der Anwendung (YAML-Manifeste zur Laufzeit) |
| **Daten (PVs)** | Persistent Volumes via ceph-csi (RBD-Images im Ceph-Pool) | die *Inhalte* — genau das, was die DB auf die Platte schreibt |

**Velero** ist das Werkzeug für beide: Es sichert K8s-Objekte und PV-Inhalte
nach S3/MinIO und kann beides gezielt in einen anderen Cluster restoren
(DR-Fall: Restore in Standort B). Das entspricht der "Objekte + Daten"-Ebene.

**Aber:** Ein Velero-Backup (oder ein Ceph-Snapshot) ist zunächst nur
*crash-consistent* — wie ein Stromausfall. Eine laufende PostgreSQL/MySQL
befindet sich in einem Zustand, aus dem sie erst per WAL-/Redo-Replay
wiederhergestellt werden muss. Für ein sauberes, wiederherstellbares Abbild
braucht die DB **App-Kooperation** (Backup-Modus, Dump, Checkpoint). Das ist
der zweite Baustein.

---

## 2. Die drei Wege zur DB-Konsistenz (aufsteigend automatisiert)

### Weg 1: Velero + Pre/Post-Hooks — **kein Operator nötig**

Velero kann in einem Backup **Hooks** definieren: Befehle, die vor/nach dem
Backup in bestimmten Pods ausgeführt werden. Die Hooks werden **zentral pro
Backup** definiert (nicht pro Pod) und wählen Pods per Label aus.

```yaml
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: db-backup
spec:
  includedNamespaces: ["prod"]
  labelSelector:
    matchLabels:
      app: postgres
  hooks:
    resources:
      - name: pg-backup-hook
        includedNamespaces: ["prod"]
        labelSelector:
          matchLabels:
            app: postgres
        pre:
          - exec:
              container: postgres
              command: ["/bin/sh", "-c", "pg_dumpall > /backup/dump.sql"]
              # ODER: PostgreSQL in Backup-Modus versetzen + FS-Freeze abwarten
        post:
          - exec:
              container: postgres
              command: ["/bin/sh", "-c", "true"]   # Backup-Modus beenden
```

Vorteil: kein Zusatz-Tool, transparent. Nachteil: Man baut den DB-Backup-Modus
selbst in die Pods ein (Skript im Image/InitContainer), HA/Failover bleibt
separates Thema (z. B. Patroni als eigenes Deployment).

### Weg 2: Stash (AppsCode) — **Sidecar-Injektion per Label, kein Operator**

Stash injiziert per **Mutation-Webhook automatisch einen Backup-Sidecar** in
jeden Pod, der ein bestimmtes Label trägt. Einmalig wird zentral eine
`BackupConfiguration` definiert:

```yaml
apiVersion: stash.appscode.com/v1beta1
kind: BackupConfiguration
metadata:
  name: db-backup
spec:
  target:
    ref:
      apiVersion: apps/v1
      kind: StatefulSet
      name: postgres
    # ODER labelSelector: matchLabels: { backup: "database" }
  schedule: "0 1 * * *"
  task:
    name: postgres-backup-12.4        # kennt pg_dump/PITR für PostgreSQL
  repository:
    name: backup-repo                 # → S3/MinIO (Backend-Config)
  retentionPolicy:
    name: keep-30
```

Der Sidecar führt dann regelmäßig konsistente Dumps aus (`pg_dump`,
`mysqldump`, `mongodump`, Redis RDB, ...) und lädt sie nach S3/MinIO. **Neue
Pods mit dem Label sind automatisch abgedeckt** — niemand muss einen Pod
einzeln anfassen. Stash ist damit die direkte Antwort auf "zentrale Lösung
ohne jede Pod anzufassen" für nicht-HA-DBs.

### Weg 3: DB-Operator (z. B. CloudNativePG) — **optional, aber mächtig**

Ein DB-Operator ist ein Controller im Cluster, der eine eigene Ressource
(CRD) überwacht — z. B. `Cluster` bei CloudNativePG. Man deklariert das
gewünschte Ende, der Operator baut und wartet alles selbst:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-prod
spec:
  instances: 3                        # Primary + Replicas (HA eingebaut)
  storage:
    size: 1Ti
  backup:
    barmanObjectStore:
      destinationPath: s3://minio/backups/postgres-prod
      wal:
        compression: gzip
    retentionPolicy: "30d"
  # Failover, Upgrades, Backups: alles vom Operator
```

Der Operator bringt mit: HA/Failover, konsistente Backups + WAL-Archivierung
(PITR), Upgrades, Monitoring. **Backup ist hier eine Eigenschaft der DB-
Ressource**, nicht ein separates Backup-Objekt.

---

## 3. Brauche ich DB-Operatoren — oder nicht? (die Entscheidung)

**Vorab die verbindliche Anforderung (gilt für ALLE Daten):** Standort B
muss **immer sofort übernehmen können** — als Hot Standby oder Active/Active.
Ein Restore aus dem Backup ist **kein Übernahme-Pfad** (nur Sicherheitsnetz
gegen Datenverlust/Korruption). Deshalb braucht **jede** Datenbank eine
**Replikation nach Standort B** — auch eine, die im Normalbetrieb "nur eine
Instanz ohne HA" ist. Der Unterschied ist nur der Automatisierungsgrad:

| Übernahme | Mechanismus | RTO |
|---|---|---|
| automatisch (Hot Standby) | Patroni / DB-Operator (CloudNativePG, Percona, KubeDB) | Sekunden–Minuten |
| manuell per Runbook | Replica läuft bereits in B, Promotion per Runbook (MySQL Replication, MSSQL AG/Log-Shipping, MongoDB ReplicaSet) | Minuten |

**Backup bleibt trotzdem Pflicht:** Replikation schützt nicht gegen logische
Fehler (DROP TABLE, Bug, Ransomware) — genau dafür sind Velero/MinIO + PBS da.
Aber die Übernahme hängt nie vom Restore ab.

**Sind Operatoren nötig?** Nicht zwingend — sie sind der bequemste Weg, die
Anforderung zu erfüllen:

| Situation | Empfehlung |
|---|---|
| Single-Instanz-DB, manuelle Promotion in B reicht | **Replica in B + Velero + Hooks/Stash** — kein Operator nötig |
| Automatisches Failover gefordert (RTO klein) | **Operator** (CloudNativePG für PostgreSQL) |
| Viele gleichartige DBs (Self-Service) | Operator (eine CRD = eine DB mit Backup+HA) |
| Bestehende DBs laufen als VMs, nicht in K8s | Replikation auf VM-Ebene (Patroni/DB-eigene Replikation) + PBS |

**Warum manche Architekturen trotzdem Operatoren nutzen:** Der Operator
entkoppelt den DB-Betrieb vom Cluster-Lebenszyklus. Ohne Operator muss man
HA (Patroni) und Backups (Hooks/CronJobs) selbst zusammenbauen und pflegen —
machbar, aber genau die Handarbeit, die bei vielen DBs weh tut.

**Empfehlung für die Zielarchitektur:**
- PostgreSQL mit automatischem Failover → CloudNativePG (ein Operator, deckt Prod ab)
- Single-Instanz-DBs (manuelle Promotion reicht) → Replica in B + Velero + Hooks/Stash
- Velero läuft immer (Objekte + PVs aller Workloads, Backup-Sicherheitsnetz)

---

## 4. Der komplette Ablauf (mit Bild)

Siehe [ablauf-k8s-db-backup.svg](ablauf-k8s-db-backup.svg):

1. **Velero** (Cluster A) startet das Backup (Scheduled oder manuell)
2. **Pre-Hook** versetzt die DB in den Backup-Modus / erzeugt Dump
3. **CSI-Snapshot** der PVCs (RBD-Snapshots im Ceph) oder Restic-Dateibackup
4. **Upload** von Objekten + Daten nach **MinIO/S3** (in Standort A, Replikation nach B)
5. **DB-Operator** (falls vorhanden) macht zusätzlich sein eigenes, konsistentes Backup (Dump + WAL) — unabhängig von Velero
6. **Übernahme in Standort B (DR) — per Replikation, nicht per Restore:** Hot Standby/Active-Active heißt: Die Workloads laufen in B bereits, die DB-Replica ist da — Übernahme = Promotion + Route-Switch (GSLB), kein Restore. **Velero-Restore ist KEIN Übernahme-Pfad**, sondern das Sicherheitsnetz gegen Datenverlust (DROP, Bug, Ransomware) und für terminierte Restore-Tests. **Im Normalbetrieb kommt Standort B nicht über einen gemeinsamen Ceph-Speicher an die Daten** (Ceph ist pro DC getrennt), sondern über die **laufende async Replikation** (Patroni für PostgreSQL, DB-eigene Replikation für MySQL/MSSQL/MongoDB, optional RBD-Mirror) — siehe Box im Hauptdiagramm.

## 5. Rollen-Zusammenfassung

| Komponente | Rolle | Pflicht? |
|---|---|---|
| Replikation nach B (Patroni / DB-eigene) | Hot Standby — sofortige Übernahme ohne Restore | **ja (Pflicht)** |
| Velero | Objekte + PVs, Backup-Sicherheitsnetz | **ja** |
| Pre/Post-Hooks oder Stash | DB-Konsistenz (Dumps) für alle DBs | eine davon |
| DB-Operator (CloudNativePG u. a.) | automatisches Failover + Backups + Upgrades | **optional** (bei RTO klein empfohlen) |
| MinIO/S3 | Backup-Ziel, Cross-Site-Restore | ja |
| PBS | VM-Image-Backups (Nodes + DB-VMs) | ja |
