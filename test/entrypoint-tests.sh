#!/bin/sh
# Startup policy tests for litestream-entrypoint, using a fake litestream CLI.
# Run only inside a disposable test container, with an empty volume at /backup.
# Literal quotes and backslashes in the exported settings are intended test inputs.
# shellcheck disable=SC2089,SC2090
set -eu
[ "${LITESTREAM_CONTAINER_TESTS:-}" = 1 ] && [ -f /.dockerenv ] || exit 1

mkdir -p /tmp/fake-bin
cat > /tmp/fake-bin/litestream <<'FAKE'
#!/bin/sh
set -eu
echo "$*" >> /tmp/entrypoint-trace
command=$1
shift
output=
optional=false
once=false
config=
exec_command=
source=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output=$2; shift ;;
        -config) config=$2; shift ;;
        -exec) exec_command=$2; shift ;;
        -if-replica-exists) optional=true ;;
        -once) once=true ;;
        *) source=$1 ;;
    esac
    shift
done
[ -z "$config" ] || [ -r "$config" ]
case "$command" in
    restore)
        case "$source" in
            file://*)
                if [ "$FAKE_VALIDATION_FAIL" = true ]; then
                    printf 'invalid database' > "$output"
                    exit 1
                fi
                cp "${output%/*}/initial.db" "$output"
                exit 0
                ;;
        esac
        [ -n "$config" ]
        case "$FAKE_RESTORE" in
            success) printf 'restored database' > "$output" ;;
            absent) [ "$optional" = true ] || exit 1 ;;
            failure) printf 'partial database' > "$output"; exit 1 ;;
            empty) : > "$output" ;;
            *) exit 2 ;;
        esac
        ;;
    replicate)
        if [ "$once" = true ]; then
            if [ -n "$config" ]; then
                # Backup of an imported database: the configured replica must read
                # the validated copy, never the not-yet-published db_path.
                case "$LITESTREAM_DB_PATH" in
                    */.restore.*/restored.db) [ -s "$LITESTREAM_DB_PATH" ] ;;
                    *) exit 3 ;;
                esac
                echo "$config" > /tmp/import-backup-config
                [ "$FAKE_BACKUP_FAIL" = false ]
            else
                [ "$FAKE_IMPORT_FAIL" = false ]
            fi
            exit $?
        fi
        [ "$Storage__BasePath" = /app/.storage ]
        [ "$APP_DATABASE_CONNECTION" = 'application-specific setting' ]
        [ "$exec_command" = 'sample-app --label "two words"' ]
        [ -n "$config" ]
        {
            echo "config=$config"
            echo "db=$LITESTREAM_DB_PATH"
            echo "sync=$LITESTREAM_SYNC_INTERVAL"
            echo "snapshot=$LITESTREAM_SNAPSHOT_INTERVAL"
            echo "retention=$LITESTREAM_SNAPSHOT_RETENTION"
        } > /tmp/app-started
        ;;
    *) exit 2 ;;
esac
FAKE
chmod +x /tmp/fake-bin/litestream

# Started directly, without Litestream, only when replication is disabled.
cat > /tmp/fake-bin/sample-app <<'FAKE'
#!/bin/sh
set -eu
[ "$#" -eq 2 ] && [ "$1" = --label ] && [ "$2" = 'two words' ]
echo direct > /tmp/app-started
FAKE
chmod +x /tmp/fake-bin/sample-app
export PATH="/tmp/fake-bin:$PATH"

printf 'dbs: []\n' > /tmp/custom-litestream.yml

reset_case() {
    rm -rf /data /import
    mkdir /data /import
    rm -f /tmp/app-started /tmp/entrypoint-trace /tmp/import-backup-config
    rm -f /backup/sample.db /backup/sample.db.imported /backup/sample.db-wal
    unset LITESTREAM_CONFIG_PATH LITESTREAM_REPLICA_TYPE
    unset LITESTREAM_SYNC_INTERVAL LITESTREAM_SNAPSHOT_INTERVAL LITESTREAM_SNAPSHOT_RETENTION
    unset LITESTREAM_S3_BUCKET LITESTREAM_S3_PATH LITESTREAM_S3_ENDPOINT LITESTREAM_S3_REGION
    unset LITESTREAM_S3_FORCE_PATH_STYLE LITESTREAM_S3_SKIP_VERIFY
    export Storage__BasePath=/app/.storage
    export APP_DATABASE_CONNECTION='application-specific setting'
    export LITESTREAM_DB_PATH=/data/sample.db
    export LITESTREAM_EXEC='sample-app --label "two words"'
    export LITESTREAM_ALLOW_INITIALIZE=false
    export FAKE_RESTORE=success
    export FAKE_IMPORT_FAIL=false FAKE_VALIDATION_FAIL=false FAKE_BACKUP_FAIL=false
}

use_s3() {
    export LITESTREAM_REPLICA_TYPE=s3
    export LITESTREAM_S3_BUCKET=backups LITESTREAM_S3_PATH=sample/db
    export LITESTREAM_S3_ENDPOINT=https://s3.example.test
}

