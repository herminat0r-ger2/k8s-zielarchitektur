# =========================================================================
# Salt-State zur Vermeidung von unkontrolliertem Log-Wachstum.
# Dieses State verteilt das Bereinigungsskript und richtet den Cronjob ein.
#
# Ablage im Uyuni/Salt-Master:
#   /srv/salt/pbs_log_cleanup.sls      (dieser State)
#   /srv/salt/pbs/files/db_log_cleanup.sh
# =========================================================================
#
# Zeitliche Staffelung (Staggering):
# Die Ausfuehrungszeit wird pro Host deterministisch aus der Minion-ID
# abgeleitet. Dadurch laeuft der Cronjob nie auf allen Hosts gleichzeitig,
# sondern verteilt sich automatisch ueber ein definiertes Zeitfenster.
#
# Formel:                  Bereich     Aufloesung
#   Minute = hash % 60     0-59        1 Minute
#   Stunde  = 1 + (hash/60) % 3  1-3  3 Stunden
#                               = 180 Slots
#
# Fuer ~500 Hosts ergibt das ~3 Hosts pro Slot. Bei Bedarf kann der
# Stundenbereich in Zeile 28 vergroessert werden (z. B. % 6 fuer 6h).

{% set hash_int = grains['id'] | hash('sha256') | int(0, 16) %}
{% set cron_minute = hash_int % 60 %}
{% set cron_hour = 1 + (hash_int // 60) % 3 %}

# Bereitstellung des universellen Bereinigungsskripts fuer alle DB-Typen
deploy_cleanup_script:
  file.managed:
    - name: /usr/local/bin/db_log_cleanup.sh
    - source: salt://pbs/files/db_log_cleanup.sh
    - user: root
    - group: root
    - mode: '0700'

# Einrichtung des taeglichen Cronjobs mit host-spezifischer Zeitstaffelung.
# Ausgabe wird ins Logfile umgeleitet (nicht nach /dev/null), damit Fehler
# sichtbar bleiben und ueber Uyuni/Logwatch ausgewertet werden koennen.
# Ausfuehrungszeit: {{ cron_hour }}:{{ '%02d' % cron_minute }} (aus Minion-ID abgeleitet)
configure_log_cleanup_cron:
  cron.present:
    - name: /usr/local/bin/db_log_cleanup.sh >> /var/log/db-cleanup.log 2>&1
    - user: root
    - minute: {{ cron_minute }}
    - hour: {{ cron_hour }}
    - require:
      - file: deploy_cleanup_script
