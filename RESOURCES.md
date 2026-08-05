# Architektur-Recherche: Best Practices & Referenzen

> **Zweck:** Entscheidungsgrundlage für die KRITIS-Zielarchitektur (Proxmox + Kubernetes, 2 Standorte).
> Jede Sektion: **Kernaussage → Quelle → Konsequenz für unsere Architektur**.
> Stand: 2026-08-05. Quellen verifiziert via offizielle Doku, Ceph-Blog (IBM), BSI, Reddit-Community.

---

## 1. Proxmox VE — Cluster & Quorum

### Kernaussagen
- **Keine harte Node-Obergrenze**: "There's no explicit limit for the number of nodes in a cluster. Currently (2021), reports of clusters with over 50 nodes in production" (Enterprise-Hardware)
- **Quorum**: Jeder Node = 1 Vote. Für HA braucht es **mind. 3 Nodes** (sonst QDevice als externen Vote)
- **2-Node-Cluster** brauchen zwingend einen QDevice (dritte Stimme) — sonst = kein Quorum bei einem Ausfall
- **Corosync-Netzwerk**: Dedizierte NIC empfohlen, UDP 5405–5412, latenzempfindlich (nicht bandbreitenhungrig, 1 Gbit reicht), bis zu 8 Links, 2. Link auf anderem physischen Netz = Pflicht für Redundanz
- **Bond als einzelner Link ist riskant** (Corosync-over-Bonds-Problematik)
- Cluster-Name, Hostname, IP **nach Cluster-Erstellung nicht mehr änderbar** → vorher fixieren
- pmxcfs verteilt Config in Echtzeit; alle Nodes brauchen Zeitsynchronisation + SSH

### Quellen
- https://pve.proxmox.com/wiki/Cluster_Manager (offizielle Doku)
- https://forum.proxmox.com/threads/design-options-for-a-2-node-cluster-in-production.141257/
- https://www.apalrd.net/posts/2022/pve_quorum/ (praktische 2-Node-Konfiguration)

### ✅ Konsequenz für uns
- Unsere Planung **3–4 Proxmox-Cluster à 16–24 Nodes** ist im Rahmen des Supportbaren (50+ nachgewiesen)
- **Kritisch: Jeder Proxmox-Cluster muss ≥3 Nodes haben** und Corosync über **zwei getrennte physische Netzwerke** (VLAN-übergreifend, nicht nur ein Bond)
- QDevice nicht nötig bei 16–24 Nodes, aber bei Wartungsfenstern (Node-Drain) Quorum beachten — mit 16–24 Nodes unkritisch
- **Kein Proxmox-Cluster über 2 DCs strecken!** Corosync ist latenzempfindlich, pmxcfs synchron — das ist der klassische Proxmox-Fehler. Pro DC eigene Cluster

---

## 2. Ceph — Storage über 2 Standorte

### Kernaussagen
- **Zwei Grundstrategien**:
  - **Asynchrone Replikation** (RBD-Mirroring, RGW-Multisite, CephFS-Snapshot): getrennte Cluster, RPO ≠ 0
  - **Synchrone Replikation = Stretch Cluster**: ein Cluster über DCs, **RPO = 0**, aber Latenz-Aufschlag bei jedem Write
- **Stretch-Cluster-Hard-Limits** (offiziell von Ceph/IBM):
  - **Max. 10 ms RTT zwischen den OSD-Standorten** (Tie-Breaker darf 100 ms)
  - **2-Standort-Aufbau: size=4** (2 Replicas pro DC) + **Tie-Breaker-Monitor** (darf eine VM sein)
  - **3-Standort: size=6**, kein Tie-Breaker nötig
  - **SSD-Pflicht** (HDD nicht supported im Stretch-Mode)
  - **Kein Erasure Coding** im Stretch-Mode (Performance)