run_case() {
    description=$1
    expected=$2
    if /usr/local/bin/litestream-entrypoint > /tmp/entrypoint-output 2>&1; then
        actual=success
    else
        actual=failure
    fi
    if [ "$actual" != "$expected" ]; then
        cat /tmp/entrypoint-output
        echo "FAIL: $description (expected $expected, got $actual)" >&2
        exit 1
    fi
    if [ "$expected" = success ]; then
        [ -f /tmp/app-started ]
    else
        [ ! -e /tmp/app-started ]
    fi
    [ -z "$(find /data -name '.restore.*' -print)" ]
    echo "PASS: $description"
}

expect_output() {
    grep -qF -- "$1" /tmp/entrypoint-output || {
        cat /tmp/entrypoint-output
        echo "FAIL: missing output: $1" >&2
        exit 1
    }
}

# Not `! grep`: a negated command does not stop the script under set -e.
expect_no_call() {
    if grep -q -- "$1" /tmp/entrypoint-trace; then
        cat /tmp/entrypoint-trace
        echo "FAIL: unexpected Litestream call: $1" >&2
        exit 1
    fi
}

reset_case
run_case 'restore before application startup' success
[ "$(cat /data/sample.db)" = 'restored database' ]
grep -q -- '-integrity-check quick' /tmp/entrypoint-trace
grep -qx 'config=/etc/litestream/file.yml' /tmp/app-started

reset_case
run_case 'replication settings have defaults' success
grep -qx 'sync=10s' /tmp/app-started
grep -qx 'snapshot=24h' /tmp/app-started
grep -qx 'retention=168h' /tmp/app-started

reset_case
export LITESTREAM_SYNC_INTERVAL=1m LITESTREAM_SNAPSHOT_INTERVAL=6h LITESTREAM_SNAPSHOT_RETENTION=720h
run_case 'replication settings can be overridden at run time' success
grep -qx 'sync=1m' /tmp/app-started
grep -qx 'snapshot=6h' /tmp/app-started
grep -qx 'retention=720h' /tmp/app-started

reset_case
printf 'existing database' > /data/sample.db
export FAKE_RESTORE=failure
run_case 'preserve an existing local database without restore' success
[ "$(cat /data/sample.db)" = 'existing database' ]
expect_no_call '^restore '

reset_case
export FAKE_RESTORE=absent
run_case 'no backup fails closed by default' failure
[ ! -e /data/sample.db ]

reset_case
export FAKE_RESTORE=absent LITESTREAM_ALLOW_INITIALIZE=true
run_case 'explicit first deployment allows a missing backup' success
[ ! -e /data/sample.db ]

reset_case
export LITESTREAM_ALLOW_INITIALIZE=true
run_case 'initialization permission still restores an existing backup' success
[ "$(cat /data/sample.db)" = 'restored database' ]

for initialize in false true; do
    reset_case
    export FAKE_RESTORE=failure LITESTREAM_ALLOW_INITIALIZE=$initialize
    run_case "partial restore failure is not published (initialize=$initialize)" failure
    [ ! -e /data/sample.db ]
    export FAKE_RESTORE=success
    run_case 'retry performs a new restore after failure' success
    [ "$(cat /data/sample.db)" = 'restored database' ]

    reset_case
    export FAKE_RESTORE=empty LITESTREAM_ALLOW_INITIALIZE=$initialize
    run_case "an empty restore result is rejected (initialize=$initialize)" failure
    [ ! -e /data/sample.db ]
done

reset_case
touch /data/sample.db
run_case 'an existing empty database is not initialized' failure

reset_case
touch /data/sample.db-wal
run_case 'orphaned WAL is not replayed onto a restored database' failure

reset_case
export LITESTREAM_ALLOW_INITIALIZE=yes
run_case 'invalid initialization option fails closed' failure

reset_case
export LITESTREAM_REPLICA_TYPE=nfs
run_case 'an unknown replica type is rejected' failure
expect_output 'LITESTREAM_REPLICA_TYPE must be file, s3 or none'

reset_case
export LITESTREAM_REPLICA_TYPE=none FAKE_RESTORE=failure
run_case 'none runs the application directly without Litestream' success
[ "$(cat /tmp/app-started)" = direct ]
[ ! -e /tmp/entrypoint-trace ]
[ ! -e /data/sample.db ]
expect_output 'WARNING: replication is disabled'

reset_case
export LITESTREAM_REPLICA_TYPE=none LITESTREAM_EXEC=
run_case 'none still requires the application command' failure

reset_case
export LITESTREAM_DB_PATH=relative.db
run_case 'relative database path is rejected' failure

reset_case
export LITESTREAM_DB_PATH=/data/
run_case 'a directory cannot be the database path' failure

reset_case
export LITESTREAM_DB_PATH=
run_case 'a missing database path is rejected' failure

