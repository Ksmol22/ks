Plan de investigación: lentitud, errores 500 y desconexiones en Bizagi 11.2.5
Sep 29, 2026 · @Kevin
Resumen
La causa más probable está en SQL Server (bloqueos, índices, estadísticas o crecimiento de tablas de Bizagi) y en el pool de conexiones entre IIS y la base de datos. Con un solo servidor IIS, un solo SQL Server y problemas desde hace 5 meses, la pregunta clave es qué cambió en ese momento.
Contexto:
• Bizagi Studio y Management Console en versión 11.2.5.0811.
• La documentación oficial marca la versión 11.2.5 como deprecada: no recibe parches y hay que planificar la migración.
• Síntomas: lentitud, errores HTTP 500, desconexiones de la base de datos y fallos en flujos.
• Infraestructura: 1 servidor IIS, SQL Server. Existe el diagnóstico Bizagi_Dg.xlsx generado con la Bizagi Diagnostics Tool.
Hipótesis, de más a menos probable:
1. Base de datos degradada: índices fragmentados, estadísticas viejas, bloqueos, tablas de auditoría o cola asíncrona muy grandes.
2. Agotamiento del pool de conexiones o timeouts entre IIS y SQL Server.
3. Recursos insuficientes o mal configurados: memoria de SQL Server, latencia de disco, reciclajes del Application Pool.
4. Cambio de entorno hace 5 meses: parches de Windows, .NET, TLS, firewall, antivirus.
5. Integraciones externas con timeouts o credenciales vencidas que rompen flujos.
6. Defectos conocidos de una versión sin soporte.
Fase 1: Línea base y alcance (día 1)
El objetivo es acotar cuándo, dónde y desde qué cambio empezó el problema, antes de tocar nada.
[ ] Fijar la fecha aproximada de inicio (hace unos 5 meses) y los horarios de mayor lentitud.
[ ] Listar qué módulos, procesos y usuarios se ven afectados y cuáles no.
[ ] Revisar el historial de cambios de esa fecha: Windows Update, parches de SQL Server y .NET, cambios de firewall o TLS, migraciones, nuevos usuarios, nuevas integraciones, despliegues de procesos.
[ ] Revisar el Bizagi_Dg.xlsx contra los requisitos de la versión 11.2.5: sistema operativo, .NET, IIS, versión de SQL Server, RAM y CPU.
[ ] Medir el volumen actual: usuarios concurrentes, casos activos, casos históricos, tamaño de la base de datos.
[ ] Respaldar la base de datos y la configuración de IIS antes de cualquier cambio.
Comando útil para ver actualizaciones instaladas (PowerShell):
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 30 HotFixID, Description, InstalledOn
Fase 2: Diagnóstico de SQL Server (días 1 a 3)
Ejecutar los scripts durante una ventana de lentitud para capturar el estado real. Guardar cada resultado con fecha y hora.
Bloqueos activos
SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time,
       DB_NAME(r.database_id) AS bd, t.text
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.blocking_session_id <> 0;
Consultas más costosas por CPU
SELECT TOP 20
       qs.total_worker_time / qs.execution_count AS cpu_promedio,
       qs.total_elapsed_time / qs.execution_count AS duracion_promedio,
       qs.execution_count, t.text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
