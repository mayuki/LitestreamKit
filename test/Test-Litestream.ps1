param(
    [string]$Image = 'litestream-kit:test'
)

$ErrorActionPreference = 'Stop'
$prefix = 'litestream-kit-test-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$label = "litestream-kit.test=$prefix"
$labelArguments = @('--label', $label)
$network = "$prefix-net"
$backupVolume = "$prefix-backup"
$emptyVolume = "$prefix-empty"
$corruptVolume = "$prefix-corrupt"
$importVolume = "$prefix-import"
$readonlyImportVolume = "$prefix-readonly-import"
$volumes = @($backupVolume, $emptyVolume, $corruptVolume, $importVolume, $readonlyImportVolume)

# Local S3-compatible server (Apache-2.0) used as a stand-in for any provider.
$s3Image = 'versity/versitygw:v1.10.0'
$curlImage = 'curlimages/curl:8.17.0'
$s3Server = "$prefix-s3"
$s3Endpoint = "http://${s3Server}:7070"
$bucket = 'litestream-test'
$accessKey = 'test-access-key'
$secretKey = 'test-secret-key'
$s3Credentials = @('--network', $network,
    '-e', "LITESTREAM_ACCESS_KEY_ID=$accessKey", '-e', "LITESTREAM_SECRET_ACCESS_KEY=$secretKey")
$s3Arguments = $s3Credentials + @('-e', 'LITESTREAM_REPLICA_TYPE=s3',
    '-e', "LITESTREAM_S3_BUCKET=$bucket", '-e', "LITESTREAM_S3_ENDPOINT=$s3Endpoint")

function Invoke-Docker {
    param([string[]]$Arguments)
    $output = & docker @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($Arguments[0]) failed: $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine)
}

function Assert-StartupFailure {
    param([string]$Description, [string[]]$RunArguments, [string]$ExpectedMessage)
    $output = & docker run --rm @labelArguments --entrypoint /usr/bin/timeout @RunArguments $Image 30 /usr/local/bin/litestream-entrypoint 2>&1
    if ($LASTEXITCODE -eq 0 -or ($output -join "`n") -notlike "*$ExpectedMessage*") {
        throw "Expected startup failure ($Description): $($output -join [Environment]::NewLine)"
    }
    Write-Host "PASS: $Description"
}

function Get-LocalEventCount {
    param([string]$Name, [string]$Kind)
    $value = Invoke-Docker @('exec', $Name, 'sqlite3', '-readonly', '-cmd', '.timeout 5000', '/data/app.db',
        "SELECT count(*) FROM events WHERE kind='$Kind';")
    return [int]$value.Trim()
}