reset_case
export LITESTREAM_DB_PATH='/data/"quoted".db'
run_case 'a database path that would break the YAML string is rejected' failure

reset_case
export LITESTREAM_DB_PATH='/data/back\slash.db'
run_case 'a database path with a YAML escape character is rejected' failure
expect_output 'must not contain double quotes or backslashes'

reset_case
export LITESTREAM_EXEC=
run_case 'a missing application command is rejected' failure

reset_case
export LITESTREAM_CONFIG_PATH=/missing/config.yml
run_case 'a missing Litestream config is rejected' failure

reset_case
export LITESTREAM_DB_PATH='/data/another app/state.sqlite'
run_case 'another application can restore a custom database path without changing storage settings' success
[ "$(cat "$LITESTREAM_DB_PATH")" = 'restored database' ]

reset_case
use_s3
run_case 's3 replica restores with the bundled s3 configuration' success
[ "$(cat /data/sample.db)" = 'restored database' ]
grep -q -- '^restore -config /etc/litestream/s3.yml ' /tmp/entrypoint-trace
grep -qx 'config=/etc/litestream/s3.yml' /tmp/app-started

reset_case
use_s3
export FAKE_RESTORE=absent
run_case 's3 replica without a backup fails closed by default' failure

for name in LITESTREAM_S3_BUCKET LITESTREAM_S3_PATH; do
    reset_case
    use_s3
    unset "$name"
    run_case "s3 replica requires $name" failure
    expect_output "$name"
done

for name in LITESTREAM_S3_FORCE_PATH_STYLE LITESTREAM_S3_SKIP_VERIFY; do
    reset_case
    use_s3
    export "$name=yes"
    run_case "invalid $name fails closed" failure
    expect_output "$name must be true or false"

    reset_case
    use_s3
    export "$name=true"
    run_case "$name accepts true" success
done

reset_case
use_s3
export LITESTREAM_S3_PATH='sample"db'
run_case 'an s3 setting that would break the YAML string is rejected' failure

reset_case
export LITESTREAM_REPLICA_TYPE=s3 LITESTREAM_CONFIG_PATH=/tmp/custom-litestream.yml
run_case 'a custom configuration does not require the bundled s3 settings' success
grep -qx 'config=/tmp/custom-litestream.yml' /tmp/app-started

reset_case
export FAKE_RESTORE=absent
printf 'initial database' > /backup/sample.db
run_case 'a standalone database in the backup folder is imported without initialization permission' success
[ "$(cat /data/sample.db)" = 'initial database' ]
[ ! -e /backup/sample.db ]
[ "$(cat /backup/sample.db.imported)" = 'initial database' ]
[ "$(cat /tmp/import-backup-config)" = /etc/litestream/file.yml ]

reset_case
use_s3
export FAKE_RESTORE=absent
printf 'initial database' > /import/sample.db
run_case 's3 replica imports a standalone database from /import' success
[ "$(cat /data/sample.db)" = 'initial database' ]
[ ! -e /import/sample.db ]
[ "$(cat /import/sample.db.imported)" = 'initial database' ]
[ "$(cat /tmp/import-backup-config)" = /etc/litestream/s3.yml ]

reset_case
use_s3
export FAKE_RESTORE=absent
printf 'initial database' > /backup/sample.db
run_case 's3 replica does not import from /backup' failure
[ -f /backup/sample.db ]

reset_case
printf 'old initial database' > /backup/sample.db
run_case 'a regular replica takes precedence over an initial database file' success
[ "$(cat /data/sample.db)" = 'restored database' ]
[ "$(cat /backup/sample.db)" = 'old initial database' ]
expect_no_call '^replicate .*-once'

for step in FAKE_IMPORT_FAIL FAKE_VALIDATION_FAIL FAKE_BACKUP_FAIL; do
    reset_case
    export FAKE_RESTORE=absent
    export "$step=true"
    printf 'initial database' > /backup/sample.db
    run_case "initial import failure preserves the source ($step)" failure
    [ ! -e /data/sample.db ]
    [ "$(cat /backup/sample.db)" = 'initial database' ]
    [ ! -e /backup/sample.db.imported ]
done

reset_case
export FAKE_RESTORE=absent
touch /backup/sample.db
run_case 'an empty initial database is rejected' failure
[ ! -e /data/sample.db ]

reset_case
export FAKE_RESTORE=absent
printf 'initial database' > /backup/sample.db
touch /backup/sample.db-wal
run_case 'an initial database with a WAL sidecar is rejected' failure

reset_case
export FAKE_RESTORE=absent
printf 'old initial database' > /backup/sample.db
touch /backup/sample.db.imported
run_case 'a consumed initial database cannot silently reset a missing replica' failure

reset_case
export FAKE_RESTORE=failure
printf 'initial database' > /backup/sample.db
run_case 'a replica restore error cannot fall back to the initial database' failure
expect_no_call '^replicate .*-once'
[ -f /backup/sample.db ]

reset_case
