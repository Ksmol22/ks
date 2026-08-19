# Centro de Recuperación Oracle con RMAN Centralizado
## Documento 2: Comprobaciones Finales

**Objetivo:** validar de extremo a extremo la solución (catálogo central + NAS + regla de 3 días) antes de darla por operativa. Ejecute las secciones en orden y registre cada resultado en la checklist final (sección 8).

Convención: `CEN` = ejecutar en el servidor central; `PRODx` = en/contra cada base de producción. Repita las secciones 2–5 **para cada base registrada**.

---

## 1. Infraestructura: NFS, wallet y conectividad

```bash
# CEN y cada PRODx
df -h /backups                     # montado desde nas01, espacio esperado
mount | grep /backups              # opciones hard,tcp,rsize=32768,wsize=32768 presentes
touch /backups/chk_$(hostname); ls -l /backups/chk_*; rm /backups/chk_$(hostname)
```
**Criterio:** todos los nodos ven el mismo contenido y pueden escribir.

```bash
# CEN: conexiones sin contraseña vía wallet
rman TARGET /@PROD1 CATALOG /@RCATDB <<< "EXIT;"    # repetir por base
tnsping RCATDB; tnsping PROD1; tnsping PROD2
```
**Criterio:** conexión TARGET+CATALOG correcta a todas las bases.

```bash
# NAS: snapshots activos (consola del NAS)
# Verificar: snapshot diario del volumen oracle_bk, retención >= 7 días,
# y última réplica externa (disco/nube) con fecha reciente.
```

---

## 2. Estado del catálogo por base

```
-- CEN: rman TARGET /@PROD1 CATALOG /@RCATDB
REPORT SCHEMA;                    -- todos los datafiles actuales de la base
LIST INCARNATION;                 -- una sola CURRENT
SHOW ALL;                         -- retención, autobackup ON, formato hacia /backups/PROD1,
                                  -- deletion policy BACKED UP 1 TIMES TO DISK
LIST GLOBAL SCRIPT NAMES;         -- bk_nivel0, bk_nivel1, bk_arch
```

```sql
-- CEN: visión global desde el catálogo (sqlplus rcat@RCATDB)
SELECT name, dbid FROM rc_database ORDER BY name;
-- Criterio: TODAS las bases de producción aparecen registradas; anote los DBID.
```

---

## 3. Backups: existencia, integridad y regla de 3 días

### 3.1 Existencia y estado

```
-- Por base, sesión TARGET+CATALOG
LIST BACKUP SUMMARY;                                   -- N0 semanal y N1 diarios recientes
LIST BACKUP OF CONTROLFILE COMPLETED AFTER 'SYSDATE-2';
CROSSCHECK BACKUP;                                     -- todos AVAILABLE
CROSSCHECK ARCHIVELOG ALL;
REPORT NEED BACKUP;                                    -- vacío
REPORT UNRECOVERABLE;                                  -- vacío (vigilancia NOLOGGING)
DELETE NOPROMPT EXPIRED BACKUP;                        -- limpieza si crosscheck marcó algo
```

### 3.2 Verificación de la regla de 3 días (en cada PRODx)

```sql
-- sqlplus sys@PRODx as sysdba
-- a) No deben existir archivelogs locales de más de 3 días:
SELECT count(*) viejos FROM v$archived_log
WHERE completion_time < sysdate-3 AND deleted='NO' AND name IS NOT NULL;
-- Esperado: 0

-- b) Ningún archivelog local sin respaldar de más de 2-3 horas (según su cron):
SELECT count(*) sin_backup FROM v$archived_log
WHERE deleted='NO' AND backup_count=0 AND completion_time < sysdate-3/24;
-- Esperado: 0

-- c) Espacio de la FRA local sano:
SELECT round(space_used/space_limit*100,1) pct_uso FROM v$recovery_file_dest;
-- Esperado: < 70% en régimen normal
```

### 3.3 Prueba del candado de seguridad

```
-- Intentar borrar un archivelog NO respaldado debe fallar/ser ignorado:
DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE';
-- Criterio: RMAN omite los no respaldados citando la deletion policy (RMAN-08137/08138).
```

