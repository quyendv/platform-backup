# One build definition, used by `mise run build` locally and by CI. Keeping both
# on the same file is what stops "works locally, breaks in CI" drift.

variable "REGISTRY" { default = "ghcr.io/quyendv/platform-backup" }
variable "TAG" { default = "dev" }
# CI overrides this to linux/amd64,linux/arm64 on release tags only: emulated
# arm64 builds are slow, and the postgres matrix multiplies that by four.
variable "PLATFORMS" { default = "linux/amd64" }
variable "SUPERCRONIC_VERSION" { default = "0.2.34" }

group "default" {
  targets = ["postgresql", "mongodb", "etcd", "vault", "redis"]
}

target "_common" {
  context   = "."
  platforms = split(",", PLATFORMS)
  args = {
    SUPERCRONIC_VERSION = SUPERCRONIC_VERSION
  }
}

# pg_dump cannot dump a server newer than itself, so one image per major
# version. `latest` follows the newest supported release.
target "postgresql" {
  name       = "postgresql-pg${pg}"
  matrix     = { pg = ["14", "15", "16", "17"] }
  inherits   = ["_common"]
  dockerfile = "backends/postgresql/Dockerfile"
  args       = { PG_VERSION = pg }
  tags = concat(
    ["${REGISTRY}/postgresql:pg${pg}"],
    TAG == "dev" ? [] : ["${REGISTRY}/postgresql:${TAG}-pg${pg}"],
    pg == "17" ? ["${REGISTRY}/postgresql:latest"] : [],
  )
}

# RDB is not backward compatible, so the image's redis-server must be at least
# the source server's version — the same shape as the postgres matrix.
target "redis" {
  name       = "redis-redis${rv}"
  matrix     = { rv = ["7", "8"] }
  inherits   = ["_common"]
  dockerfile = "backends/redis/Dockerfile"
  args       = { REDIS_VERSION = rv }
  tags = concat(
    ["${REGISTRY}/redis:redis${rv}"],
    TAG == "dev" ? [] : ["${REGISTRY}/redis:${TAG}-redis${rv}"],
    rv == "8" ? ["${REGISTRY}/redis:latest"] : [],
  )
}

target "mongodb" {
  inherits   = ["_common"]
  dockerfile = "backends/mongodb/Dockerfile"
  tags = concat(
    ["${REGISTRY}/mongodb:latest"],
    TAG == "dev" ? [] : ["${REGISTRY}/mongodb:${TAG}"],
  )
}

target "etcd" {
  inherits   = ["_common"]
  dockerfile = "backends/etcd/Dockerfile"
  tags = concat(
    ["${REGISTRY}/etcd:latest"],
    TAG == "dev" ? [] : ["${REGISTRY}/etcd:${TAG}"],
  )
}

target "vault" {
  inherits   = ["_common"]
  dockerfile = "backends/vault/Dockerfile"
  tags = concat(
    ["${REGISTRY}/vault:latest"],
    TAG == "dev" ? [] : ["${REGISTRY}/vault:${TAG}"],
  )
}
