#!/bin/sh
# Restores a SQLite database from its Litestream replica before the application
# starts, then runs the application under continuous replication.
# Everything is configured through environment variables; see README.md.
#
# Startup fails closed: the application starts only with an existing local
# database, a verified restore, a verified import of an initial database, or an
# explicitly allowed empty first deployment. Replication can be turned off only
# explicitly, with LITESTREAM_REPLICA_TYPE=none for development and testing.
set -eu

log() {
    echo "Database startup: $*"
}

fail() {
    log "$*" >&2
    exit 1
}

require_boolean() {
    case "$2" in
        true|false) ;;
        *) fail "$1 must be true or false." ;;
    esac
}

# Values expanded into double-quoted YAML strings must not end the string.
require_yaml_safe() {
    case "$2" in
        *'"'* | *\\*) fail "$1 must not contain double quotes or backslashes." ;;
    esac
}

# SQLite would apply these sidecar files to whatever database appears next to them.
require_no_sidecars() {
    for suffix in -wal -shm -journal; do
        [ ! -e "$1$suffix" ] || fail "Found $1$suffix. $2"
    done
}

# Settings read by the bundled s3.yml. Credentials are read by Litestream itself
# from LITESTREAM_ACCESS_KEY_ID/LITESTREAM_SECRET_ACCESS_KEY or AWS_*.
validate_bundled_s3_settings() {
    [ -n "${LITESTREAM_S3_BUCKET:-}" ] || fail "Set LITESTREAM_S3_BUCKET for the s3 replica."
    [ -n "${LITESTREAM_S3_PATH:-}" ] || fail "Set LITESTREAM_S3_PATH to a key prefix used only by this database."
    require_yaml_safe LITESTREAM_S3_BUCKET "$LITESTREAM_S3_BUCKET"
    require_yaml_safe LITESTREAM_S3_PATH "$LITESTREAM_S3_PATH"
    require_yaml_safe LITESTREAM_S3_ENDPOINT "${LITESTREAM_S3_ENDPOINT:-}"
    require_yaml_safe LITESTREAM_S3_REGION "${LITESTREAM_S3_REGION:-}"
    # Empty leaves the choice to Litestream's defaults.
    [ -z "${LITESTREAM_S3_FORCE_PATH_STYLE:-}" ] || require_boolean LITESTREAM_S3_FORCE_PATH_STYLE "$LITESTREAM_S3_FORCE_PATH_STYLE"
    [ -z "${LITESTREAM_S3_SKIP_VERIFY:-}" ] || require_boolean LITESTREAM_S3_SKIP_VERIFY "$LITESTREAM_S3_SKIP_VERIFY"
}

# Where backups go, for the startup log and restore errors. This names the source
# of the credentials and must never include their values.
describe_replica() {
    if [ -n "${LITESTREAM_CONFIG_PATH:-}" ]; then
        echo "the $replica_type replica defined in $config_path"
    elif [ "$replica_type" = file ]; then
        echo "the file replica at /backup"
    else
        # Litestream ignores LITESTREAM_* when AWS_* is set, even if it is empty.
        if [ -n "${AWS_ACCESS_KEY_ID+set}" ]; then
            credentials=AWS_ACCESS_KEY_ID
        elif [ -n "${LITESTREAM_ACCESS_KEY_ID+set}" ]; then
            credentials=LITESTREAM_ACCESS_KEY_ID
        else
            credentials='AWS SDK defaults'
        fi
        echo "s3://$LITESTREAM_S3_BUCKET/$LITESTREAM_S3_PATH (endpoint: ${LITESTREAM_S3_ENDPOINT:-AWS S3}, region: ${LITESTREAM_S3_REGION:-default}, credentials: $credentials)"
    fi
}

# Litestream retries an unreachable replica for minutes without logging anything,
# and a large restore is just as quiet, so report what a long wait is waiting for.
# Runs in the background; stops on TERM without leaving its sleep behind.
report_slow_restore() {
    waited=0
    while :; do
        sleep 30 &
        sleep_pid=$!
        trap 'kill "$sleep_pid"; exit' TERM
        wait "$sleep_pid"
        waited=$((waited + 30))
        log "still waiting for the replica after ${waited}s: $replica. A large database takes time, but Litestream also retries an unreachable replica for several minutes without logging. Set LOG_LEVEL=debug to log each request." >&2
    done
}