### 3.4 Validación de restaurabilidad (sin restaurar, por base)

```
RESTORE DATABASE VALIDATE;
RESTORE CONTROLFILE VALIDATE;
RESTORE SPFILE VALIDATE;
VALIDATE DATABASE;                       -- corrupción física
```
```sql
SELECT * FROM v$database_block_corruption;    -- 0 filas
```
**Criterio:** todas finalizan sin errores. Anote la duración de `RESTORE DATABASE VALIDATE`: es una primera estimación (optimista) de su RTO de lectura desde el NAS.

---

## 4. SIMULACRO DE DESASTRE — restauración completa en otro servidor

La prueba reina: simula "el servidor de PROD1 ha muerto; solo tengo el catálogo y el NAS". Ejecutar en un servidor de pruebas (o el propio central si tiene recursos) con el mismo software Oracle instalado y `/backups` montado. **No toca la base de producción.**

```bash
# En el servidor de pruebas
export ORACLE_SID=PROD1
echo "db_name=PROD1" > $ORACLE_HOME/dbs/initPROD1.ora
mkdir -p /u01/app/oracle/{oradata/PROD1,admin/PROD1/adump,fra}

rman CATALOG /@RCATDB
```
```
SET DBID <dbid_de_PROD1>;                 -- el anotado en la sección 2
STARTUP NOMOUNT PFILE='?/dbs/initPROD1.ora';
RESTORE SPFILE TO '?/dbs/spfilePROD1.ora' FROM AUTOBACKUP;
SHUTDOWN ABORT;
-- Ajustar en el spfile rutas que difieran (control_files, db_recovery_file_dest,
-- db_create_file_dest, memoria) con STARTUP NOMOUNT + ALTER SYSTEM ... SCOPE=SPFILE
STARTUP NOMOUNT;
RESTORE CONTROLFILE FROM AUTOBACKUP;
ALTER DATABASE MOUNT;
-- Si las rutas de datafiles difieren del original:
RUN {
  SET NEWNAME FOR DATABASE TO '/u01/app/oracle/oradata/PROD1/%b';
  RESTORE DATABASE;
  SWITCH DATAFILE ALL;
  RECOVER DATABASE;
}
ALTER DATABASE OPEN RESETLOGS;
```

**Criterios de éxito (todos):**
1. La base abre con `OPEN RESETLOGS` sin intervención más allá del guion.
2. Una consulta de negocio devuelve datos coherentes con la hora del último archivelog respaldado.
3. **Cronometrar todo el proceso**: ese es su **RTO real**. Documentarlo.
4. La diferencia entre la hora del desastre simulado y el último dato recuperado es ≤ frecuencia del job `bk_arch` (1–2 h): ese es su **RPO real**.

```
-- Limpieza: la base de prueba NO debe quedar registrada como nueva incarnación de producción.
-- En la sesión CATALOG, verificar tras la prueba:
LIST INCARNATION OF DATABASE PROD1;
-- La incarnación CURRENT de producción debe seguir siendo la original.
-- Borrar la base de prueba (dbca -deleteDatabase o borrado manual de ficheros).
```

### 4.1 Prueba de recuperación a un punto en el tiempo (error humano)

Mismo procedimiento añadiendo antes del RESTORE:
```
SET UNTIL TIME "TO_DATE('<fecha-hora anterior al error>','YYYY-MM-DD HH24:MI:SS')";
```
**Criterio:** la base abre con los datos tal como estaban en ese instante. Valida su defensa contra el `DELETE sin WHERE`.

---

## 5. Recuperaciones parciales rápidas (sin desastre total)

Probar al menos una vez, contra la base de pruebas restaurada:

```
-- Pérdida de un solo datafile:
RESTORE DATAFILE 4; RECOVER DATAFILE 4;
-- Pérdida del controlfile actual:
RESTORE CONTROLFILE FROM AUTOBACKUP;
```
**Criterio:** ambas operaciones completan usando el catálogo, sin necesitar el controlfile original.

---

## 6. Protección del propio centro

