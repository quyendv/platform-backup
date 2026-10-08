# syntax=docker/dockerfile:1
#
# SQLite backup image. The database is a file on a volume this container mounts,
# so the image carries the sqlite3 CLI and nothing that talks to a server.
#
# One image: the SQLite file format is backward compatible, and VACUUM INTO
# (3.27+) is far older than any supported base.
ARG ALPINE_VERSION=3.22
ARG SUPERCRONIC_VERSION=0.2.34

FROM alpine:${ALPINE_VERSION}
ARG TARGETARCH
ARG SUPERCRONIC_VERSION
LABEL org.opencontainers.image.title="platform-backup/sqlite" \
  org.opencontainers.image.description="SQLite database backup to S3-compatible storage" \
  org.opencontainers.image.source="https://github.com/quyendv/platform-backup"

RUN apk add --no-cache bash ca-certificates coreutils curl findutils gzip jq util-linux aws-cli sqlite

RUN set -eux; \
  curl -fsSL -o /usr/local/bin/supercronic \
  "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}"; \
  chmod +x /usr/local/bin/supercronic

WORKDIR /opt/platform-backup
COPY lib/ ./lib/
COPY entrypoint.sh ./entrypoint.sh
COPY backends/sqlite/backend.sh ./backend.sh
COPY healthcheck.sh ./healthcheck.sh
RUN chmod +x entrypoint.sh healthcheck.sh

ENV BACKUP_DIR=/backup RESTORE_DIR=/restore
RUN mkdir -p /backup /restore && chown -R 999:1000 /backup /restore
VOLUME ["/backup"]

# Makes a failing schedule visible to docker ps and anything watching
# container health. A one-shot run exits before this ever matters.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=1 \
  CMD ["/opt/platform-backup/healthcheck.sh"]

# Unprivileged, numeric so Kubernetes runAsNonRoot can resolve it. Backup only
# reads the database; restore needs root to give the restored file its owner
# (see README.md).
USER 999:1000

ENTRYPOINT ["/opt/platform-backup/entrypoint.sh"]
CMD []
