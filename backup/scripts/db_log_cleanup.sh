#!/bin/bash
# =========================================================================
# AUTOMATISIERTES DATENBANK-WARTUNGS- UND CLEANUP-SKRIPT
# Dieses Skript bereinigt die Transaktionsprotokolle der installierten
# Datenbanken, um ein Volllaufen der Festplatten zu verhindern.
# Es wird taeglich via Cron aufgerufen (Salt-State pbs_log_cleanup.sls).
# =========================================================================
#
# WARNUNG: Das Skript setzt MS SQL Server auf das SIMPLE Recovery Model.
# Dadurch geht Point-in-Time Recovery (PITR) verloren. Siehe Kommentar
# im MS SQL-Abschnitt fuer Alternativen.
# =========================================================================

set -e

LOGFILE="/var/log/db-cleanup.log"

# Protokollierung des Wartungsstarts
echo "$(date): Taegliche Log-Bereinigung gestartet." >> "$LOGFILE"

# -------------------------------------------------------------------------
# 1. MICROSOFT SQL SERVER (LINUX)
# -------------------------------------------------------------------------
if systemctl is-active --quiet mssql-server; then
    echo "$(date): Bereinigung MS SQL Server..." >> "$LOGFILE"

    # SA-Passwort aus geschuetzter Konfigurationsdatei auslesen.
    # Die Datei /etc/backup/mssql_backup.conf sollte nur das Passwort
    # als erste Zeile enthalten und via `chmod 600` gesichert sein.
    MSSQL_CONF="/etc/backup/mssql_backup.conf"
    if [ -f "$MSSQL_CONF" ]; then
        SQL_PASSWORD=$(cat "$MSSQL_CONF")
    else
        echo "$(date): FEHLER - Keine SA-Zugangsdaten unter $MSSQL_CONF. MS SQL-Bereinigung uebersprungen." >> "$LOGFILE"
        echo "$(date): Hinweis: Datei anlegen mit 'echo <SA-Passwort> | sudo tee $MSSQL_CONF && sudo chmod 600 $MSSQL_CONF'" >> "$LOGFILE"
        # Kein exit 1, damit andere DB-Typen noch bearbeitet werden koennen
    fi

    if [ -n "$SQL_PASSWORD" ]; then
        # Umstellung aller Benutzerdatenbanken auf das SIMPLE Recovery Model.
        # Dies verhindert dauerhaft das unbegrenzte Anwachsen der .ldf-Dateien,
        # da freigegebener Speicher ueberschrieben wird.
        #
        # WARNUNG: SIMPLE Recovery Model deaktiviert Point-in-Time Recovery (PITR).
        # Alternativ koennen Transaktionslogs via BACKUP LOG gesichert und
        # anschliessend mit SHRINKFILE verkleinert werden, um PITR zu erhalten:
        #
        #   BACKUP LOG [db_name] TO DISK = '/var/opt/mssql/backup/[db_name]_log.trn';
        #   DBCC SHRINKFILE ([db_name]_log, 100);
        #
        # Dies erfordert jedoch ausreichend Speicherplatz fuer die
        # Log-Backup-Dateien und eine separate Aufraeumlogik fuer alte Backups.
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SQL_PASSWORD" -C -Q "
            DECLARE @db_name NVARCHAR(255);
            DECLARE db_cursor CURSOR FOR
            SELECT name FROM sys.databases WHERE name NOT IN ('master', 'tempdb', 'model', 'msdb');
            OPEN db_cursor;
            FETCH NEXT FROM db_cursor INTO @db_name;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC('ALTER DATABASE [' + @db_name + '] SET RECOVERY SIMPLE;');
                FETCH NEXT FROM db_cursor INTO @db_name;
            END;
            CLOSE db_cursor;
            DEALLOCATE db_cursor;
        " >> "$LOGFILE" 2>&1
    fi

# -------------------------------------------------------------------------
# 2. MARIADB / MYSQL
# -------------------------------------------------------------------------
elif systemctl is-active --quiet mariadb || systemctl is-active --quiet mysql; then
    echo "$(date): Bereinigung MariaDB/MySQL..." >> "$LOGFILE"

    # Loeschen aller Binaerlogs (Binlogs), die aelter als 3 Tage sind.
    # Dies haelt ausreichend Transaktionsdaten fuer kurzfristige Replikationen
    # vor, verhindert jedoch die dauerhafte Belegung von Speicherplatz.
    # Hinweis: Schlaegt fehl, wenn Binlogging nicht aktiviert ist.
    mysql -u root -e "PURGE BINARY LOGS BEFORE NOW() - INTERVAL 3 DAY;" >> "$LOGFILE" 2>&1 || \
        echo "$(date): Warnung - Binlog-Purge fehlgeschlagen (Binlogging moeglicherweise deaktiviert)." >> "$LOGFILE"

# -------------------------------------------------------------------------
# 3. POSTGRESQL
# -------------------------------------------------------------------------
elif systemctl is-active --quiet postgresql; then
    echo "$(date): Bereinigung PostgreSQL..." >> "$LOGFILE"

    # Loeschen von verwaisten und inaktiven Replikations-Slots.
    # Inaktive Replikations-Slots sind die haeufigste Ursache dafuer, dass
    # PostgreSQL die WAL-Dateien (Write-Ahead-Logs) unbegrenzt im Verzeichnis
    # 'pg_wal' aufstaut, da auf eine Bestaetigung des Clients gewartet wird.
    # Hinweis: Die Spalte 'wal_status' erfordert PostgreSQL 13 oder neuer.
    # Bei aelteren Versionen kann die Bedingung 'active = false' ausreichen.
    sudo -u postgres psql -c "
        SELECT pg_drop_replication_slot(slot_name)
        FROM pg_replication_slots
        WHERE active = false AND wal_status = 'lost';
    " >> "$LOGFILE" 2>&1
fi

echo "$(date): Taegliche Log-Bereinigung erfolgreich beendet." >> "$LOGFILE"
exit 0
