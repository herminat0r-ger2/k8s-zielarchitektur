# KRITIS Zielarchitektur — Proxmox + Kubernetes

Interaktives HTML-Diagramm der Zielarchitektur für eine KRITIS-Umgebung auf HPE Gen10 ESXi-Basis, Migration weg von VMware.

## 🌐 Live-Ansicht (gerendert im Browser)

**https://herminat0r-ger2.github.io/k8s-zielarchitektur/**

> Hinweis: Die Datei `index.html` im Repo wird von GitHub als Quellcode angezeigt.
> Für die gerenderte Diagramm-Ansicht immer den Live-Link oben verwenden (GitHub Pages).

## Inhalt

- **Drei Proxmox-Cluster**: eigenständige Cluster in Standort A und B auf lokalem Alletra-Storage (kein Sync) **plus** ein gestreckter Cluster über beide Standorte (VMs + Kubernetes) auf dem Alletra-Metro-Paar
- **Drei Kubernetes-Cluster**: K8s-A, K8s-B, K8s-Stretch · DB-Replikation zwischen A und B via CloudNativePG
- **[failover.md](failover.md)** — Standort-Failover & Split-Brain: Anforderung "B übernimmt sofort", drei Regeln; **Entscheidung gestreckter Proxmox-Cluster (§8)** und **Corosync-Betriebsauflagen (Latenz-Budget, Timeout-Formel, Link-Prioritäten, QDevice — §9)**
- **[storage.md](storage.md)** — Proxmox VE Storage-Lösungen (File- & Block-Level): Bewertungsmatrix für das Enterprise-Stretched-Cluster (HPE Alletra + PBS), Empfehlung Block-Storage über NVMe-oF/iSCSI + LVM, Linux-VM-Resilienz bei Netzwerkfehlern
- **Layer-Modell**: Proxmox VE (VM-Plattform) · RKE2/Talos Kubernetes · Cilium Overlay · **HPE Alletra MP B10000** (zwei LUN-Klassen: lokal-only + Metro) · DR via Velero/CloudNativePG · IaC via OpenTofu, Patches via Uyuni
- **Umgebungen**: Produktiv / Test / Quality als getrennte Cluster
- **Offene Entscheidungen** direkt im Diagramm dokumentiert
- **[backup/](backup/)** — Backup-Architektur für die neue Welt: PBS + Uyuni + PVE-Hook (VMs) und Velero/Stash/DB-Operatoren (K8s) inkl. Skripte und Ablauf-Bild

## Nutzung

Datei `index.html` im Browser öffnen (lokal oder über GitHub Pages). Kein Build, keine externen Assets außer Google Fonts.

## Relocation / Eigener Betrieb

1. Repo klonen: `git clone https://github.com/herminat0r-ger2/k8s-zielarchitektur.git`
2. `index.html` öffnen — fertig
3. Anpassungen direkt in der HTML (Inline-SVG + JavaScript, kein Framework)
