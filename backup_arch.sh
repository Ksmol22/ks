#!/bin/bash
. /home/oracle/.bash_profile
export ORACLE_SID=CRMPILCON
FECHA=$(date +%Y%m%d_%H%M)
LOG=/home/oracle/logs/arch_${FECHA}.log

rman target / log=$LOG <<EOF
run {
  configure compression algorithm 'BASIC';
  backup as compressed backupset
    archivelog all not backed up 1 times
    format '/u03/backup/arch_%d_%T_%s_%p.bkp'
    delete input;
}
EOF

if grep -qE "RMAN-|ORA-" $LOG; then
  mail -s "FALLO backup archivelog CRMPILCON" tu@correo < $LOG
fi
