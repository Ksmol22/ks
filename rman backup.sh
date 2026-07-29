#!/bin/bash
# rman_backup.sh
# Wrapper para ejecutar el backup diario de RMAN con logging y control de errores.
# Pensado para ser llamado desde cron.

# ---------- Configuración del entorno ----------
export ORACLE_SID=ORCL                     # <-- Ajustar al SID real
export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1   # <-- Ajustar
export PATH=$ORACLE_HOME/bin:$PATH
export TNS_ADMIN=$ORACLE_HOME/network/admin

RMAN_SCRIPT=/u01/scripts/rman_backup.rman   # <-- Ajustar ruta al .rman
LOG_DIR=/u01/scripts/logs
DATE=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/rman_backup_${DATE}.log"

mkdir -p "$LOG_DIR"

# ---------- Ejecución del backup ----------
echo "===== Inicio backup RMAN: $(date) =====" >> "$LOG_FILE"

rman cmdfile="$RMAN_SCRIPT" log="$LOG_FILE" append

RMAN_EXIT=$?

echo "===== Fin backup RMAN: $(date) - Exit code: $RMAN_EXIT =====" >> "$LOG_FILE"

# ---------- Verificación de errores ----------
if grep -q "RMAN-00" "$LOG_FILE" || grep -q "ORA-" "$LOG_FILE"; then
    echo "ALERTA: Se detectaron errores en el backup. Revisar $LOG_FILE" >> "$LOG_FILE"
    # Aquí se puede agregar envío de correo/alerta, por ejemplo:
    # mail -s "ERROR en backup RMAN $ORACLE_SID" admin@empresa.com < "$LOG_FILE"
    exit 1
fi

# ---------- Limpieza de logs antiguos (más de 7 días) ----------
find "$LOG_DIR" -name "rman_backup_*.log" -mtime +7 -delete

exit 0