ORDER BY cpu_promedio DESC;
Esperas dominantes (qué recurso frena al servidor)
SELECT TOP 10 wait_type, wait_time_ms, waiting_tasks_count
FROM sys.dm_os_wait_stats
WHERE wait_type NOT LIKE '%SLEEP%' AND wait_type NOT IN ('BROKER_TASK_STOP','XE_TIMER_EVENT','LAZYWRITER_SLEEP','SQLTRACE_BUFFER_FLUSH','REQUEST_FOR_DEADLOCK_SEARCH','CHECKPOINT_QUEUE','DIRTY_PAGE_POLL')
ORDER BY wait_time_ms DESC;
Lectura rápida: PAGEIOLATCH_* indica disco lento; LCK_M_* indica bloqueos; CXPACKET indica paralelismo; RESOURCE_SEMAPHORE indica falta de memoria.
Tablas más grandes (buscar crecimiento anormal en tablas de Bizagi como auditoría, cola asíncrona, tareas y casos)
SELECT TOP 20 t.name AS tabla, SUM(p.rows) AS filas,
       SUM(a.total_pages) * 8 / 1024 AS mb_total
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
JOIN sys.allocation_units a ON a.container_id = p.partition_id
GROUP BY t.name ORDER BY mb_total DESC;
Fragmentación de índices
SELECT TOP 50 OBJECT_NAME(ips.object_id) AS tabla, i.name AS indice,
       ips.avg_fragmentation_in_percent AS frag_pct, ips.page_count
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
JOIN sys.indexes i ON i.object_id = ips.object_id AND i.index_id = ips.index_id
WHERE ips.page_count > 1000 AND ips.avg_fragmentation_in_percent > 30
ORDER BY ips.avg_fragmentation_in_percent DESC;
Estadísticas desactualizadas
SELECT TOP 50 OBJECT_NAME(s.object_id) AS tabla, s.name AS estadistica,
       sp.last_updated, sp.rows, sp.modification_counter
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
ORDER BY sp.modification_counter DESC;
Memoria, archivos de datos y log
-- Memoria configurada
SELECT name, value_in_use FROM sys.configurations
WHERE name IN ('max server memory (MB)','max degree of parallelism','cost threshold for parallelism');

-- Latencia por archivo (objetivo: datos < 20 ms, log < 5 ms)
SELECT DB_NAME(vfs.database_id) AS bd, mf.physical_name,
       vfs.io_stall_read_ms / NULLIF(vfs.num_of_reads,0) AS lat_lectura_ms,
       vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes,0) AS lat_escritura_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id;

-- Uso del log de transacciones
DBCC SQLPERF(LOGSPACE);
Conexiones y errores del motor
SELECT login_name, host_name, program_name, COUNT(*) AS sesiones
FROM sys.dm_exec_sessions WHERE is_user_process = 1
GROUP BY login_name, host_name, program_name ORDER BY sesiones DESC;

EXEC xp_readerrorlog 0, 1, N'error';
EXEC xp_readerrorlog 0, 1, N'deadlock';
Qué buscar: max server memory en el valor por defecto (2147483647), latencia de disco alta, log de transacciones lleno o creciendo sin control, tablas con millones de filas, índices con más de 30% de fragmentación y estadísticas sin actualizar hace meses.
Fase 3: IIS, Application Pool y errores 500 (días 2 a 4)
Un error 500 solo dice que el servidor falló. La causa real está en los logs, así que el objetivo es agrupar los 500 por URL, hora y mensaje de error.
Pasos
1. Copiar los logs de IIS (C:\inetpub\logs\LogFiles\W3SVC*) de las últimas semanas y filtrar sc-status = 500.
2. Agrupar por URL y por hora para ver si los errores se concentran en un módulo, un horario o un pico de usuarios.
3. Revisar time-taken alto (más de 30 segundos) en las mismas URLs: suele preceder a los timeouts.
4. Abrir el Visor de eventos, secciones Application y System, y buscar errores de .NET Runtime, ASP.NET, WAS y Bizagi.
5. Revisar el Application Pool: reciclajes, caídas del worker process, límite de memoria privada y timeouts.
6. Revisar los logs propios de Bizagi (Work Portal, Scheduler, traza de la Management Console) y activar temporalmente el detalle de errores en un entorno controlado.
7. Anotar el texto exacto del error de fondo. Los más comunes:
    ◦ Timeout expired o connection was forcibly closed: base de datos o red.
    ◦ Max pool size was reached: agotamiento del pool de conexiones.
    ◦ Deadlock victim: bloqueos en SQL Server.
    ◦ OutOfMemoryException: memoria del proceso.
    ◦ Errores de servicios web o certificados: integraciones externas.