# Restores the replica into a throwaway container; -1 means it could not be restored.
function Get-ReplicaEventCount {
    param([string[]]$SourceArguments, [string]$Source, [string]$Kind)
    $script = 'litestream restore -integrity-check quick -o /tmp/check.db "$1" >&2 && sqlite3 -readonly /tmp/check.db "$2"'
    $value = & docker run --rm @labelArguments @SourceArguments --entrypoint /bin/sh $Image -c $script 'check' $Source `
        "SELECT count(*) FROM events WHERE kind='$Kind';" 2>$null
    if ($LASTEXITCODE -ne 0) { return -1 }
    return [int]"$value".Trim()
}

function Start-Demo {
    param([string]$Name, [string[]]$RunArguments)
    $null = Invoke-Docker (@('run', '-d', '--name', $Name) + $labelArguments +
        @('-e', 'APP_HEARTBEAT_INTERVAL=1') + $RunArguments + $Image)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(60)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ((Invoke-Docker @('inspect', '--format', '{{.State.Running}}', $Name)) -ne 'true') {
            throw "Application exited: $(Invoke-Docker @('logs', $Name))"
        }
        if ((Invoke-Docker @('logs', $Name)) -like '*demo-app: started*') { return }
        Start-Sleep -Milliseconds 500
    }
    throw "Application did not start: $(Invoke-Docker @('logs', $Name))"
}

function Remove-Container {
    param([string]$Name)
    $null = Invoke-Docker @('kill', $Name)
    $null = Invoke-Docker @('rm', $Name)
}

# The same lifecycle for each replica type: first deployment, continuous
# replication, loss of the container, automatic restore and final shutdown sync.
function Test-ReplicaLifecycle {
    param([string]$Name, [string[]]$ReplicaArguments, [string[]]$CheckArguments, [string]$CheckSource)
    $first = "$prefix-$Name-first"
    $second = "$prefix-$Name-second"

    Start-Demo $first ($ReplicaArguments + @('-e', 'LITESTREAM_ALLOW_INITIALIZE=true', '-e', 'LITESTREAM_SYNC_INTERVAL=1s'))
    Write-Host "PASS: [$Name] an explicit first deployment starts the application"

    # Restore while the application is still running, proving continuous
    # replication rather than only the final sync on graceful shutdown.
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(60)
    $replicated = -1
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ((Get-LocalEventCount $first 'heartbeat') -ge 3) {
            $replicated = Get-ReplicaEventCount $CheckArguments $CheckSource 'heartbeat'
            if ($replicated -ge 3) { break }
        }
        Start-Sleep -Seconds 1
    }
    if ($replicated -lt 3) { throw "[$Name] Continuous replication did not reach the replica: $(Invoke-Docker @('logs', $first))" }
    Write-Host "PASS: [$Name] the replica contains live updates before shutdown"

    # Lose the whole writable layer without a final sync, and do not allow initialization.
    Remove-Container $first
    # A long sync interval leaves only the shutdown sync to deliver the marker below.
    Start-Demo $second ($ReplicaArguments + @('-e', 'LITESTREAM_SYNC_INTERVAL=1h'))
    if ((Get-LocalEventCount $second 'start') -ne 2 -or (Get-LocalEventCount $second 'heartbeat') -lt $replicated) {
        throw "[$Name] The replacement container did not restore the replicated events."
    }
    Write-Host "PASS: [$Name] a replacement container restores the replica without initialization"

    # Litestream opens the database on its first monitor tick (about 1s) and
    # performs the final shutdown sync only for opened databases.
    Start-Sleep -Seconds 3
    $null = Invoke-Docker @('exec', $second, 'sqlite3', '-cmd', '.timeout 5000', '/data/app.db',
        "INSERT INTO events (kind) VALUES ('marker');")
    $null = Invoke-Docker @('stop', '--time', '60', $second)
    if ((Invoke-Docker @('inspect', '--format', '{{.State.ExitCode}}', $second)) -ne '0') {
        throw "[$Name] Graceful shutdown did not complete successfully: $(Invoke-Docker @('logs', $second))"
    }
    if ((Get-ReplicaEventCount $CheckArguments $CheckSource 'marker') -ne 1) {
        throw "[$Name] The final shutdown sync did not persist the last update."
    }
    Write-Host "PASS: [$Name] graceful shutdown persists the last update with the final sync"
}

function New-SeedDatabase {
    param([string]$Volume)
    $null = Invoke-Docker (@('run', '--rm') + $labelArguments + @('--mount', "type=volume,source=$Volume,target=/import",
        '--entrypoint', 'sqlite3', $Image, '/import/app.db',
        "CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP); INSERT INTO events (kind) VALUES ('seed');"))
}

try {
    $null = Invoke-Docker @('network', 'create', '--label', $label, $network)
    foreach ($volume in $volumes) {
        $null = Invoke-Docker @('volume', 'create', '--label', $label, $volume)
    }
    $null = Invoke-Docker (@('run', '-d', '--name', $s3Server, '--network', $network) + $labelArguments +
        @($s3Image, '--access', $accessKey, '--secret', $secretKey, 'posix', '/tmp'))
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    while ($true) {
        $null = & docker run --rm @labelArguments --network $network $curlImage -sSf --aws-sigv4 'aws:amz:us-east-1:s3' `
            -u "${accessKey}:${secretKey}" -X PUT "$s3Endpoint/$bucket" 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        if ([DateTimeOffset]::UtcNow -ge $deadline) { throw "Could not create the test bucket: $(Invoke-Docker @('logs', $s3Server))" }
        Start-Sleep -Seconds 1
    }

    # Exercise the shell policy inside the actual image with a fake CLI.
    $unitOutput = Invoke-Docker (@('run', '--rm') + $labelArguments + @('--entrypoint', '/bin/sh',
        '-e', 'LITESTREAM_CONTAINER_TESTS=1',
        '--mount', "type=volume,source=$emptyVolume,target=/backup",
        '--mount', "type=bind,source=$PSScriptRoot,target=/tests,readonly",
        $Image, '/tests/entrypoint-tests.sh'))
    Write-Host $unitOutput

    $fileBackup = @('--mount', "type=volume,source=$backupVolume,target=/backup")
    Assert-StartupFailure 'file: a missing /backup mount' @() 'Mount an external backup directory'
    Assert-StartupFailure 'file: a read-only backup destination' @('--mount',
        "type=volume,source=$emptyVolume,target=/backup,readonly") '/backup must be writable'
    Assert-StartupFailure 'file: a missing backup with real Litestream' @('--mount',
        "type=volume,source=$emptyVolume,target=/backup") 'Restore failed'
    Assert-StartupFailure 's3: missing bucket setting' @('-e', 'LITESTREAM_REPLICA_TYPE=s3',
        '-e', 'LITESTREAM_S3_PATH=missing/app') 'Set LITESTREAM_S3_BUCKET'
    Assert-StartupFailure 's3: a missing backup with real Litestream' ($s3Arguments +
        @('-e', 'LITESTREAM_S3_PATH=missing/app')) 'Restore failed'
    Assert-StartupFailure 's3: wrong credentials are not treated as a missing backup' (@('--network', $network,
        '-e', "LITESTREAM_ACCESS_KEY_ID=$accessKey", '-e', 'LITESTREAM_SECRET_ACCESS_KEY=wrong-secret-key',
        '-e', 'LITESTREAM_REPLICA_TYPE=s3', '-e', "LITESTREAM_S3_BUCKET=$bucket", '-e', "LITESTREAM_S3_ENDPOINT=$s3Endpoint",
        '-e', 'LITESTREAM_S3_PATH=missing/app', '-e', 'LITESTREAM_ALLOW_INITIALIZE=true')) 'Restore failed'
    Assert-StartupFailure 's3: a nonexistent bucket is not treated as a missing backup' ($s3Credentials + @(
        '-e', 'LITESTREAM_REPLICA_TYPE=s3', '-e', 'LITESTREAM_S3_BUCKET=no-such-bucket', '-e', "LITESTREAM_S3_ENDPOINT=$s3Endpoint",
        '-e', 'LITESTREAM_S3_PATH=missing/app', '-e', 'LITESTREAM_ALLOW_INITIALIZE=true')) 'Restore failed'

    # A plain run without any backup destination, as in development or CI.
    $direct = "$prefix-none"
    Start-Demo $direct @('-e', 'LITESTREAM_REPLICA_TYPE=none')
    if ((Invoke-Docker @('logs', $direct)) -notlike '*WARNING: replication is disabled*') {
        throw 'Disabled replication was not reported.'
    }
    $null = Invoke-Docker @('stop', '--time', '10', $direct)
    if ((Invoke-Docker @('inspect', '--format', '{{.State.ExitCode}}', $direct)) -ne '0') {
        throw "The application did not stop gracefully as PID 1: $(Invoke-Docker @('logs', $direct))"
    }
    Write-Host 'PASS: none: the application starts without a backup destination and stops gracefully'

    Test-ReplicaLifecycle 'file' $fileBackup @('--mount', "type=volume,source=$backupVolume,target=/backup,readonly") 'file:///backup'

    $s3Path = 'apps/demo'
    $s3Source = "s3://$bucket/${s3Path}?endpoint=$s3Endpoint&region=us-east-1&forcePathStyle=true"
    Test-ReplicaLifecycle 's3' ($s3Arguments + @('-e', "LITESTREAM_S3_PATH=$s3Path")) $s3Credentials $s3Source

    # Move an existing standalone database into an S3-replicated deployment.
    New-SeedDatabase $importVolume
    $importArguments = $s3Arguments + @('-e', 'LITESTREAM_S3_PATH=apps/imported')
    $imported = "$prefix-import"
    Start-Demo $imported ($importArguments + @('--mount', "type=volume,source=$importVolume,target=/import"))
    $null = Invoke-Docker @('exec', $imported, '/bin/sh', '-c', 'test ! -e /import/app.db && test -s /import/app.db.imported')
    if ((Get-LocalEventCount $imported 'seed') -ne 1) { throw 'The standalone database was not imported.' }
    # Killed immediately: only the backup made before the application started is guaranteed.
    Remove-Container $imported
    $importRestored = "$prefix-import-restored"
    Start-Demo $importRestored $importArguments
    if ((Get-LocalEventCount $importRestored 'seed') -ne 1) {
        throw 'The imported database was not restored from the S3 replica.'
    }
    $null = Invoke-Docker @('stop', '--time', '60', $importRestored)
    Write-Host 'PASS: s3: a standalone database in /import is backed up first and later restored from S3'

    New-SeedDatabase $readonlyImportVolume
    Assert-StartupFailure 's3: a read-only /import cannot consume the initial database' ($s3Arguments + @(
        '-e', 'LITESTREAM_S3_PATH=apps/readonly-import',
        '--mount', "type=volume,source=$readonlyImportVolume,target=/import,readonly")) '/import must be writable'

    # Corrupt only a disposable copy, never the successfully verified backup.
    $corruptScript = 'cp -a /backup/. /broken/; find /broken -type f -name "*.ltx" -exec sh -c ''printf corrupt > "$1"'' sh {} \;'
    $null = Invoke-Docker (@('run', '--rm') + $labelArguments + @('--entrypoint', '/bin/sh',
        '--mount', "type=volume,source=$backupVolume,target=/backup,readonly",
        '--mount', "type=volume,source=$corruptVolume,target=/broken",
        $Image, '-c', $corruptScript))
    Assert-StartupFailure 'file: a corrupt backup cannot fall back to initialization' @('--mount',
        "type=volume,source=$corruptVolume,target=/backup", '-e', 'LITESTREAM_ALLOW_INITIALIZE=true') 'Restore failed'

    Write-Host 'All container backup tests passed.'
} finally {
    $leftovers = & docker ps -aq --filter "label=$label"
    if ($leftovers) { & docker rm -f @leftovers 2>$null | Out-Null }
    foreach ($volume in $volumes) {
        & docker volume rm $volume 2>$null | Out-Null
    }
    & docker network rm $network 2>$null | Out-Null
}
