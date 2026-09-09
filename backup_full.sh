#!/bin/bash
. /home/oracle/.bash_profile
export ORACLE_SID=CRMPILCON
FECHA=$(date +%Y%m%d_%H%M)
LOG=/home/oracle/logs/full_${FECHA}.log

rman target / log=$LOG <<EOF
run {
  configure compression algorithm 'BASIC';
  configure controlfile autobackup on;
  configure retention policy to recovery window of 3 days;
  configure archivelog deletion policy to backed up 1 times to disk;
  backup as compressed backupset
    database format '/u03/backup/full_%d_%T_%s_%p.bkp'
    plus archivelog delete input;
  delete noprompt obsolete;
  crosscheck backup;
  delete noprompt expired backup;
}
EOF

if grep -qE "RMAN-|ORA-" $LOG; then
  mail -s "FALLO backup full CRMPILCON" tu@correo < $LOG
fi