# What to check for a Litestream restore error. These match the error text of the
# pinned Litestream version; the tests catch a changed message, and anything
# unrecognized gets only the general advice.
restore_hint() {
    case "$1" in
        *'no matching backup files'*)
            echo "No backup exists at this location. Check that it is the right one. Only a first deployment without backups should set LITESTREAM_ALLOW_INITIALIZE=true." ;;
        *'get credentials'*)
            echo "No credentials were found. Set LITESTREAM_ACCESS_KEY_ID and LITESTREAM_SECRET_ACCESS_KEY, or give the container an IAM role." ;;
        *x509* | *certificate* | *'HTTP response to HTTPS client'*)
            echo "TLS failed. Check http or https in the endpoint, and that the image has CA certificates (ca-certificates on Debian)." ;;
        *'request send failed'* | *'no such host'* | *'connection refused'* | *'i/o timeout'*)
            echo "The replica could not be reached. Check the endpoint's host and port, DNS, and the container's network." ;;
        *SignatureDoesNotMatch* | *InvalidAccessKeyId* | *AccessDenied* | *'StatusCode: 403'*)
            echo "The replica rejected the credentials. Check the access key, the secret key, and the key's permissions on the bucket." ;;
        *NoSuchBucket* | *'StatusCode: 404'*)
            echo "The bucket was not found. Check the bucket name and the endpoint." ;;
        *AuthorizationHeaderMalformed* | *PermanentRedirect* | *'StatusCode: 301'*)
            echo "The bucket is in another region. Check the region." ;;
        *)
            echo "Check the Litestream error above." ;;
    esac
}

# Imports a standalone SQLite file into restored_db. It works only on a local
# copy and backs it up to the replica before consuming the source, so any failure
# leaves the source untouched and the application stopped.
# Uses initial_db_path, initial_db_dir, restore_dir, restored_db and config_path.
import_initial_db() {
    [ -f "$initial_db_path" ] && [ -s "$initial_db_path" ] && [ -r "$initial_db_path" ] || fail "The initial database must be a non-empty readable file: $initial_db_path"
    [ ! -e "$initial_db_path.imported" ] || fail "The initial database was already imported; refusing to reuse it without a backup."
    require_no_sidecars "$initial_db_path" "Provide a consistent standalone initial database without SQLite sidecar files."
    [ -w "$initial_db_dir" ] || fail "$initial_db_dir must be writable to mark the initial database as imported."

    log "importing $initial_db_path."
    # Use Litestream itself to snapshot the copy and restore it with quick_check,
    # without installing another tool.
    cp -- "$initial_db_path" "$restore_dir/initial.db"
    litestream replicate -once "$restore_dir/initial.db" "file://$restore_dir/initial-backup" \
        || fail "Initial database import failed. The application was not started."
    litestream restore -integrity-check quick -o "$restored_db" "file://$restore_dir/initial-backup" \
        || fail "Initial database validation failed. The application was not started."
    [ -s "$restored_db" ] || fail "Initial database validation did not produce a non-empty database."

    # Point the same configuration at the validated copy, so the backup lands
    # exactly where a later restore of db_path looks for it.
    LITESTREAM_DB_PATH="$restored_db" litestream replicate -config "$config_path" -once \
        || fail "Initial database backup failed. The initial file was preserved and the application was not started."
    mv -- "$initial_db_path" "$initial_db_path.imported"
    log "initial database backed up; source retained as $initial_db_path.imported."
}

db_path=${LITESTREAM_DB_PATH:-}
app_command=${LITESTREAM_EXEC:-}
replica_type=${LITESTREAM_REPLICA_TYPE:-file}
allow_initialize=${LITESTREAM_ALLOW_INITIALIZE:-false}

case "$db_path" in
    */) fail "LITESTREAM_DB_PATH must identify a database file." ;;
    /*) ;;
    *) fail "LITESTREAM_DB_PATH must be an absolute database file path." ;;
esac
require_yaml_safe LITESTREAM_DB_PATH "$db_path"
[ -n "$app_command" ] || fail "Set LITESTREAM_EXEC to the application command."
require_boolean LITESTREAM_ALLOW_INITIALIZE "$allow_initialize"

# Development and testing: run the application without restore or replication.
if [ "$replica_type" = none ]; then
    log "WARNING: replication is disabled (LITESTREAM_REPLICA_TYPE=none). The database is not backed up and is lost when the container is removed." >&2
    # The shell parses the command here, so unlike Litestream's -exec it also
    # expands variables in it.
    eval "exec $app_command"
fi

# A file replica writes to /backup, so the initial database is dropped there.
# An s3 replica has no local backup directory; use an optional /import mount.
case "$replica_type" in
    file) initial_db_dir=/backup ;;
    s3) initial_db_dir=/import ;;
    *) fail "LITESTREAM_REPLICA_TYPE must be file, s3 or none." ;;
esac

config_path=${LITESTREAM_CONFIG_PATH:-/etc/litestream/$replica_type.yml}
if [ -z "${LITESTREAM_CONFIG_PATH:-}" ] && [ "$replica_type" = s3 ]; then
    validate_bundled_s3_settings
fi
[ -f "$config_path" ] && [ -r "$config_path" ] || fail "The Litestream configuration is not a readable file: $config_path"

replica=$(describe_replica)
log "database $db_path, backing up to $replica."

db_dir=${db_path%/*}
# A database directly under / leaves db_dir empty.
[ -n "$db_dir" ] || db_dir=/
initial_db_path=$initial_db_dir/${db_path##*/}

