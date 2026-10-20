# Least privilege for the vault backup image (vault operator raft snapshot save).
#
#   vault policy write backup-raft policies/backup-raft.hcl
#
# Give it to a machine identity, not to a hand-made token: an AppRole role on a
# Docker host, a Kubernetes auth role in a cluster, with Vault Agent fetching
# and renewing the token (../README.md, "Authentication"). The image itself
# never renews a token, so a static one fails every run once it expires.
#
# Restore needs a different, much stronger policy — do not grant it here.

path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# Include if /v1/sys/health is not served anonymously in your deployment.
path "sys/health" {
  capabilities = ["read"]
}

# Lets Vault Agent renew the token it holds. Also part of Vault's built-in
# default policy; listed so this policy stands on its own.
path "auth/token/renew-self" {
  capabilities = ["update"]
}