- **Write-Amplifikation**: size=6 = 6 OSD-Operationen pro Client-Write → **OLTP/DB-Workloads leiden** (Ceph-Empfehlung: "high IOPS, low-latency OLTP database workload likely will struggle")
- **Stretch-Mode-Verhalten**: Bei DC-Ausfall wird min_size auf 1 reduziert → Betrieb läuft mit einer Site weiter, PGs peeren NIE nur innerhalb einer Site (Schutz vor Split-Brain und Single-Site-Datenverlust)
- Monitor-Election-Strategie: `connectivity` zwingend
- **Netzwerk-Grundlage**: ≥10 GbE zwischen den OSD-Nodes, 40/100 GbE für Spine üblich (Ceph-Hardware-Empfehlung)
- OSD-Sizing-Community: **1 OSD pro Node oder 4+**, 2–3 OSDs pro Node = Platzprobleme

### Quellen
- https://docs.ceph.com/en/reef/rados/operations/stretch-mode/ (offizielle Doku, ausführlich)
- https://ceph.io/en/news/blog/2025/stretch-cluuuuuuuuusters-part1/ (IBM-Blog, Key Concepts + Limits)
- https://docs.ceph.com/en/reef/start/hardware-recommendations/ (Hardware/Netz)
- https://forum.proxmox.com/threads/best-practices-for-setting-up-ceph-in-a-proxmox-environment.148790/
- https://github.com/rook/rook/blob/master/design/ceph/ceph-stretch-cluster.md (Rook-Stretch-Design)

### ✅ Konsequenz für uns
- **Unsere 4×100 Gb/s Interconnect ist die Ausnahme-Situation**, die Stretch überhaupt erlaubt — aber **Latenz messen!** Wenn >2–3 ms RTT zwischen den DCs: Stretch kritisch prüfen
- **Empfehlung bleibt: Ceph pro DC (getrennte Cluster) + Replikation auf Applikationsebene** (Patroni, RBD-Mirroring). Stretch nur für die wirklich Metro-kritischen VMs (FCI/RAC) — genau das haben wir mit SAN/Alletra Metro vorgesehen
- Falls doch Stretch für K8s-Rook: size=4 + Tie-Breaker-VM, **niemals OLTP-DB-PV auf Stretch-Pool**
- Netzwerk: OSD-Traffic sauber vom Corosync- und VM-Traffic trennen (Ceph-Empfehlung 10 GbE min., wir haben 100 GbE)

---

## 3. Kubernetes Multi-Site — etcd, Split-Brain, Stretched Clusters

### Kernaussagen
- **etcd = Raft-Consensus (CP-System)**: Quorum = (n+1)/2. **3 Nodes → 1 Ausfall toleriert. 5 Nodes → 2.**
- **Bei Netzwerk-Partition wird Availability geopfert, nie Consistency** — das ist gewollt und NICHT konfigurierbar
- **Stretched etcd über 2 DCs ist der klassische Fehler**: Bei Partition zwischen den DCs verliert eine Seite das Quorum → Cluster fällt aus, obwohl beide DCs leben
- **Wichtig: 2-Site-etcd (3 Nodes: 2+1) ist eine Zeitbombe**: 2 Nodes in DC A, 1 in DC B → fällt DC A aus, hat B kein Quorum; fällt die Verbindung, kann A nicht schreiben (kein Quorum mit 2 von 3 nur wenn... eigentlich: 2/3 = Quorum, aber beide A-Nodes müssen da sein)
- Community-Konsens (Reddit r/kubernetes): **etcd nie über Standorte strecken**, außer 3 gleichwertige Standorte (2-of-3-Quorum erfordert 2 Sites erreichbar)
- **etcd-Betriebs-Härtung**:
  - Storage-Limit default 2 GB (max 8 GB) → **Compaction + Defrag automatisieren**, bei 70% alarmeren
  - Disk-I/O-Latenz ist kritisch (fdatasync je Write) → **dedizierte schnelle SSDs, keine geteilten Storage-LUNs**
  - Backups: **alle 6–12 h**, extern lagern, Restore regelmäßig testen (Snapshots sind Alles-oder-nichts — kein selektives Restore)
  - TLS für alle etcd-Kommunikation