Análisis rápido de logs de IIS con PowerShell
$logs = Get-ChildItem "C:\inetpub\logs\LogFiles\W3SVC1\*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 14
$datos = foreach ($f in $logs) {
  $campos = ((Get-Content $f | Where-Object { $_ -like '#Fields:*' } | Select-Object -First 1) -replace '#Fields: ','') -split ' '
  Get-Content $f | Where-Object { $_ -notlike '#*' } | ConvertFrom-Csv -Delimiter ' ' -Header $campos
}
# Errores 500 por URL
$datos | Where-Object { $_.'sc-status' -eq '500' } |
  Group-Object 'cs-uri-stem' | Sort-Object Count -Descending | Select-Object -First 20 Count, Name
# Peticiones más lentas (más de 30 s)
$datos | Where-Object { [int]$_.'time-taken' -gt 30000 } |
  Group-Object 'cs-uri-stem' | Sort-Object Count -Descending | Select-Object -First 20 Count, Name
Monitoreo con PerfMon en el servidor IIS (registrar durante al menos una semana, cada 30 segundos)
• Processor(_Total)\% Processor Time
• Memory\Available MBytes
• Process(w3wp)\Private Bytes
• ASP.NET Applications\Requests/Sec y Request Execution Time
• .NET CLR Memory\% Time in GC
• .NET Data Provider for SqlServer\NumberOfPooledConnections
Configuración a revisar: Max Pool Size y Connect Timeout en la cadena de conexión, reciclaje del Application Pool (evitar horas laborales), Idle Time-out, y exclusiones del antivirus para las carpetas de Bizagi, los temporales de ASP.NET y los archivos de la base de datos.
Fase 4: Desconexiones, red y conexiones a la base de datos (días 3 a 5)
Las desconexiones intermitentes entre IIS y SQL Server casi siempre vienen de red, pool de conexiones, TLS o credenciales. Se descartan en este orden:
Causa posible
Cómo comprobarlo
Señal de que es esta
Pool de conexiones agotado
Contador NumberOfPooledConnections y sesiones por programa en SQL Server
Error Max pool size was reached; sesiones que solo crecen
Conexiones huérfanas o transacciones largas
sys.dm_tran_active_transactions y sesiones con open_transaction_count > 0
Sesiones dormidas con transacciones abiertas
Red o firewall que corta conexiones inactivas
Test-NetConnection y ping continuo entre IIS y SQL; revisar timeouts de firewall
Error forcibly closed a horas de baja actividad
TLS o drivers cliente tras un parche
Log de errores de SQL Server y Visor de eventos (Schannel)
Fallos que empezaron tras una actualización de Windows
Reinicios o caídas del motor
xp_readerrorlog, Visor de eventos del servidor SQL
Mensajes de inicio o de fallo de recursos
Cuenta de servicio o login con problema
Eventos de seguridad, cuenta bloqueada o contraseña vencida
Errores de login que aparecen y desaparecen
Antivirus escaneando
Exclusiones configuradas en ambos servidores
Picos de CPU de procesos del antivirus
Comandos útiles
# Latencia y conectividad desde IIS hacia SQL Server (ajustar nombre y puerto)
Test-NetConnection -ComputerName SERVIDOR_SQL -Port 1433
ping SERVIDOR_SQL -t

# Errores de Schannel (TLS) recientes
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Schannel'} -MaxEvents 50 | Format-Table TimeCreated, Id, Message -Wrap
-- Transacciones abiertas más antiguas
DBCC OPENTRAN;

