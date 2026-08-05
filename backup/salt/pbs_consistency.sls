# =========================================================================
# Salt-State zur Absicherung der Datenkonsistenz waehrend PBS-Backups.
# Dieses State installiert den QEMU Guest Agent und die Quiescing-Skripte.
#
# Ablage im Uyuni/Salt-Master:
#   /srv/salt/pbs_consistency.sls      (dieser State)
#   /srv/salt/pbs/files/pre-freeze-script
#   /srv/salt/pbs/files/post-thaw-script
#
# Zuweisung in Uyuni: Systemgruppe z. B. "grp_db_backup_pbs".
# =========================================================================

# Installation des QEMU Guest Agents (Voraussetzung fuer `qm guest exec`
# aus dem PVE-Hook-Skript und fuer den automatischen FS-Freeze bei Snapshots)
install_qemu_guest_agent:
  pkg.installed:
    - name: qemu-guest-agent

# Sicherstellung, dass der QEMU Guest Agent laeuft
enable_qemu_guest_agent:
  service.running:
    - name: qemu-guest-agent
    - enable: True
    - require:
      - pkg: install_qemu_guest_agent

# Sicherstellung, dass das Zielverzeichnis fuer die Skripte existiert
ensure_sbin_directory:
  file.directory:
    - name: /usr/sbin
    - user: root
    - group: root
    - mode: '0755'

# Bereitstellung des Pre-Freeze-Skripts zur Vorbereitung der Datenbanken
deploy_pre_freeze_script:
  file.managed:
    - name: /usr/sbin/pre-freeze-script
    - source: salt://pbs/files/pre-freeze-script
    - user: root
    - group: root
    - mode: '0700'
    - require:
      - file: ensure_sbin_directory

# Bereitstellung des Post-Thaw-Skripts zur Freigabe der Datenbanken
deploy_post_thaw_script:
  file.managed:
    - name: /usr/sbin/post-thaw-script
    - source: salt://pbs/files/post-thaw-script
    - user: root
    - group: root
    - mode: '0700'
    - require:
      - file: ensure_sbin_directory