```
-- CEN
LIST BACKUP SUMMARY;                       -- (sesión TARGET / de RCATDB) backup diario presente
```
```bash
ls -lh /backups/RCATDB/rcat_*.dmp          # export del esquema rcat de esta semana
```
**Prueba de rescate del catálogo:** importar el dump en una base auxiliar (`impdp`) y ejecutar `LIST INCARNATION;` conectado a él.
**Prueba sin catálogo (último recurso):** conectar `rman TARGET sys@PROD1` (sin CATALOG) y verificar `LIST BACKUP SUMMARY;` — el controlfile de cada base conserva su metadata reciente; junto con el DBID anotado permite restaurar aun perdiendo el central entero.

---

## 7. Supervisión continua

Verificar que quedan operativas estas alertas:

1. **Fallo de job**: el `run_rman.sh` envía correo si `rc != 0`; probar forzando un fallo (p. ej. parar el listener de una base y lanzar `bk_arch`).
2. **Salud diaria desde el catálogo** (un solo query para TODAS las bases):
```sql
-- sqlplus rcat@RCATDB
SELECT db_name, max(completion_time) ultimo_backup
FROM rc_backup_set_details GROUP BY db_name ORDER BY 2;
-- Alerta si alguna base lleva > 26h sin backup (N1) o > 3h sin archivelog (ajustar a su cron):
SELECT d.name FROM rc_database d
WHERE NOT EXISTS (SELECT 1 FROM rc_backup_set_details b
                  WHERE b.db_name=d.name AND b.completion_time > sysdate-3/24);
```
3. **Espacio del NAS**: alerta del propio NAS al 85% + `df /backups` en el chequeo diario.
4. **FRA local de cada producción**: alerta al 80% de `v$recovery_file_dest`.
5. **Snapshots y réplica externa del NAS**: revisión semanal de que siguen ejecutándose.

---

## 8. Lista de aceptación final

| # | Comprobación | Sección | Resultado esperado | OK |
|---|--------------|---------|--------------------|----|
| 1 | /backups montado y escribible en todos los nodos | 1 | OK | ☐ |
| 2 | Wallet: conexión TARGET+CATALOG a todas las bases | 1 | OK | ☐ |
| 3 | Snapshots NAS + réplica externa activos | 1 | Configurados | ☐ |
| 4 | Todas las bases registradas; DBIDs anotados y guardados | 2 | Completo | ☐ |
| 5 | SHOW ALL correcto por base (retención, autobackup, policy) | 2 | Según diseño | ☐ |
| 6 | N0/N1 recientes; CROSSCHECK limpio; NEED BACKUP vacío | 3.1 | Limpio | ☐ |
| 7 | 0 archivelogs locales > 3 días en cada producción | 3.2 | 0 | ☐ |
| 8 | 0 archivelogs sin respaldar más antiguos que el ciclo | 3.2 | 0 | ☐ |
| 9 | Candado deletion policy verificado | 3.3 | Protege | ☐ |
| 10 | RESTORE ... VALIDATE sin errores; 0 bloques corruptos | 3.4 | OK | ☐ |
| 11 | Simulacro completo en otro host: base abierta | 4 | OK | ☐ |
| 12 | RTO medido y documentado | 4 | ≤ objetivo acordado | ☐ |
| 13 | RPO real ≤ frecuencia de bk_arch | 4 | ≤ 2 h | ☐ |
| 14 | PITR probado (error humano) | 4.1 | OK | ☐ |
| 15 | Restauración parcial (datafile, controlfile) probada | 5 | OK | ☐ |
| 16 | Backup + export del catálogo verificados | 6 | OK | ☐ |
| 17 | Restauración sin catálogo verificada (plan B) | 6 | OK | ☐ |
| 18 | Alertas de fallo, lag de backup y espacio operativas | 7 | Activas | ☐ |

**Criterio de aceptación global:** los 18 puntos marcados con evidencias fechadas archivadas junto a este documento. Repetir el simulacro (puntos 11–14) cada 6 meses y tras cualquier cambio de versión de Oracle, del NAS o de la red.