-- Sesiones dormidas con transacción abierta
SELECT session_id, login_name, host_name, program_name, last_request_end_time, open_transaction_count
FROM sys.dm_exec_sessions
WHERE open_transaction_count > 0 AND status = 'sleeping';
Comprobaciones adicionales: sincronización horaria entre servidores, resolución DNS estable, certificados vigentes, y que IIS y SQL Server estén en la misma red o segmento sin saltos innecesarios.
Fase 5: Fallos en flujos, Scheduler y procesos asíncronos (días 4 a 6)
Los flujos suelen fallar como consecuencia de los problemas de base de datos o de integración, no por el diseño del proceso. Hay que comprobar si el fallo es siempre el mismo o es aleatorio.
[ ] Listar los flujos que fallan y anotar en qué actividad, regla o integración se detienen.
[ ] Comprobar si el fallo es reproducible (siempre en la misma actividad) o intermitente (apunta a base de datos, red o timeouts).
[ ] Revisar en la Management Console el estado del Scheduler y de los procesos asíncronos: tareas atascadas, reintentos, cola creciente.
[ ] Revisar las tablas de la cola asíncrona y de casos con errores: cuántos registros pendientes o fallidos hay y cuál es el más antiguo.
[ ] Identificar las integraciones usadas por los flujos fallidos (servicios web, SAP, correo, APIs) y probar cada una de forma aislada.
[ ] Verificar credenciales, certificados y tokens de las integraciones: vencimientos, cambios de contraseña, cambios de URL.
[ ] Revisar timeouts de las integraciones y de las reglas de negocio de larga duración.
[ ] Correlacionar la hora exacta de cada fallo con bloqueos de SQL Server, errores 500 y picos de recursos.
Pregunta guía: si un flujo falla y al reintentar funciona, la causa es de infraestructura (base de datos, red, timeouts). Si falla siempre igual, la causa es de la lógica, los datos o la integración.
Fase 6: Línea de tiempo y causa raíz (días 6 a 7)
La causa raíz es el evento que aparece justo antes de cada síntoma, de forma repetida. Se construye una sola tabla con todas las fuentes ordenadas por hora y se buscan coincidencias.
Hora
Fuente
Evento
Observación
Ejemplo 10:42
IIS
Error 500 en una URL del Work Portal
Timeout expired
Ejemplo 10:41
SQL Server
Bloqueo de 45 s en tabla de tareas
Sesión 87 bloquea la 112
Ejemplo 10:41
PerfMon
CPU de SQL Server al 95%
Coincide con una consulta pesada
Ejemplo 10:43
Bizagi
Flujo detenido en una actividad
Reintento exitoso a las 10:50
Cómo interpretar las coincidencias
• Error 500, bloqueo y pico de CPU al mismo minuto: consulta costosa o falta de índice. Ir a la fase de remediación de base de datos.
• Error 500 y cierre de conexión sin actividad en SQL Server: red, firewall o TLS.
• Errores en horas fijas: tareas programadas, respaldos, reciclaje del pool o mantenimiento del antivirus.
• Errores que crecen con el número de usuarios: falta de recursos o pool de conexiones pequeño.
• Fallos solo en un flujo o integración: problema local de esa integración o de su lógica.
Criterio para dar por identificada la causa: el evento se repite en al menos tres ocurrencias distintas, aplicar la corrección lo elimina en un entorno de pruebas o en una ventana controlada, y los síntomas vuelven a aparecer si se revierte el cambio.
Fase 7: Remediación y mantenimiento (semana 2 en adelante)
Aplicar los cambios de uno en uno, en una ventana de mantenimiento, con respaldo previo y medición antes y después.
Acciones rápidas (bajo riesgo)
1. Mantenimiento de índices y estadísticas (script abajo), programado semanalmente.
2. Configurar max server memory dejando al menos 4 GB libres para el sistema operativo.
3. Ajustar Max Pool Size y Connect Timeout en la cadena de conexión según el número de usuarios concurrentes.
4. Programar el reciclaje del Application Pool fuera de horario laboral.
5. Agregar exclusiones de antivirus para carpetas de Bizagi, temporales de ASP.NET y archivos de la base de datos.
6. Verificar que los respaldos de log de transacciones se ejecuten y que el log no crezca sin control.
Acciones de mediano plazo
1. Optimizar las consultas y reglas de negocio más costosas detectadas en la Fase 2 (índices nuevos solo con análisis previo).
2. Archivar o purgar datos históricos de auditoría, cola asíncrona y casos cerrados, siguiendo el procedimiento recomendado por Bizagi.
3. Añadir timeouts y reintentos controlados en las integraciones externas.
4. Dimensionar recursos (RAM, CPU, discos rápidos) según el volumen medido.
5. Configurar alertas de monitoreo: bloqueos largos, uso de disco, CPU, errores 500 por hora y cola asíncrona creciente.
Acciones estratégicas
1. Abrir un caso de soporte con Bizagi adjuntando Bizagi_Dg.xlsx, los logs y la línea de tiempo de la Fase 6.
2. Planificar la migración desde 11.2.5 (deprecada) a una versión con soporte, con entorno de pruebas y plan de retorno.
3. Separar la base de datos y el servidor web en máquinas con recursos dedicados si hoy comparten carga.
Script de mantenimiento de índices y estadísticas
-- Reorganiza (5-30%) o reconstruye (>30%) índices fragmentados y actualiza estadísticas.
-- Ejecutar fuera de horario y con respaldo previo.
DECLARE @sql NVARCHAR(MAX) = N'';
SELECT @sql += CASE
    WHEN ips.avg_fragmentation_in_percent > 30
      THEN N'ALTER INDEX ' + QUOTENAME(i.name) + N' ON ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N' REBUILD;' + CHAR(10)
    ELSE N'ALTER INDEX ' + QUOTENAME(i.name) + N' ON ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N' REORGANIZE;' + CHAR(10)
  END
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
JOIN sys.indexes i ON i.object_id = ips.object_id AND i.index_id = ips.index_id
JOIN sys.tables t ON t.object_id = ips.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE ips.page_count > 1000 AND ips.avg_fragmentation_in_percent > 5 AND i.name IS NOT NULL;

