#!/usr/bin/tclsh
# HammerDB TPC-C schema build for PostgreSQL.
# Reads connection + sizing params from environment variables (see run-hammerdb-tpcc.sh).

dbset db pg
dbset bm TPC-C

diset connection pg_host        $env(PG_HOST)
diset connection pg_port        $env(PG_PORT)
diset connection pg_sslmode     $env(PG_SSLMODE)

diset tpcc pg_count_ware        $env(PG_COUNT_WARE)
diset tpcc pg_num_vu            $env(PG_BUILD_VU)
diset tpcc pg_superuser         $env(PG_SUPERUSER)
diset tpcc pg_superuserpass     $env(PG_SUPERUSERPASS)
diset tpcc pg_defaultdbase      $env(PG_DEFAULT_DBASE)
diset tpcc pg_dbase             $env(PG_DBASE)
diset tpcc pg_user              $env(PG_USER)
diset tpcc pg_pass              $env(PG_PASS)
diset tpcc pg_storedprocs       false
diset tpcc pg_partition         false

puts "=== HammerDB TPC-C build: warehouses=$env(PG_COUNT_WARE) build_vu=$env(PG_BUILD_VU) target=$env(PG_HOST):$env(PG_PORT)/$env(PG_DBASE) ==="

buildschema
waittocomplete

puts "=== build complete ==="
exit
