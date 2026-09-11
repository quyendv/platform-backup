# syntax=docker/dockerfile:1
#
# Vault backup image, built on the official Vault image so the CLI version
# tracks the server it talks to.
ARG VAULT_VERSION=1.18
ARG SUPERCRONIC_VERSION=0.2.34

FROM hashicorp/vault:${VAULT_VERSION}
ARG TARGETARCH
ARG SUPERCRONIC_VERSION
LABEL org.opencontainers.image.title="platform-backup/vault" \
  org.opencontainers.image.description="Vault Raft snapshot backup to S3-compatible storage" \
  org.opencontainers.image.source="https://github.com/quyendv/platform-backup"

USER 0

RUN apk add --no-cache bash ca-certificates coreutils curl findutils gzip util-linux aws-cli jq

# Selecting the binary by TARGETARCH is what makes this image multi-arch; the
# base image has published arm64 all along.
RUN set -eux; \
  curl -fsSL -o /usr/local/bin/supercronic \
  "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}"; \
  chmod +x /usr/local/bin/supercronic

WORKDIR /opt/platform-backup
COPY lib/ ./lib/
COPY entrypoint.sh ./entrypoint.sh
COPY backends/vault/backend.sh ./backend.sh
COPY healthcheck.sh ./healthcheck.sh
RUN chmod +x entrypoint.sh healthcheck.sh

ENV BACKUP_DIR=/backup RESTORE_DIR=/restore
RUN mkdir -p /backup /restore && chown -R 100:1000 /backup /restore
VOLUME ["/backup"]

# Back to the base image's own unprivileged user (vault, uid 100). Nothing here
# needs root, and Kubernetes runAsNonRoot needs the numeric id.
USER 100:1000

# The base image sets its own CMD; without clearing it Docker would pass that
# command as arguments to this entrypoint.
# Makes a failing schedule visible to docker ps and anything watching
# container health. A one-shot run exits before this ever matters.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=1 \
  CMD ["/opt/platform-backup/healthcheck.sh"]

ENTRYPOINT ["/opt/platform-backup/entrypoint.sh"]
CMD []
