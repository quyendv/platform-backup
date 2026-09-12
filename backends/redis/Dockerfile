# syntax=docker/dockerfile:1
#
# Redis backup image, built on the official Redis image — it already ships both
# redis-cli and the redis-server that restore stages the RDB on.
#
# Built once per major version: RDB is not backward compatible (Redis 8 writes
# REDIS0015, which redis-server 7.4 refuses to load), and both verification and
# restore load the file. Match the tag to the server, or use a newer one.
ARG REDIS_VERSION=8
ARG SUPERCRONIC_VERSION=0.2.34

FROM redis:${REDIS_VERSION}-alpine
ARG TARGETARCH
ARG SUPERCRONIC_VERSION
LABEL org.opencontainers.image.title="platform-backup/redis" \
  org.opencontainers.image.description="Redis RDB backup to S3-compatible storage" \
  org.opencontainers.image.source="https://github.com/quyendv/platform-backup"

USER 0

RUN apk add --no-cache bash ca-certificates coreutils curl findutils gzip jq util-linux aws-cli

RUN set -eux; \
  curl -fsSL -o /usr/local/bin/supercronic \
  "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}"; \
  chmod +x /usr/local/bin/supercronic

WORKDIR /opt/platform-backup
COPY lib/ ./lib/
COPY entrypoint.sh ./entrypoint.sh
COPY backends/redis/backend.sh ./backend.sh
COPY healthcheck.sh ./healthcheck.sh
RUN chmod +x entrypoint.sh healthcheck.sh

ENV BACKUP_DIR=/backup RESTORE_DIR=/restore
RUN mkdir -p /backup /restore && chown -R 999:1000 /backup /restore
VOLUME ["/backup"]

# Makes a failing schedule visible to docker ps and anything watching
# container health. A one-shot run exits before this ever matters.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=1 \
  CMD ["/opt/platform-backup/healthcheck.sh"]

# Back to the base image's own unprivileged user (redis). Numeric, so
# Kubernetes runAsNonRoot can resolve it. Staging writes only under BACKUP_DIR,
# which is owned above.
USER 999:1000

# The base image sets its own CMD; without clearing it Docker would pass that
# command as arguments to this entrypoint.
ENTRYPOINT ["/opt/platform-backup/entrypoint.sh"]
CMD []
