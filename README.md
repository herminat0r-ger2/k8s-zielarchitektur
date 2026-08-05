# KRITIS Zielarchitektur — Proxmox + Kubernetes

Interaktives HTML-Diagramm der Zielarchitektur für eine KRITIS-Umgebung auf HPE Gen10 ESXi-Basis, Migration weg von VMware.

## 🌐 Live-Ansicht (gerendert im Browser)

**https://herminat0r-ger2.github.io/k8s-zielarchitektur/**

> Hinweis: Die Datei `index.html` im Repo wird von GitHub als Quellcode angezeigt.
> Für die gerenderte Diagramm-Ansicht immer den Live-Link oben verwenden (GitHub Pages).

## Inhalt

- **Zwei Standorte (Aktiv/Passiv & Aktiv/Aktiv)** — umschaltbar per Toggle im Diagramm
- **[failover.md](failover.md)** — Standort-Failover & Split-Brain: Anforderung "B übernimmt sofort", Witness/Down-Detection, drei Regeln
- **Layer-Modell**: Proxmox VE (VM-Plattform) · RKE2/Talos Kubernetes · Cilium Overlay · Ceph Storage · DR via Velero/Patroni
- **Umgebungen**: Produktiv / Test / Quality als getrennte Cluster
- **Offene Entscheidungen** direkt im Diagramm dokumentiert
- **[backup/](backup/)** — Backup-Architektur für die neue Welt: PBS + Uyuni + PVE-Hook (VMs) und Velero/Stash/DB-Operatoren (K8s) inkl. Skripte und Ablauf-Bild

## Nutzung

Datei `index.html` im Browser öffnen (lokal oder über GitHub Pages). Kein Build, keine externen Assets außer Google Fonts.

## Relocation / Eigener Betrieb

1. Repo klonen: `git clone https://github.com/herminat0r-ger2/k8s-zielarchitektur.git`
2. `index.html` öffnen — fertig
3. Anpassungen direkt in der HTML (Inline-SVG + JavaScript, kein Framework)