- **K8s-Multi-Site-Muster (Best Practice)**:
  - **Getrennte Cluster pro DC** + Failover auf DNS/GLB-Ebene (kein Stretched Cluster)
  - Dritter Standort nur als Arbiter/Witness (kein Datenverkehr) — CNCF-Artikel zeigt dieses Muster explizit gegen Split-Brain

### Quellen
- https://etcd.io/docs/v3.2/faq/ (Quorum/Failure Tolerance)
- https://www.reddit.com/r/kubernetes/comments/1ssk7hx/2node_sites_remote_etcd_am_i_building_a_time_bomb/ (Time-Bomb-Diskussion)
- https://www.cncf.io/blog/2021/09/16/redundancy-across-data-centers-with-kubernetes-wireguard-and-rook/ (3-Region-Arbiter-Muster)
- https://www.latitude.sh/blog/etcd-the-kubernetes-component-youre-probably-neglecting (etcd-Betrieb)
- https://stackoverflow.com/questions/70345068/ (etcd = CP-System, Availability vs Consistency)

### ✅ Konsequenz für uns
- **Bestätigt: 2 unabhängige Cluster (Site A aktiv, Site B passiv) + GLB/DNS-Failover** — kein Stretched etcd, kein "3-Nodes-über-2-DCs"
- Control-Plane-Nodes: **3 pro Cluster, alle in EINEM DC**, auf dedizierten Hosts (Anti-Affinität), schnelle lokale NVMe für etcd
- etcd-Operationalisierung in den GitOps/Ansible-Playbooks verankern: Compaction-Cron, 6-12h-Backups nach extern, Restore-Test als DR-Übung
- Aktiv/Aktiv (ClusterMesh) nur für **Stateless** — DB-Primary bleibt in Site A (Single-Primary-Writes), exakt wie unser Toggle es darstellt

---

## 4. Cilium ClusterMesh (Multi-Cluster-Netzwerk)

### Kernaussagen
- **ClusterMesh verbindet mehrere Cluster** (Service-Discovery, L7-Policies über Cluster-Grenzen, Global Services). Service Mesh (Istio/Linkerd) ist das NICHT — ClusterMesh ist kein Mesh im Sidecar-Sinn
- **Hard-Requirement: Pod-Subnets dürfen sich zwischen Clustern NICHT überlappen** → pro Cluster eindeutige CIDRs planen (10.10.0.0/16 vs 10.20.0.0/16)
- **NodePort als Service-Typ für clustermesh-apiserver ist fragil** ("may fail when nodes are removed") → LoadBalancer-Typ bevorzugen
- **KVStoreMesh** (etcd-basiert) vs MCS-API: KVStoreMesh skaliert besser für viele Cluster
- **Performance-Vergleich läuft** (Cilium ClusterMesh vs Istio Multi-Cluster): eBPF-Datapath ist schnell, Overhead primär bei Service-Mesh-Features, nicht ClusterMesh selbst
- Produktions-Reife: Riot Games (20+ Cluster, 3+ pro Game in gleicher Config), auch AWS-Cross-Region-Deployments dokumentiert
- **IPsec/WireGuard für Cross-Cluster-Encryption** (eBPF-Datapath kann verschlüsselt werden)
- Locality-Routing: Traffic bevorzugt lokale Endpoints — wichtig für Aktiv/Aktiv mit Read-Replicas

### Quellen
- https://cilium.io/use-cases/cluster-mesh/ (offiziell, Use-Cases inkl. Riot)
- https://ferrishall.dev/cilium-clustermesh-kubernetes-ebpf-guide (Setup + CIDR-Falle)
- https://github.com/cilium/cilium/discussions/42358 (Performance-Diskussion)
- https://www.reddit.com/r/kubernetes/comments/1cn2e2o/cilium_service_mesh_vs_cluster_mesh/

