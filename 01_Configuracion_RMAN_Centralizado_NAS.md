# Centro de Recuperación Oracle con RMAN Centralizado
## Documento 1: Requisitos y Configuración — Servidor Central (catálogo) y Clientes (bases de producción)

**Arquitectura:** N bases de datos de producción (sin standby) + 1 servidor central con catálogo de recuperación RMAN + NAS en red como almacén de backups.
**Objetivos de diseño:** administración desde un único punto, máximo 3 días de archivelog en los servidores de producción, coste mínimo (sin Data Guard, sin Enterprise Edition obligatoria).

---

## 1. Visión general

```
[BD PROD1]  [BD PROD2]  [BD PRODn]          [Servidor Central]
    |            |           |                    |- BD catálogo RMAN (RCAT, pequeña)
    |            |           |                    |- Scripts y cron centralizados
    +------------+-----------+---------+----------+
                 |  (montaje NFS común)
              [ NAS ]  /backups  ->  backups nivel 0/1 + archivelogs de TODAS las bases
                 |
          (copia externa periódica: disco rotado / nube)  <- recomendado anti-ransomware
```

Flujo: cada job RMAN se lanza **desde el servidor central**, conecta a la base de producción (`TARGET`) y al catálogo (`CATALOG`), y escribe los ficheros directamente en el NAS. Los archivelogs se copian al NAS cada 1–2 horas y se borran de producción a los 3 días **solo si ya están respaldados**.

| Elemento | Nombre de ejemplo | Sustituir por |
|----------|-------------------|----------------|
| Servidor central | `srvcentral` | su hostname |
| BD catálogo | `RCATDB` (servicio `RCATDB`) | — |
| Usuario catálogo | `rcat` | — |
| Bases producción | `PROD1`, `PROD2`, ... | sus DB_NAME |
| NAS | `nas01`, export `/volume1/oracle_bk` | según su modelo |
| Punto de montaje | `/backups` (en todos los servidores) | — |

---

## 2. FASE 1 — Requisitos previos

### 2.1 Servidor central

- Máquina modesta: 2–4 vCPU, 8–16 GB RAM, 100 GB de disco local. Solo aloja la BD del catálogo y los scripts; los backups van al NAS.
- Oracle Database instalado (**Standard Edition 2 es suficiente**; si ya tiene una licencia sobrante, sirve). La BD del catálogo ocupará pocos GB.
- Cliente SQL*Net con conectividad a todas las bases de producción (puerto 1521).

### 2.2 El NAS

Requisitos para que el NAS sea válido como almacén de backups Oracle:

1. **Soporte NFS** (v3 o v4). Preferible a SMB/CIFS para cargas Oracle en Linux.
2. **Capacidad**: estimación por base = `tamaño_BD × 1,5` (nivel 0 comprimido ≈ 30–50% + niveles 1 + archivelogs de la ventana). Fórmula global orientativa:
   `Espacio NAS ≈ Σ(tamaño de cada BD) × 1,5 × (ventana_recuperación/7 + 0,5)`
   Ejemplo: 3 bases de 200 GB con ventana de 7 días ≈ 3 × 200 × 1,5 × 1,5 ≈ **1,4 TB**. Dimensione con 30% de margen.
3. **Red**: idealmente interfaz dedicada o VLAN de backup a 1 Gbps mínimo (10 Gbps si las bases superan el TB, para que el nivel 0 semanal quepa en su ventana: a 1 Gbps se copian ~400 GB/hora reales).
4. **Muy recomendado — protección anti-ransomware**: si el NAS soporta *snapshots inmutables* o versiones de solo lectura (la mayoría de NAS actuales lo permiten), active snapshots diarios del volumen de backups con retención de 7–14 días. Es la defensa clave: aunque un atacante cifre `/backups` desde la red, los snapshots del propio NAS quedan intactos.
5. **Copia externa** (regla 3-2-1): programe en el NAS una réplica periódica del volumen a un destino fuera de la sala (otro NAS, disco USB rotado o nube). El NAS resuelve el desastre lógico y de servidor; la copia externa resuelve el desastre físico de la sala.

**Comprobación:**
```bash
# Desde cualquier servidor Oracle
showmount -e nas01          # debe listar el export /volume1/oracle_bk
ping -c 3 nas01
```

### 2.3 Servidores de producción (clientes)

