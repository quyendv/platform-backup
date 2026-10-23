# syntax=docker/dockerfile:1
#
# files backup image: a selection of files under one mounted directory, as one
# tar.zst. GNU tar, not BusyBox: the adapter relies on -T, --numeric-owner and
# GNU's exclusion wildcard semantics (see the design).
ARG ALPINE_VERSION=3.22
ARG SUPERCRONIC_VERSION=0.2.34

FROM alpine:${ALPINE_VERSION}
ARG TARGETARCH
ARG SUPERCRONIC_VERSION
# Recorded in every run's _COMPLETE marker, so a backup says what wrote it.
ARG VERSION=dev
ENV PLATFORM_BACKUP_VERSION=${VERSION}
# AWS CLI 2.23+ sends checksum headers by default, which several S3-compatible
# providers reject: with 2.38 every GetObject failed against one of them, so
# uploads worked and every fetch and restore did not. Only when the operation
# requires one; set either variable to override.
ENV AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
  AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
LABEL org.opencontainers.image.title="platform-backup/files" \
  org.opencontainers.image.description="Directory backup (a checked file selection) to S3-compatible storage" \
  org.opencontainers.image.source="https://github.com/quyendv/platform-backup"

RUN apk add --no-cache bash ca-certificates coreutils curl findutils gzip jq util-linux aws-cli tar zstd

RUN set -eux; \
  curl -fsSL -o /usr/local/bin/supercronic \
  "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}"; \
  chmod +x /usr/local/bin/supercronic

WORKDIR /opt/platform-backup
COPY lib/ ./lib/
COPY entrypoint.sh ./entrypoint.sh
COPY backends/files/backend.sh ./backend.sh
COPY healthcheck.sh ./healthcheck.sh
RUN chmod +x entrypoint.sh healthcheck.sh

ENV BACKUP_DIR=/backup RESTORE_DIR=/restore
# Owned by root, unlike the other images: a backup runs as root with only
# DAC_READ_SEARCH, which reads anything but writes only what root owns.
RUN mkdir -p /backup /restore
VOLUME ["/backup"]

# Makes a failing schedule visible to docker ps and anything watching
# container health. A one-shot run exits before this ever matters.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=1 \
  CMD ["/opt/platform-backup/healthcheck.sh"]

# Root, so every selected file is readable whatever its owner, and so restore
# can give files their owners back. Backups need only DAC_READ_SEARCH (and a
# read-only mount); restore needs CHOWN, DAC_OVERRIDE and FOWNER.
# hadolint ignore=DL3002
USER 0

ENTRYPOINT ["/opt/platform-backup/entrypoint.sh"]
CMD []
