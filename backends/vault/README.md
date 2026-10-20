# vault

`ghcr.io/quyendv/platform-backup/vault`

`vault operator raft snapshot save`, gzipped. Restores with
`vault operator raft snapshot restore`.

Raft integrated storage only. A Vault backed by Consul or another storage
backend is backed up by backing up that store instead.

- [Variables](#variables)
- [Authentication: why a static token is not enough](#authentication-why-a-static-token-is-not-enough)
- [Docker: AppRole and Vault Agent](#docker-approle-and-vault-agent)
- [Kubernetes: Kubernetes auth and an agent init container](#kubernetes-kubernetes-auth-and-an-agent-init-container)
- [Restore](#restore)
- [Troubleshooting](#troubleshooting)

## Variables

| Variable | Required | Default | Notes |
|---|:--:|---|---|
| `VAULT_ADDR` | ✅ | — | Must be reachable from inside the container |
| `VAULT_TOKEN_FILE` | one of the two | — | File containing the token, **read again at the start of every run** |
| `VAULT_TOKEN` | one of the two | — | A fixed token. Wins over `VAULT_TOKEN_FILE` when both are set |
| `VAULT_CACERT` | | — | CA bundle for a Vault served over TLS with a private CA; read by the `vault` CLI itself |

Plus the [shared variables](../../README.md#environment).

Every mode validates the token setting, including `fetch`, which never talks to
Vault.

## Authentication: why a static token is not enough

Backups need one capability, not root. The policy is
[`policies/backup-raft.hcl`](policies/backup-raft.hcl):

```bash
vault policy write backup-raft policies/backup-raft.hcl
```

The question is how the container gets a token carrying that policy, and keeps
getting one for as long as the schedule runs.

**This image does not renew or replace tokens.** It reads `VAULT_TOKEN`, or the
contents of `VAULT_TOKEN_FILE`, and uses what it finds. That makes every
static token a deadline:

| Token | What happens |
|---|---|
| `vault token create -ttl=…` | Expires at its TTL. Every run after that fails with `403 permission denied / invalid token`. |
| `vault token create -period=…` | Lives only while something renews it within each period. Nothing here does, so it expires one period after it was created: a 720h period is a silent failure 30 days later. |
| Root token | Never expires, and can do anything to the Vault it is stolen from. Do not. |

A scheduled container showing `Up` says nothing about this: the scheduler is
running, every backup is not. See
[Knowing when a backup fails](../../README.md#knowing-when-a-backup-fails).

**The fix is to let something that can log in hand the image a fresh token.**
[Vault Agent](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent)
does exactly that: it authenticates with a machine identity, writes the token
to a file, renews it, and authenticates again when renewal is no longer
possible — max TTL reached, token revoked, or Vault sealed and unsealed in
between. The image reads `VAULT_TOKEN_FILE` at the start of every run, so each
run picks up whatever the agent last wrote. No change to the image is needed.

| Where the backup runs | Machine identity | Agent shape |
|---|---|---|
| Docker host | [AppRole](https://developer.hashicorp.com/vault/docs/auth/approle): a role-id and a secret-id on disk | long-running sidecar container |
| Kubernetes | [Kubernetes auth](https://developer.hashicorp.com/vault/docs/auth/kubernetes): the pod's ServiceAccount token, nothing stored | init container that logs in once per Job and exits |

## Docker: AppRole and Vault Agent

[`docker/`](docker/) has the whole setup: a `vault-agent` sidecar, the
scheduled `backup` service, and a manual `restore` service.

```
docker/
├── compose.yaml   agent + backup + restore
├── agent.hcl      AppRole login, token written to an in-memory volume
├── .env           you create it: cp ../.env.example .env
└── secrets/       you create it: role-id and secret-id (git-ignored)
```

### 1. On Vault: policy, AppRole and role

Run these once, with a token allowed to manage auth methods and policies:

```bash
vault policy write backup-raft policies/backup-raft.hcl

vault auth enable approle

vault write auth/approle/role/vault-backup \
  token_policies=backup-raft \
  token_type=service \
  token_ttl=1h \
  token_max_ttl=24h \
  secret_id_ttl=0 \
  secret_id_num_uses=0
```

What each setting is for:

| Setting | Value | Why |
|---|---|---|
| `token_ttl` / `token_max_ttl` | `1h` / `24h` | The agent renews before the TTL and logs in again at the max TTL, so these only bound how long a leaked token stays useful. Any values work; long ones buy nothing. |
| `secret_id_ttl` | `0` | The secret-id is what the agent logs in with, on every new login. One that expires reproduces the expired-token failure one level up. Rotate it on your own schedule instead (below). |
| `secret_id_num_uses` | `0` | The agent logs in many times over its life. |

**Bind the credentials to where they are used** (recommended). A secret-id
copied off the host is then useless elsewhere:

```bash
vault write auth/approle/role/vault-backup \
  token_policies=backup-raft token_type=service \
  token_ttl=1h token_max_ttl=24h \
  secret_id_ttl=0 secret_id_num_uses=0 \
  secret_id_bound_cidrs=172.18.0.0/16 \
  token_bound_cidrs=172.18.0.0/16
```

The CIDR is whatever source address Vault sees from the agent container. For a
Vault on the same host reached through `host.docker.internal`, that is the
subnet of the Compose project's network:

```bash
docker network inspect platform-backup-vault_default \
  --format '{{(index .IPAM.Config 0).Subnet}}'
```

That network only exists after the first `docker compose up`, so create the
role without the bindings first, then tighten it. If Vault sits behind a proxy
or load balancer it sees the proxy's address instead, unless its listener
trusts `X-Forwarded-For`.

### 2. On the Docker host: credentials and configuration

```bash
cd backends/vault/docker
cp ../.env.example .env        # set VAULT_ADDR, the S3 settings and SCHEDULE

mkdir -p secrets
vault read  -field=role_id   auth/approle/role/vault-backup/role-id   > secrets/role-id
vault write -f -field=secret_id auth/approle/role/vault-backup/secret-id > secrets/secret-id

# The agent runs as uid 100; nobody else needs to read these.
sudo chown 100:1000 secrets/role-id secrets/secret-id
sudo chmod 0400     secrets/role-id secrets/secret-id
```

Leave `VAULT_TOKEN` out of `.env`. The compose file forces it empty for the
`backup` service anyway, because a value there would win over the agent's file.
Both containers read `.env`, so `VAULT_ADDR` and `VAULT_CACERT` are set in one
place. The agent takes it as an `env_file` rather than through `${VAULT_ADDR}`
on purpose: in interpolation, Compose lets the invoking shell's environment
win over `.env`, and an operator's shell that exports its own `VAULT_ADDR`
would silently point the agent at that address instead.

The secret-id is the one credential left on the host. Treat it like a
password: it is git-ignored, owned by the agent's uid, and — with the bindings
above — only usable from that Docker network.

### 3. Start and verify

```bash
docker compose up -d
docker compose logs vault-agent     # "authentication successful, sending token to sinks"
docker compose run --rm backup run  # one backup now, against the same volume
docker compose ps                   # backup turns (healthy) once a run succeeded
```

The `backup` service waits for the agent to be healthy, which means a token
file exists. The token lives on a `tmpfs` volume owned by uid 100: it is never
written to disk, and it disappears when the agent stops.

With `SCHEDULE` set, `docker compose up -d` leaves the container running and
backing up on that cron; add `RESTART_POLICY=unless-stopped` to `.env` so it
comes back after a reboot. With `SCHEDULE` empty it takes one backup and exits,
like the image itself, and the restart policy has to stay at its default `no`:
otherwise every exit restarts it, and one backup becomes a loop. The `/backup` volume is persistent, so
`docker ps` shows `(unhealthy)` once a run fails, and `NOTIFY_ON=change` works.

### 4. Rotating the secret-id

```bash
vault write -f -field=secret_id auth/approle/role/vault-backup/secret-id \
  | sudo tee secrets/secret-id >/dev/null
docker compose restart vault-agent

# Then destroy the old one by its accessor
vault list auth/approle/role/vault-backup/secret-id
vault write auth/approle/role/vault-backup/secret-id-accessor/destroy \
  secret_id_accessor=<old accessor>
```

The agent only reads the secret-id when it logs in, so it keeps working with
its current token until the restart.

### What happens when Vault is unavailable

| Event | Agent | Backup runs |
|---|---|---|
| Vault sealed or down | renewal fails; login is retried with exponential backoff, capped at 5 minutes | fail and notify |
| Vault unsealed or back | the next login attempt succeeds and a new token is written | succeed from the next run |
| Token reaches its max TTL | logs in again | unaffected |
| Agent container stopped | — | the last token works until its TTL, then runs fail |

Measured with Vault 1.18, a role with `token_ttl=30s` and `token_max_ttl=60s`,
and a backup every minute:

- The agent logged in again at every max TTL, and no run failed.
- Sealed for 140 seconds: login retries came 1, 2, 3, 6, 10, 20, 34 and 67
  seconds apart. The runs inside the window failed and were discarded. The
  agent logged in 6 seconds after the unseal, and the next run succeeded with
  nothing done by hand.

## Kubernetes: Kubernetes auth and an agent init container

[`k8s/cronjob.yaml`](k8s/cronjob.yaml) runs each backup as a Job whose init
container is Vault Agent: it logs in with the pod's ServiceAccount token,
writes a Vault token to an in-memory `emptyDir`, and exits. The backup
container then reads it through `VAULT_TOKEN_FILE`. Every run logs in afresh,
and nothing about Vault is stored in the cluster — there is no token or
secret-id to expire or leak.

### 1. On Vault: Kubernetes auth and a role

Vault must be able to call the cluster's TokenReview API. For a Vault running
inside the same cluster, under a ServiceAccount bound to the
`system:auth-delegator` ClusterRole (the official Helm chart does this), the
defaults are enough:

```bash
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc
```

For a Vault outside the cluster, give it the API address, the cluster's CA,
and a reviewer token from a ServiceAccount bound to `system:auth-delegator`;
see the [Kubernetes auth documentation](https://developer.hashicorp.com/vault/docs/auth/kubernetes#configuration).
With several clusters, enable one mount per cluster
(`vault auth enable -path=kubernetes-prod kubernetes`) and set `mount_path` in
the ConfigMap's `agent.hcl` to match.

Then the role, bound to the CronJob's ServiceAccount:

```bash
vault write auth/kubernetes/role/vault-backup \
  bound_service_account_names=vault-backup \
  bound_service_account_namespaces=<your-namespace> \
  token_policies=backup-raft \
  token_ttl=15m \
  token_max_ttl=1h
```

`token_ttl` only has to outlive one run: the token is used by one Job and
thrown away with its pod.

### 2. In the cluster

Replace `<your-namespace>` and fill in the Secret's S3 settings, then:

```bash
kubectl apply -f k8s/cronjob.yaml
kubectl -n <your-namespace> create job --from=cronjob/vault-backup vault-backup-now
kubectl -n <your-namespace> logs job/vault-backup-now -c vault-agent   # "authentication successful"
kubectl -n <your-namespace> logs job/vault-backup-now -c backup
```

The manifest creates the ServiceAccount, a ConfigMap holding `agent.hcl`, the
Secret and the CronJob. The pod runs as uid 100 / gid 1000 — the `vault` user
of both images — so it satisfies `runAsNonRoot`. Verified end to end on kind
with Vault 1.18 inside the cluster: the init container logged in, exited, and
the backup container took and verified the snapshot.

Notifications are configured in the same Secret. Leave `NOTIFY_ON=failure`
there: each run is a fresh pod with an `emptyDir`, so the state file never
survives and "previous outcome" is always unknown — `change` would fire on
every run, and a recovery message can never be sent. Failures notify either
way, which is the part that matters.

### AppRole on Kubernetes

Where Vault cannot reach the cluster's API, use AppRole in the same init
container instead: put `role-id` and `secret-id` in a Secret, mount it at
`/vault/approle`, and swap the `auto_auth` method in the ConfigMap for the one
in [`docker/agent.hcl`](docker/agent.hcl). Keep `exit_after_auth = true`.

## Restore

**Restore needs a much broader policy.** `sys/storage/raft/snapshot-force`
replaces the entire Vault state — every secret, mount and policy. Never give it
to the agent's role, and never leave a restore-capable token mounted in a
scheduled job. Use a privileged token for the one run, by hand, and revoke it
afterwards.

Docker, with the same `.env`:

```bash
cd backends/vault/docker
mkdir -p restore && sudo chown 100:1000 restore   # the image runs as uid 100

# Download and checksum-verify first, touching nothing
docker compose run --rm restore

# Then restore; RESTORE_TIMESTAMP=YYYYMMDD_HHMMSS pins a run, empty is the newest
docker compose run --rm -e MODE=restore -e VAULT_TOKEN=<privileged token> restore
```

The `restore` service mounts the agent's token only because the image asks for
one in every mode; that token can take snapshots and nothing else. A token
passed with `-e VAULT_TOKEN` wins over it.

Kubernetes: [`k8s/restore-job.yaml`](k8s/restore-job.yaml) reads the
privileged token from its own Secret, created for the restore and deleted
after it:

```bash
kubectl -n <your-namespace> create secret generic vault-restore-token \
  --from-literal=VAULT_TOKEN=<privileged token>
kubectl apply -f k8s/restore-job.yaml
kubectl -n <your-namespace> logs -f job/vault-restore
kubectl -n <your-namespace> delete secret vault-restore-token
```

The restore is applied with `-force`, which is what allows a snapshot to be
loaded into a Vault whose cluster identity differs from the one it was taken
from. Loaded into another cluster, it brings that cluster's keyring: unseal
with the keys **belonging to the snapshot**, not the ones for the cluster you
just overwrote. Loaded back into the cluster it came from, Vault stays unsealed
and serves the restored data at once (measured on 1.18: a secret changed after
the backup read its old value again, and the next backup ran normally). Auth methods are
part of the snapshot too: a role or secret-id created after the snapshot was
taken no longer exists once it is restored, so the agent may need a new
secret-id.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Runs fail with `403 … invalid token`, container `Up` | a static token expired | move to the agent setup above |
| Agent logs `error authenticating` with `permission denied` | wrong role-id, a destroyed secret-id, or a source address outside `secret_id_bound_cidrs` | check the address Vault sees in its audit log; issue a new secret-id |
| Agent logs `connection refused` or `i/o timeout` | Vault unreachable from the agent's network | a host firewall that only accepts traffic from `docker0` drops packets from the Compose project's own bridge; add `network_mode: bridge` to both services, and use docker0's subnet in the CIDR bindings |
| Backup logs `Set VAULT_TOKEN, or VAULT_TOKEN_FILE …` | no token file yet | the agent has not logged in; read its logs |
| `docker compose up` hangs on `vault-agent`, then fails as unhealthy | the agent never logged in; `backup` waits for it | `docker compose logs vault-agent` names the address and the error |
| Agent logs `permission denied` opening `/vault/approle/secret-id` | the agent (uid 100) cannot read the file | `sudo chown 100:1000 secrets/*` |
| `backup` stays `(unhealthy)` after a fix | the last recorded run is still the failure | `docker compose run --rm backup run` |