# The configuration references these through environment expansion.
export LITESTREAM_DB_PATH="$db_path"
export LITESTREAM_SYNC_INTERVAL="${LITESTREAM_SYNC_INTERVAL:-10s}"
export LITESTREAM_SNAPSHOT_INTERVAL="${LITESTREAM_SNAPSHOT_INTERVAL:-24h}"
export LITESTREAM_SNAPSHOT_RETENTION="${LITESTREAM_SNAPSHOT_RETENTION:-168h}"

if [ "$replica_type" = file ]; then
    # Do not silently write backups into the disposable container layer.
    # Field 5 of mountinfo is the mount point.
    awk '$5 == "/backup" { found = 1 } END { exit !found }' /proc/self/mountinfo \
        || fail "Mount an external backup directory at /backup."
    [ -d /backup ] && [ -r /backup ] && [ -x /backup ] || fail "/backup must be a readable directory."
    backup_probe=$(mktemp /backup/.write-check.XXXXXX) || fail "/backup must be writable."
    rm -f -- "$backup_probe"
fi
mkdir -p "$db_dir"

if [ -e "$db_path" ]; then
    [ -f "$db_path" ] && [ -s "$db_path" ] || fail "The existing database is not a non-empty regular file; refusing to initialize it."
    log "using the existing local database."
else
    require_no_sidecars "$db_path" "It has no database; resolve the orphaned SQLite files before restoring."

    # Restore into a temporary directory and publish only a verified database, so
    # a failed or interrupted restore never leaves a partial file at db_path.
    restore_dir=$(mktemp -d "$db_dir/.restore.XXXXXX")
    restored_db=$restore_dir/restored.db
    report_slow_restore &
    slow_restore_reporter=$!
    cleanup() {
        kill "$slow_restore_reporter" 2>/dev/null || :
        # Reap it here: the process that replaces this shell would not.
        wait "$slow_restore_reporter" 2>/dev/null || :
        # Guard rm -rf against anything but the directory created above.
        case "$restore_dir" in
            "$db_dir"/.restore.*) rm -rf -- "$restore_dir" ;;
        esac
    }
    trap cleanup EXIT
    # sh may skip the EXIT trap when killed by a signal; exit normally instead.
    trap 'exit 143' TERM
    trap 'exit 130' INT

    # With -if-replica-exists, restore succeeds without writing restored_db when
    # no backup exists. Accept that only when there is something else to start
    # from; network, auth, I/O and integrity errors always fail. The flag is left
    # unquoted so that it disappears when empty.
    if_replica_exists=
    if [ "$allow_initialize" = true ] || [ -e "$initial_db_path" ]; then
        if_replica_exists=-if-replica-exists
    fi

    log "restoring the database from the $replica_type replica."
    # Litestream's own log goes to stdout and stays live. Its stderr carries the
    # final error, which is captured to choose a hint.
    restore_errors=$restore_dir/errors
    restore_succeeded=true
    # shellcheck disable=SC2086
    litestream restore -config "$config_path" -o "$restored_db" -integrity-check quick $if_replica_exists "$db_path" 2> "$restore_errors" \
        || restore_succeeded=false
    cat "$restore_errors" >&2
    if [ "$restore_succeeded" = false ]; then
        log "Restore failed from $replica. The application was not started." >&2
        fail "$(restore_hint "$(cat "$restore_errors")") Set LOG_LEVEL=debug for more detail from Litestream."
    fi

    if [ ! -e "$restored_db" ] && [ -e "$initial_db_path" ]; then
        import_initial_db
    fi

    if [ -s "$restored_db" ]; then
        mv -- "$restored_db" "$db_path"
        log "database restored successfully."
    elif [ ! -e "$restored_db" ] && [ "$allow_initialize" = true ]; then
        # Only a missing file means "no backup"; an empty one is a failed restore.
        log "no backup found; new database initialization was explicitly allowed. Remove LITESTREAM_ALLOW_INITIALIZE after this deployment."
    else
        fail "Restore did not produce a non-empty database; refusing to start."
    fi

    # exec below replaces the shell, so the EXIT trap would never run.
    cleanup
    trap - EXIT TERM INT
fi

# Litestream forwards termination to the app and performs its final backup sync.
exec litestream replicate -config "$config_path" -exec "$app_command"
