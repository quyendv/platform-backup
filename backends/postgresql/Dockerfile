# syntax=docker/dockerfile:1
#
# PostgreSQL backup image. Built once per server major version: pg_dump refuses
# to dump a server newer than itself, so the tag must match the target.
ARG PG_VERSION=17
ARG SUPERCRONIC_VERSION=0.2.34

FROM debian:bookworm-slim AS awscli
ARG TARGETARCH
RUN apt-get update \
  && apt-get install -y --no-install-recommends curl unzip ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
  case "${TARGETARCH}" in \
  amd64) arch=x86_64 ;; \
  arm64) arch=aarch64 ;; \
  *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
  esac; \
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o /tmp/aws.zip; \
  unzip -q /tmp/aws.zip -d /tmp; \
  /tmp/aws/install --install-dir /aws-cli --bin-dir /aws-cli/bin

FROM debian:bookworm-slim AS supercronic
ARG TARGETARCH
ARG SUPERCRONIC_VERSION
RUN apt-get update \
  && apt-get install -y --no-install-recommends curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /usr/local/bin/supercronic \
  "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
  && chmod +x /usr/local/bin/supercronic

FROM debian:bookworm-slim
ARG PG_VERSION
LABEL org.opencontainers.image.title="platform-backup/postgresql" \
  org.opencontainers.image.description="PostgreSQL backup to S3-compatible storage" \
  org.opencontainers.image.source="https://github.com/quyendv/platform-backup"

# A failing curl inside a pipe must fail the build, not be swallowed by gpg.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  bash ca-certificates curl gnupg gzip findutils util-linux jq \
  && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends "postgresql-client-${PG_VERSION}" \
  && apt-get purge -y gnupg \
  && apt-get autoremove -y \
  && rm -rf /var/lib/apt/lists/*

COPY --from=awscli /aws-cli /aws-cli
COPY --from=supercronic /usr/local/bin/supercronic /usr/local/bin/supercronic
ENV PATH="/aws-cli/bin:${PATH}"

WORKDIR /opt/platform-backup
COPY lib/ ./lib/
COPY entrypoint.sh ./entrypoint.sh
COPY backends/postgresql/backend.sh ./backend.sh
COPY healthcheck.sh ./healthcheck.sh
RUN chmod +x entrypoint.sh healthcheck.sh

ENV BACKUP_DIR=/backup RESTORE_DIR=/restore
RUN mkdir -p /backup /restore
VOLUME ["/backup"]

# Makes a failing schedule visible to docker ps and anything watching
# container health. A one-shot run exits before this ever matters.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=1 \
  CMD ["/opt/platform-backup/healthcheck.sh"]

ENTRYPOINT ["/opt/platform-backup/entrypoint.sh"]