- Cada base en modo **ARCHIVELOG** (imprescindible; se activa en la Fase 4).
- Espacio local suficiente para 3 días de archivelogs + pico (dimensionar con la consulta de la sección 5.1).
- UID/GID del usuario `oracle` **idéntico en todos los servidores** (o mapeo NFS equivalente), para que todos puedan leer/escribir en `/backups`:
```bash
id oracle      # ejecutar en todos los nodos: uid y gid deben coincidir
```

---

## 3. FASE 2 — Configuración del NAS y montaje NFS

### 3.1 En el NAS

- Crear volumen/carpeta compartida `oracle_bk` exportada por NFS.
- Permitir acceso solo a las IPs de los servidores Oracle (central y producción).
- Opciones del export: `rw`, `no_root_squash` (o mapeo al uid de oracle), `sync`.
- Activar snapshots del volumen (diarios, retención 7–14 días) si el modelo lo soporta.

### 3.2 En TODOS los servidores (central y producción)

```bash
# Como root
mkdir -p /backups
# Añadir a /etc/fstab (opciones recomendadas por Oracle para backups sobre NFS):
nas01:/volume1/oracle_bk  /backups  nfs  rw,bg,hard,nointr,tcp,vers=3,timeo=600,rsize=32768,wsize=32768,actimeo=0  0 0

mount /backups
mkdir -p /backups/{PROD1,PROD2,RCATDB,logs,scripts}
chown -R oracle:oinstall /backups
```

**Comprobación (en cada servidor, como oracle):**
```bash
df -h /backups                          # montado, tamaño del NAS visible
touch /backups/test_$(hostname) && ls -l /backups/test_*   # escritura OK
dd if=/dev/zero of=/backups/speedtest bs=1M count=1024 oflag=direct; rm /backups/speedtest
# Anote el MB/s: le sirve para estimar duración de backups y restauraciones
```

---

## 4. FASE 3 — Servidor central: base de datos del catálogo

### 4.1 Crear la base RCATDB

Con DBCA, una base mínima (1–2 GB de SGA, un solo tablespace de datos es suficiente). Registrarla en el listener del central.

**Comprobación:**
```bash
lsnrctl status              # servicio RCATDB registrado
sqlplus system@RCATDB       # conexión OK
```

### 4.2 Crear el propietario del catálogo

```sql
-- En RCATDB como SYSTEM
CREATE TABLESPACE rcat_ts DATAFILE SIZE 2G AUTOEXTEND ON NEXT 512M MAXSIZE 10G;
CREATE USER rcat IDENTIFIED BY "<PwdRcat_Segura>"
  DEFAULT TABLESPACE rcat_ts QUOTA UNLIMITED ON rcat_ts;
GRANT recovery_catalog_owner, create session TO rcat;
```

### 4.3 Crear el catálogo

```bash
rman CATALOG rcat/<PwdRcat_Segura>@RCATDB
```
```
CREATE CATALOG;
EXIT;
```

**Comprobación:**
```sql
-- En RCATDB como rcat
SELECT * FROM rcver;        -- muestra la versión del esquema del catálogo
```

### 4.4 tnsnames.ora del servidor central

Debe contener una entrada por cada base de producción más el catálogo:

```
RCATDB = (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=srvcentral)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=RCATDB)))
PROD1  = (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=srvprod1)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=PROD1)))
PROD2  = (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=srvprod2)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=PROD2)))
```

**Comprobación:** `tnsping PROD1`, `tnsping PROD2`, `tnsping RCATDB` — OK desde el central.

### 4.5 Wallet de credenciales (evita contraseñas en claro en los scripts)

```bash
# En el central, como oracle
mkstore -wrl /home/oracle/wallet -create
mkstore -wrl /home/oracle/wallet -createCredential PROD1 sys <PwdSysProd1>
mkstore -wrl /home/oracle/wallet -createCredential PROD2 sys <PwdSysProd2>
mkstore -wrl /home/oracle/wallet -createCredential RCATDB rcat <PwdRcat_Segura>
```

En `$ORACLE_HOME/network/admin/sqlnet.ora` del central:
```
WALLET_LOCATION = (SOURCE=(METHOD=FILE)(METHOD_DATA=(DIRECTORY=/home/oracle/wallet)))
SQLNET.WALLET_OVERRIDE = TRUE
```

**Comprobación:**
```bash
rman TARGET /@PROD1 CATALOG /@RCATDB     # conecta sin escribir contraseñas
```
> Nota: la conexión TARGET requiere privilegio SYSDBA/SYSBACKUP remoto: cada base de producción debe tener `remote_login_passwordfile=EXCLUSIVE` (valor por defecto) y password file vigente.

---

## 5. FASE 4 — Configuración de cada base de producción (cliente)

