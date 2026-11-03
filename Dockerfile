# Builds two images:
# - kit (--target kit): only the files an application image copies; published to GHCR.
# - the final stage: an example application that uses the kit the same way.

# Pinned replication binary (Apache-2.0).
FROM litestream/litestream:0.5.17@sha256:4b02b9859a6b6b4087d8b8944e15f7e984bd7957cba322bbeee38b0e27b9656a AS litestream

FROM scratch AS kit
COPY --from=litestream /usr/local/bin/litestream /usr/local/bin/litestream
COPY container/LICENSE.litestream /usr/share/licenses/litestream/LICENSE
COPY LICENSE /usr/share/licenses/litestreamkit/LICENSE
COPY container/litestream/ /etc/litestream/
COPY --chmod=755 container/litestream-entrypoint.sh /usr/local/bin/litestream-entrypoint

FROM debian:trixie-slim
# ca-certificates is required for HTTPS endpoints of the s3 replica.
# sqlite3 is used only by the demo application.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# --- Litestream ------------------------------------------------------------
# An application image copies from the published kit instead of this stage;
# see README.md.
COPY --from=kit / /
# /data intentionally uses the container's disk-backed writable layer; the
# replica (/backup or S3) is the durable copy and is restored on startup.
RUN mkdir -p /data
ENV LITESTREAM_DB_PATH=/data/app.db
ENTRYPOINT ["/usr/local/bin/litestream-entrypoint"]
# ---------------------------------------------------------------------------

# Demo application. The application's own database setting must use the same
# absolute path as LITESTREAM_DB_PATH.
COPY --chmod=755 example/demo-app.sh /usr/local/bin/demo-app
ENV APP_DB_PATH=/data/app.db
ENV LITESTREAM_EXEC=/usr/local/bin/demo-app