### ✅ Konsequenz für uns
- **ClusterMesh = unser Werkzeug für Aktiv/Aktiv** — aber nur für Stateless (wie im Diagramm)
- **CIDR-Plan vor Cluster-Erstellung fixieren**: Pro Cluster eindeutige Pod- und Service-CIDRs, sonst ist ClusterMesh später unmöglich ohne Rebuild
- LoadBalancer (MetalLB) für clustermesh-apiserver, nicht NodePort
- IPsec zwischen den DCs für verschlüsselte ClusterMesh-Verbindung (bei ACI-L3-Transport sowieso sauber zu realisieren)
- Locality-Routing aktivieren → Read-Replicas werden lokal bedient (genau unser GSLB-50/50-Modell)

---

## 5. Kubernetes-Distribution: Talos vs RKE2 vs andere

### Kernaussagen
- **Talos Linux** (Sidero Labs):
  - **Immutable OS, API-first, kein SSH, kein Paket-Manager** — Konfig-Drift unmöglich
  - Vanilla-Kubernetes, extrem schlank (~40 MB), nur für K8s gebaut
  - ISO-27001/KRITIS-freundlich: keine SSH-Angriffsfläche, signierte Upgrades, rollback-fähig
  - Learning Curve: komplett anderes Betriebsmodell (talosctl statt SSH)
- **RKE2** (SUSE/Rancher):
  - Produktionsreif, CIS-Hardening-Profile, **FIPS-Mode** (für KRITIS relevant)
  - Embedded etcd, näher am klassischen Linux-Betrieb (SSH möglich)
  - Upgrade-Pfad über Rancher/Rancher Prime bekannt
- **Community-Erfahrung**: Rancher ist nicht exklusiv mit Talos — Rancher Prime kann auch Talos-Cluster managen (via CAPI). Migrations-Berichte RKE→Talos existieren (oneuptime 2026)
- **Cluster API (CAPI) + CAPMOX** (ionos-cloud/cluster-api-provider-proxmox): deklarativer Cluster-Bau auf Proxmox — **Talos + CAPI + Proxmox ist ein dokumentierter, funktionierender Weg** (Reddit + Blog + offizielles CAPMOX-Repo)

### Quellen
- https://www.siderolabs.com/blog/talos-linux-vs-k3s/ (offiziell)
- https://www.infoq.com/news/2025/10/talos-linux-kubernetes/ (Immutability/Omni)
- https://oneuptime.com/blog/post/2026-03-03-migrate-from-rancher-rke-to-talos-linux/view (Migration)
- https://www.reddit.com/r/kubernetes/comments/1crzs8z/rancher_in_2024/ (Rancher/Talos-Kompatibilität)
- https://github.com/ionos-cloud/cluster-api-provider-proxmox (CAPMOX)
- https://a-cup-of.coffee/blog/talos-capi-proxmox/ + https://unixorn.github.io/post/homelab/k8s/01-talos-with-cilium-cni-on-proxmox/ (Praxis-Reports)

### ✅ Konsequenz für uns
- **Talos ist die härtere Wahl für KRITIS/ISO 27001** (kein SSH, immutable, Audit-freundlich) — passt zu unserem Security-Profil
- **RKE2 bleibt die konservative Alternative** mit FIPS-Mode, falls das Team klassischen Linux-Betrieb braucht
- **Entscheidung nicht nur OS, sondern Betriebsmodell**: Team muss talosctl/API-Denke lernen — das ist der eigentliche Kostenpunkt
- **CAPI + CAPMOX + Talos als reproduzierbarer Standard** — Cluster als Code, kein Hand-VM-Bau (löst exakt unser "Rancher auf VMs war nicht schön"-Problem)
- Rancher Prime optional als Management-Ebene auch über Talos (kein Ausschlusskriterium)

---

## 6. BSI / ISO 27001 / KRITIS — Container & Kubernetes

### Kernaussagen
- **BSI IT-Grundschutz** hat zwei relevante Bausteine:
  - **SYS.1.6 Containerisierung**
  - **APP.4.4 Kubernetes** (seit Edition 2022) — Einrichtung, Betrieb, Orchestrierung, spezialisierte Infrastruktur