Repetir esta fase para cada base (`PROD1`, `PROD2`, ...). Todo puede ejecutarse desde el central conectando por TNS.

### 5.1 Activar ARCHIVELOG y dimensionar los 3 días

```sql
-- sqlplus sys@PROD1 as sysdba
SELECT log_mode FROM v$database;
-- Si NOARCHIVELOG:
SHUTDOWN IMMEDIATE; STARTUP MOUNT; ALTER DATABASE ARCHIVELOG; ALTER DATABASE OPEN;

-- Destino local de archivelogs (disco local del servidor de producción)
ALTER SYSTEM SET db_recovery_file_dest_size = 100G SCOPE=BOTH;   -- ver cálculo abajo
ALTER SYSTEM SET db_recovery_file_dest = '/u02/fra' SCOPE=BOTH;
```

Cálculo del espacio local necesario (3 días + margen):
```sql
SELECT round(sum(blocks*block_size)/1024/1024/1024,1) gb_por_dia
FROM v$archived_log WHERE first_time > sysdate-7 GROUP BY trunc(first_time);
-- db_recovery_file_dest_size >= gb_por_dia_máximo × 3 × 1.5
```

**Comprobación:** `SELECT log_mode FROM v$database;` → ARCHIVELOG.

### 5.2 Advertencia sobre operaciones NOLOGGING

Sin Data Guard no es obligatorio `FORCE LOGGING`, pero cualquier carga `NOLOGGING` (direct path, algunos CREATE INDEX) **no será recuperable desde archivelogs**. Dos opciones: activar `ALTER DATABASE FORCE LOGGING;` (recomendado si el rendimiento lo permite) o vigilarlo con `REPORT UNRECOVERABLE` en las comprobaciones y lanzar un nivel 1 tras cada carga NOLOGGING.

### 5.3 Registrar la base en el catálogo

```bash
# Desde el central
rman TARGET /@PROD1 CATALOG /@RCATDB
```
```
REGISTER DATABASE;
```

**Comprobación:**
```
REPORT SCHEMA;        -- lista todos los datafiles de PROD1: el catálogo ya la conoce
LIST INCARNATION;     -- una incarnación CURRENT
```

### 5.4 Configuración RMAN persistente de cada base

Dentro de la misma sesión RMAN (se repite por base, cambiando la ruta):

```
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF 7 DAYS;
CONFIGURE CONTROLFILE AUTOBACKUP ON;
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '/backups/PROD1/cf_%F';
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '/backups/PROD1/%d_%T_%U' MAXPIECESIZE 32G;
CONFIGURE DEVICE TYPE DISK PARALLELISM 2 BACKUP TYPE TO COMPRESSED BACKUPSET;
CONFIGURE ARCHIVELOG DELETION POLICY TO BACKED UP 1 TIMES TO DISK;
```

Claves del diseño:
- **`RECOVERY WINDOW OF 7 DAYS`**: ventana de viaje en el tiempo **en el NAS**. Su requisito de 3 días aplica a los archivelogs *en producción*; en el NAS 7 días cuesta poco y salva errores humanos detectados tarde. Si el espacio manda, baje a `3 DAYS`.
- **`BACKED UP 1 TIMES TO DISK`**: candado de seguridad — RMAN se negará a borrar de producción un archivelog que no esté ya en el NAS.

**Comprobación:** `SHOW ALL;` refleja los seis parámetros.

---

## 6. FASE 5 — Scripts globales y programación centralizada

Ventaja del catálogo: los scripts se guardan **una sola vez dentro del catálogo** y valen para todas las bases.

### 6.1 Crear los scripts globales (una vez, desde cualquier sesión con CATALOG)

```
CREATE GLOBAL SCRIPT bk_nivel0
COMMENT 'Nivel 0 semanal + archivelogs + purga'
{
  BACKUP AS COMPRESSED BACKUPSET INCREMENTAL LEVEL 0 DATABASE TAG 'NIVEL0'
    PLUS ARCHIVELOG NOT BACKED UP 1 TIMES TAG 'ARCH';
  DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-3';
  DELETE NOPROMPT OBSOLETE;
}

CREATE GLOBAL SCRIPT bk_nivel1
COMMENT 'Nivel 1 diario + archivelogs + purga'
{
  BACKUP AS COMPRESSED BACKUPSET INCREMENTAL LEVEL 1 DATABASE TAG 'NIVEL1'
    PLUS ARCHIVELOG NOT BACKED UP 1 TIMES TAG 'ARCH';
  DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-3';
  DELETE NOPROMPT OBSOLETE;
}

CREATE GLOBAL SCRIPT bk_arch
COMMENT 'Archivelogs cada 1-2 horas hacia el NAS'
{
  BACKUP AS COMPRESSED BACKUPSET ARCHIVELOG ALL NOT BACKED UP 1 TIMES TAG 'ARCH';
}
```

