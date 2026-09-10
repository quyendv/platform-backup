# syntax=docker/dockerfile:1
#
# etcd backup image. Alpine keeps it small; etcdctl is pinned so it can be
# matched to the cluster's major/minor version.
ARG ETCD_VERSION=3.5.16
ARG SUPERCRONIC_VERSION=0.2.34

FROM alpine:3.20
ARG TARGETARCH
ARG ETCD_VERSION
ARG SUPERCRONIC_VERSION
LABEL org.opencontainers.image.title="platform-backup/etcd" \
  org.opencontainers.image.description="etcd snapshot backup to S3-compatible storage" \
  org.opencontainers.image.source="https://github.com/quyendv/platform-backup"

RUN apk add --no-cache bash ca-certificates coreutils curl findutils util-linux aws-cli

# A failing curl inside a pipe must fail the build, not be swallowed by tar.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
  curl -fsSL "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-${TARGETARCH}.tar.gz" \
  | tar -xz -C /usr/local/bin --strip-components=1 "etcd-v${ETCD_VERSION}-linux-${TARGETARCH}/etcdctl"; \
  etcdctl version

RUN set -eux; \
  curl -fsSL -o /usr/local/bin/supercronic \
  "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}"; \
  chmod +x /usr/local/bin/supercronic

WORKDIR /opt/platform-backup
COPY lib/ ./lib/
COPY entrypoint.sh ./entrypoint.sh
COPY backends/etcd/backend.sh ./backend.sh
RUN chmod +x entrypoint.sh

ENV BACKUP_DIR=/backup RESTORE_DIR=/restore ETCD_MODE=kubeadm
RUN mkdir -p /backup /restore
VOLUME ["/backup"]

ENTRYPOINT ["/opt/platform-backup/entrypoint.sh"]
