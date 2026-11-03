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
            failure)
                printf 'partial database' > "$output"
                echo "Error: ${FAKE_RESTORE_ERROR:-fake restore failure}" >&2
                exit 1
                ;;
            slow) /bin/sleep 1; printf 'restored database' > "$output" ;;
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
    unset LITESTREAM_ACCESS_KEY_ID LITESTREAM_SECRET_ACCESS_KEY AWS_ACCESS_KEY_ID FAKE_RESTORE_ERROR
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

expect_no_output() {
    if grep -qF -- "$1" /tmp/entrypoint-output; then
        cat /tmp/entrypoint-output
        echo "FAIL: unexpected output: $1" >&2
        exit 1
    fi
}

# The error stays visible, with the location and what to check.
expect_restore_hint() {
    reset_case
    use_s3
    export FAKE_RESTORE=failure FAKE_RESTORE_ERROR="$1"
    run_case "restore error is explained: $2" failure
    expect_output "$1"
    expect_output 'Restore failed from s3://backups/sample/db'
    expect_output "$2"
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
run_case 'the file destination is logged' success
expect_output 'database /data/sample.db, backing up to the file replica at /backup.'

reset_case
use_s3
export LITESTREAM_S3_REGION=auto
export LITESTREAM_ACCESS_KEY_ID=visible-key-id LITESTREAM_SECRET_ACCESS_KEY=visible-secret-key
printf 'existing database' > /data/sample.db
run_case 'the s3 destination is logged without credential values, also without a restore' success
expect_output 's3://backups/sample/db (endpoint: https://s3.example.test, region: auto, credentials: LITESTREAM_ACCESS_KEY_ID)'
expect_no_output visible-key-id
expect_no_output visible-secret-key

reset_case
use_s3
unset LITESTREAM_S3_ENDPOINT
export LITESTREAM_ACCESS_KEY_ID=ignored AWS_ACCESS_KEY_ID=preferred
run_case 'the logged credential source follows the precedence of Litestream' success
expect_output '(endpoint: AWS S3, region: default, credentials: AWS_ACCESS_KEY_ID)'
unset AWS_ACCESS_KEY_ID LITESTREAM_ACCESS_KEY_ID
reset_case
use_s3
run_case 'credentials from the AWS SDK defaults are logged as such' success
expect_output 'credentials: AWS SDK defaults'

reset_case
export LITESTREAM_REPLICA_TYPE=s3 LITESTREAM_CONFIG_PATH=/tmp/custom-litestream.yml
run_case 'a custom configuration is logged as the destination' success
expect_output 'the s3 replica defined in /tmp/custom-litestream.yml'

reset_case
use_s3
export FAKE_RESTORE=absent
run_case 's3 replica without a backup fails closed by default' failure

expect_restore_hint 'no matching backup files available' 'No backup exists at this location'
expect_restore_hint 'get identity: get credentials: failed to refresh cached credentials' 'No credentials were found'
expect_restore_hint 'get credentials: request send failed, Get "http://169.254.169.254/": dial tcp: i/o timeout' 'No credentials were found'
expect_restore_hint 'request send failed: tls: failed to verify certificate: x509: certificate signed by unknown authority' 'TLS failed'
expect_restore_hint 'request send failed: http: server gave HTTP response to HTTPS client' 'TLS failed'
expect_restore_hint 'request send failed, Get "http://host/": dial tcp: lookup host: no such host' 'could not be reached'
expect_restore_hint 'exceeded maximum number of attempts, 10, request send failed: connect: connection refused' 'could not be reached'
expect_restore_hint 'StatusCode: 403, api error SignatureDoesNotMatch: signature mismatch' 'rejected the credentials'
expect_restore_hint 'StatusCode: 403, api error InvalidAccessKeyId: unknown key' 'rejected the credentials'
expect_restore_hint 'StatusCode: 403, api error AccessDenied: denied' 'rejected the credentials'
expect_restore_hint 'StatusCode: 404, NoSuchBucket: The specified bucket does not exist.' 'The bucket was not found'
expect_restore_hint 'StatusCode: 301, api error PermanentRedirect: wrong endpoint' 'another region'
expect_restore_hint 'an error the entrypoint does not know' 'Check the Litestream error above'

# With a short fake sleep, the 30 second interval passes during a 1 second restore.
reset_case
export FAKE_RESTORE=slow
printf '#!/bin/sh\nexec /bin/sleep 0.1\n' > /tmp/fake-bin/sleep
chmod +x /tmp/fake-bin/sleep
run_case 'a slow restore reports what it is waiting for' success
rm /tmp/fake-bin/sleep
expect_output 'still waiting for the replica after 30s: the file replica at /backup'
# Anything still running would keep appending to the output.
reported=$(wc -c < /tmp/entrypoint-output)
/bin/sleep 0.5
[ "$(wc -c < /tmp/entrypoint-output)" = "$reported" ]

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