> `DELETE ... COMPLETED BEFORE 'SYSDATE-3'` materializa su regla de 3 días, y la deletion policy de la Fase 4 garantiza que nunca se borre nada no respaldado. Los archivelogs siguen existiendo en el NAS dentro de la ventana de 7 días.

**Comprobación:** `LIST GLOBAL SCRIPT NAMES;` — los tres scripts listados.

### 6.2 Lanzador desde el central

`/backups/scripts/run_rman.sh`:
```bash
#!/bin/bash
# Uso: run_rman.sh <BASE> <script_global>
DB=$1; SCRIPT=$2
. /home/oracle/.bash_profile
LOG=/backups/logs/${DB}_${SCRIPT}_$(date +%Y%m%d_%H%M).log
rman TARGET /@${DB} CATALOG /@RCATDB log=${LOG} <<EOF
RUN { EXECUTE GLOBAL SCRIPT ${SCRIPT}; }
EXIT;
EOF
RC=$?
[ $RC -ne 0 ] && echo "FALLO RMAN ${DB} ${SCRIPT} rc=${RC}" | mail -s "ALERTA BACKUP ${DB}" dba@su-empresa.com
exit $RC
```

### 6.3 Cron del servidor central (único punto de programación)

```
# Nivel 0 semanal (domingo), escalonado por base
00 01 * * 0  /backups/scripts/run_rman.sh PROD1 bk_nivel0
00 03 * * 0  /backups/scripts/run_rman.sh PROD2 bk_nivel0
# Nivel 1 diario (lunes-sábado)
00 01 * * 1-6 /backups/scripts/run_rman.sh PROD1 bk_nivel1
00 03 * * 1-6 /backups/scripts/run_rman.sh PROD2 bk_nivel1
# Archivelogs cada 2 horas (RPO máximo = 2h; baje a cada hora si lo necesita)
15 */2 * * * /backups/scripts/run_rman.sh PROD1 bk_arch
45 */2 * * * /backups/scripts/run_rman.sh PROD2 bk_arch
```

**Comprobación:** ejecutar a mano `run_rman.sh PROD1 bk_nivel0`, revisar el log en `/backups/logs/` y que aparezcan piezas en `/backups/PROD1/`.

---

## 7. FASE 6 — Proteger el propio centro de recuperación

El catálogo y el central también pueden fallar; su pérdida no destruye backups (los controlfiles de cada base conservan su propia metadata reciente), pero conviene protegerlos:

```bash
# Cron diario en el central: backup de la BD del catálogo + export lógico del esquema
30 06 * * * rman TARGET / <<EOF ... BACKUP DATABASE FORMAT '/backups/RCATDB/%d_%T_%U' PLUS ARCHIVELOG; EOF
45 06 * * * expdp rcat/<pwd>@RCATDB schemas=rcat directory=DATA_PUMP_DIR dumpfile=rcat_$(date +\%a).dmp reuse_dumpfiles=y
# y copiar el dump al NAS: cp .../rcat_*.dmp /backups/RCATDB/
```

Guarde además fuera del NAS (documentado en papel/gestor de contraseñas): los **DBID de cada base** (`SELECT dbid, name FROM v$database;`) — imprescindibles para restaurar sin catálogo en el peor de los casos — y las contraseñas del wallet.

**Comprobación:** `LIST BACKUP OF DATABASE;` en RCATDB y dump del día presente en el NAS.

---

## 8. Resumen de responsabilidades

| Tarea | Servidor central | Cada producción | NAS |
|-------|------------------|-----------------|-----|
| BD catálogo RCAT | ✔ | — | — |
| Scripts globales + cron + wallet | ✔ | — | — |
| ARCHIVELOG + FRA local 3 días | — | ✔ | — |
| Password file / passwordfile EXCLUSIVE | — | ✔ | — |
| Montaje /backups | ✔ | ✔ | export NFS |
| Ficheros de backup y archivelog | — | — | ✔ |
| Snapshots inmutables + réplica externa | — | — | ✔ |

Complete la implantación con el **Documento 2: Comprobaciones finales**, que incluye el simulacro de desastre (restauración completa de una base en otro servidor usando solo el catálogo y el NAS).
