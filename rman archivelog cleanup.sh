#!/bin/bash
# rman_archivelog_cleanup.sh
# Ejecuta limpieza frecuente de archivelogs para evitar que el destino se llene
# y detenga la base de datos (ORA-00257). Pensado para correr por cron cada hora.

export ORACLE_SID=ORCL                     # <-- Ajustar al SID real
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1   # <-- Ajustar
export PATH=$ORACLE_HOME/bin:$PATH
export TNS_ADMIN=$ORACLE_HOME/network/admin

RMAN_SCRIPT=/u01/scripts/rman_archivelog_cleanup.rman   # <-- Ajustar ruta
LOG_DIR=/u01/scripts/logs
DATE=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/arch_cleanup_${DATE}.log"

mkdir -p "$LOG_DIR"

rman cmdfile="$RMAN_SCRIPT" log="$LOG_FILE" append

RMAN_EXIT=$?

if grep -q "RMAN-00" "$LOG_FILE" || grep -q "ORA-" "$LOG_FILE"; then
    echo "ALERTA: error en limpieza de archivelogs. Revisar $LOG_FILE" >> "$LOG_FILE"
    exit 1
fi

# Limpieza de logs de más de 7 días
find "$LOG_DIR" -name "arch_cleanup_*.log" -mtime +7 -delete

exit 0
