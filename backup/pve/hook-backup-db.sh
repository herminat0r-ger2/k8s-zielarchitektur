#!/bin/bash
# =========================================================================
# PVE-HOOK-SKRIPT FUER PBS-BACKUPS MIT DB-KONSISTENZ
#
# Ablage auf dem PVE-Host:  /var/lib/vz/snippets/hook-backup-db.sh
# Aktivierung pro VM:       qm set <VMID> --hookscript local:snippets/hook-backup-db.sh
#                            (oder Proxmox-GUI: VM -> Optionen -> Hook-Skript)
#
# Phasen, die behandelt werden:
#   pre-start  -> DB in konsistenten Zustand versetzen (pre-freeze im Gast)
#   post-stop  -> DB-Locks wieder freigeben (post-thaw im Gast)
#
# Voraussetzungen:
#   - qemu-guest-agent in der VM (via Uyuni-State pbs_consistency.sls)
#   - Skripte /usr/sbin/pre-freeze-script + /usr/sbin/post-thaw-script im Gast
#
# WICHTIG: Die genaue Phasen-Reihenfolge im Zielkontext verifizieren
# (pre-start -> QEMU-GA-fsfreeze -> Snapshot -> post-stop). Siehe backup/README.md.
# =========================================================================

LOG="/var/log/pve-hook-db.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$PHASE] VM $VMID: $1" >> "$LOG"
}

PHASE="${1:-}"
VMID="${2:-}"

case "$PHASE" in
    pre-start)
        # VM laeuft -> pre-freeze im Gast ausfuehren
        if ! qm guest exec "$VMID" -- /usr/sbin/pre-freeze-script > /tmp/pve-hook-pre.out 2>&1; then
            log "FEHLER: pre-freeze im Gast fehlgeschlagen (qm guest exec). Backup wird abgebrochen."
            cat /tmp/pve-hook-pre.out >> "$LOG"
            exit 1
        fi
        log "pre-freeze im Gast erfolgreich ausgefuehrt."
        ;;
    post-stop)
        # Backup fertig -> Locks im Gast freigeben. Fehler nur loggen
        # (das Backup ist bereits abgeschlossen, kein Abbruch mehr moeglich).
        if ! qm guest exec "$VMID" -- /usr/sbin/post-thaw-script > /tmp/pve-hook-post.out 2>&1; then
            log "WARNUNG: post-thaw im Gast fehlgeschlagen (qm guest exec)."
            cat /tmp/pve-hook-post.out >> "$LOG"
        else
            log "post-thaw im Gast erfolgreich ausgefuehrt."
        fi
        ;;
    *)
        # Alle anderen Phasen (job-init, job-end, pre-stop, post-start, ...)
        # werden ignoriert, aber protokolliert.
        log "Phase '$PHASE' ignoriert."
        ;;
esac

exit 0
