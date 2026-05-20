#!/usr/bin/tclsh
# HammerDB TPC-C timed run for PostgreSQL.
# Reads connection + run params from environment variables (see run-hammerdb-tpcc.sh).

dbset db pg
dbset bm TPC-C

diset connection pg_host        $env(PG_HOST)
diset connection pg_port        $env(PG_PORT)
diset connection pg_sslmode     $env(PG_SSLMODE)

diset tpcc pg_dbase             $env(PG_DBASE)
diset tpcc pg_user              $env(PG_USER)
diset tpcc pg_pass              $env(PG_PASS)
diset tpcc pg_driver            timed
diset tpcc pg_rampup            $env(PG_RAMPUP)
diset tpcc pg_duration          $env(PG_DURATION)
diset tpcc pg_allwarehouse      true
diset tpcc pg_timeprofile       true
diset tpcc pg_storedprocs       false

puts "=== HammerDB TPC-C run: vu=$env(PG_NUM_VU) rampup=$env(PG_RAMPUP)m duration=$env(PG_DURATION)m target=$env(PG_HOST):$env(PG_PORT)/$env(PG_DBASE) ==="

loadscript
vuset vu $env(PG_NUM_VU)
vuset logtotemp 1
vuset unique 1
vucreate
vurun

# Wait for the timed driver script to complete (rampup + duration), then a small grace period.
# vustatus returns a multi-line "<vu_id> = FINISH SUCCESS" report, not the literal
# "FINISHED SUCCESS" — match the MONITOR vuser (vuser 1) being done by looking
# for its TEST RESULT line in /tmp/hammerdb_*.log, with a hard timeout.
set total_secs [expr {($env(PG_RAMPUP) + $env(PG_DURATION)) * 60 + 60}]
puts "waiting up to ${total_secs}s for run to finish"
set elapsed 0
set finished 0
while {$elapsed < $total_secs && !$finished} {
    after 5000
    incr elapsed 5
    foreach f [glob -nocomplain /tmp/hammerdb_*.log] {
        set fh [open $f r]
        set contents [read $fh]
        close $fh
        if {[string match "*TEST RESULT*" $contents]} { set finished 1; break }
    }
}
puts "wait loop exited finished=$finished elapsed=${elapsed}s"
vudestroy

puts "=== run complete status=[vustatus] ==="
# hammerdbcli auto otherwise drops to an interactive prompt — force exit so
# `docker run --rm` actually returns and the wrapper script proceeds.
exit
