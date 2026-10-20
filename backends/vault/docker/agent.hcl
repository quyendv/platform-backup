# Vault Agent for the backup container: AppRole login, token kept at
# /vault/token/token. The Vault address comes from VAULT_ADDR.
#
# The agent renews the token while it can, and logs in again when renewal is no
# longer possible: max TTL reached, token revoked, or Vault sealed and unsealed.
# Login is retried with backoff for as long as it fails, so a Vault that is down
# for a day recovers on its own once it is back.

auto_auth {
  method "approle" {
    config = {
      role_id_file_path   = "/vault/approle/role-id"
      secret_id_file_path = "/vault/approle/secret-id"
      # Keep the secret-id: the agent needs it again for every new login.
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/vault/token/token"
      # Readable by the backup image (uid 100, gid 1000), nobody else.
      mode = 0640
    }
  }
}
