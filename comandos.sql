$psql = "C:\Program Files\PostgreSQL\17\bin\psql.exe"
foreach ($p in 5432,5433,5434) {
  "===== Puerto $p ====="
  & $psql -U postgres -p $p -d postgres `
    -c "SELECT version();" `
    -c "SHOW data_directory;" `
    -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE NOT datistemplate;" `
    -c "SELECT datname, usename, client_addr, count(*) FROM pg_stat_activity WHERE datname IS NOT NULL GROUP BY 1,2,3;"
}


& "C:\Program Files\PostgreSQL\17\bin\psql.exe" -U postgres -p 5433 -d postgres -W -c "SELECT version();" -c "SHOW data_directory;" -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE NOT datistemplate;"

SELECT datname, numbackends, xact_commit, stats_reset
FROM pg_stat_database WHERE datname NOT LIKE 'template%';


Get-PSDrive -PSProvider FileSystem
"C:\PostgreSQL\data\pg10","C:\Program Files\PostgreSQL\14\data","C:\Program Files\PostgreSQL\17\data" | % {
  "{0}  {1:N1} GB" -f $_, ((gci $_ -Recurse -File -ea 0 | measure Length -Sum).Sum/1GB) }


  -- Plan


  Get-Volume -DriveLetter E

  $b = "C:\Program Files\PostgreSQL\18\bin"
mkdir E:\pgmig
& "$b\pg_dumpall.exe" -U postgres -p 5433 --globals-only -f E:\pgmig\globals_14.sql
& "$b\pg_dump.exe" -U postgres -p 5433 -Fd -j 4 -d "BSNC-Provisiones" -f E:\pgmig\provisiones_14


& "$b\psql.exe" -U postgres -p 5435 -f E:\pgmig\globals_14.sql
& "$b\createdb.exe" -U postgres -p 5435 "BSNC-Provisiones"
& "$b\pg_restore.exe" -U postgres -p 5435 -j 4 -d "BSNC-Provisiones" E:\pgmig\provisiones_14


& "C:\Program Files\PostgreSQL\17\bin\psql.exe" -U postgres -p 5433 -W -c "SHOW lc_collate;"

& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -U postgres -p 5435 -W -c "SHOW lc_collate;"

-- Diagnostico 

Get-Service postgresql-x64-18
netstat -ano | findstr :543
Get-ChildItem E:\PostgreSQL\18\data | Select -First 10

Get-ChildItem E:\PostgreSQL\18\data\log | Sort LastWriteTime | Select -Last 1 | Get-Content -Tail 30