- Konkrete APP.4.4-Anforderungen (Auszug): Service Accounts, RBAC, Secrets-Management, Auditing, Image-Scanning, Patch-Management
- Red Hat liefert eine **BSI-Quick-Check-Mapping** für OpenShift (zeigt, wie Bausteine auf konkrete Plattform-Features abgebildet werden) — als Vorlage nutzbar, unabhängig von OpenShift
- Tools für SzA-Umsetzung: NeuVector (Container-Security) etc.
- ISO 27001-Konsequenzen für uns (bereits im Architektur-Gespräch identifiziert): GitOps als Change-Trail, automatisierte Patch-Doku, terminierte Backup-Restore-Tests, zentrales SIEM

### Quellen
- https://www.bsi.bund.de/SharedDocs/Downloads/DE/BSI/Grundschutz/IT-GS-Kompendium_Einzel_PDFs_2022/06_APP_Anwendungen/APP_4_4_Kubernetes_Edition_2022.pdf (BSI-Original)
- https://access.redhat.com/articles/7045834 (BSI-Quick-Check-Mapping auf Plattform)
- https://elastisys.io/welkin/ciso-guide/controls/bsi-it-grundschutz/ (Control-Mapping)

### ✅ Konsequenz für uns
- **APP.4.4 + SYS.1.6 als Pflicht-Bausteine in die ISMS-Doku aufnehmen** — nicht erst bei Rezertifizierung, sondern als Design-Vorgabe (RBAC, Secrets, Auditing, Image-Scanning sind Architektur-Bestandteile, kein Nachrüsten)
- Red-Hat-Quick-Check als **Checkliste** nutzen (Plattform-unabhängig abgleichen: Was kann unsere Plattform, was fehlt?)
- Kyverno/OPA, Vault, Trivy, Audit-Logs → SIEM: diese Elemente sind damit nicht nice-to-have, sondern **Compliance-Pflicht**

---

## 7. Tooling für Diagramme (Stand der Dinge)

Kurzreferenz — vollständige Liste: https://github.com/philippemerle/Awesome-Kubernetes-Architecture-Diagrams

| Tool | Sterne | Zweck |
|---|---|---|
| KubeDiagrams | 2.6k | Diagramme aus Manifests/Helm/Live-Cluster; PNG/SVG/drawio/Mermaid/D2 |
| KubeView | — | Live-Cluster-Visualisierung (GUI) |
| k8sviz | 327 | Diagramm aus Namespace-State (Graphviz) |
| kubernetes-PlantUML | 282 | PlantUML-Sprites für K8s |
| Diagrams-as-Code (HariSekhon) | 280 | D2/Python/Mermaid |
| cloudogu/k8s-diagrams | 339 | PlantUML-Sammlung (RBAC, Security) |
| KIS (Kubernetes Icons Set) | — | Offizielle Icons (kubernetes/community/icons) |

**Lernwert für uns:** KIS-Icons in unsere HTML einbauen; KubeDiagrams als Ist-Zustand-Doku prüfen.

---

## 8. Offene Entscheidungen / nächste Schritte

1. **Latenzmessung DC A ↔ DC B** (Voraussetzung für jede Storage- und ClusterMesh-Entscheidung): >3 ms → Stretch-Ceph streichen, RBD-Mirroring/Patroni nutzen
2. **Talos vs RKE2**: Team-Fähigkeiten vs Security-Gewinn abwägen; FIPS-Anforderung prüfen (RKE2 hat FIPS-Mode, Talos nicht offiziell)
3. **CIDR-Plan fixieren** (Pod/Service je Cluster) — Voraussetzung für ClusterMesh, später nicht änderbar
4. **CAPI + CAPMOX** im Test-Cluster validieren (Welle 0)
5. **BSI APP.4.4** als Design-Vorgabe in ISMS aufnehmen (nicht erst zur Zertifizierung)
