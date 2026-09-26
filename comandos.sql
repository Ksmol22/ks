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