PRINT @sql;              -- revisar primero
-- EXEC sp_executesql @sql;   -- ejecutar tras revisar

EXEC sp_updatestats;
Validación: repetir las consultas de la Fase 2 y las mediciones de la Fase 3, comparar contra la línea base, hacer una prueba de carga con usuarios reales en horario pico y mantener el monitoreo al menos 30 días.
Cronograma y responsables
Las fechas son relativas al inicio de la investigación. Completar la columna de responsable según el equipo.
Días
Fase
Entregable
Responsable
1
Fase 1: línea base
Lista de cambios de los últimos 5 meses y respaldos hechos

1 a 3
Fase 2: SQL Server
Resultados de los scripts guardados con fecha y hora

2 a 4
Fase 3: IIS y errores 500
Errores 500 agrupados por URL, hora y mensaje de fondo

3 a 5
Fase 4: desconexiones y red
Causa descartada o confirmada por cada fila de la tabla

4 a 6
Fase 5: flujos
Lista de flujos fallidos con actividad y causa

6 a 7
Fase 6: causa raíz
Línea de tiempo y causa raíz documentada

8 a 14
Fase 7: remediación
Cambios aplicados, medición antes y después

14 a 30
Validación y migración
Monitoreo activo, caso con Bizagi y plan de migración

Información que hay que reunir y adjuntar al caso de soporte de Bizagi:
[ ] Bizagi_Dg.xlsx actualizado.
[ ] Logs de IIS y del Visor de eventos de las horas con fallos.
[ ] Resultados de las consultas de la Fase 2.
[ ] Línea de tiempo de la Fase 6.
[ ] Versión exacta de SQL Server, Windows Server y .NET.
[ ] Lista de cambios recientes en el entorno.