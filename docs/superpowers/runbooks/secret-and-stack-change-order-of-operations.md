# Secret & Stack Change — Order of Operations

Order-sensitive procedures for changing secrets, renaming DB sidecars, and
removing stacks/services in the `op://` + GitOps + watchtower world. Distilled
from the `docker-zendc` healthcheck / naming-normalization / secret-rotation /
watchtower-fold work (2026-06), where getting the order wrong failed deploys.

> **The golden rule:** the deploy runs `op run --env-file=compose.env -- docker compose …`
> for **every** operation, including the teardown of a *removed* stack. `op run`
> resolves **every** `op://` reference in `compose.env` up front and **fails the
> whole command if any referenced field is missing**. Therefore an op item/field
> must keep existing for as long as `compose.env` references it.

---

## 1. Removing a stack or a service (and its secrets)

**Wrong order (fails the deploy):** delete the op item/field first → a commit
still references it in `compose.env` → that commit's deploy runs `op run`, can't
resolve the deleted field, and **the teardown fails** (`item '…' does not have a
field '…'`).

**Correct order:**

1. **Compose first, in ONE commit:** remove the service/stack from `*/compose.yaml`
   **and** delete its `VAR=op://…` lines from `compose.env`. Keep these together
   so no intermediate commit is independently deployable in a broken state (e.g.
   stack dir gone but `compose.env` still referencing its secret, or vice-versa).
2. **Push + deploy.** The removed-stack teardown now runs with the refs already
   gone (`op run` resolves a clean `compose.env`; the stale stack's `${VAR}`s are
   simply undefined → compose warns, `down` proceeds).
3. **Only then** delete the op item/fields, the host datadir, and (if needed) any
   leftover containers.

**Shortcut:** if you `docker stop && docker rm` the stack's containers by hand,
the stack is *effectively torn down already* — a deploy isn't required to remove
it (only to create anything you're folding it into elsewhere).

---

## 2. Renaming a DB sidecar + rotating its password (combined, per app)

Do **one app at a time**, verify green, then the next. Never batch blindly — the
secret's load-bearing location is **not uniform** (config file vs inline compose
vs op field vs full DSN-in-op).

1. **compose**: rename `service` key + `container_name` + `hostname` + `depends_on`
   + `com.github.saltbox.depends_on` label + any inline host (`DATABASE_URL`,
   `POSTGRES_SERVER`, …). **Keep the data-bind path** (`${APPDATA_PATH}/<old>`) —
   the bind source need not match the container name, so no data is moved.
2. **compose.env**: point the op refs at the new item name (`zendc-<app>-<db>`).
3. **op**: `op item edit … --title <new>` to rename, then set the rotated value.
   Verify every change with `op read` (see §4).
4. **stop the app** (and any sidecar that holds DB connections, e.g. a runner)
   *before* the `ALTER`, so there are no live connections to break.
5. **rotate on the DB** (generate `N`, 32 alnum, never echo it):
   - mariadb: `ALTER USER '<user>'@'%' IDENTIFIED BY '<N>'; FLUSH PRIVILEGES;`
     via `docker exec -i <db> mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"` (SQL piped on stdin).
   - postgres: `ALTER ROLE "<role>" WITH PASSWORD '<N>';` via
     `docker exec -i <db> psql -U <role> -d <db>` (local socket = trust).
6. **update the load-bearing location with `N`**: the config file (gitea
   `app.ini`, privatebin `conf.php`), or the op field the app reads
   (`DATABASE_URL` / `DB_PASSWORD` / a DSN), **and** the bootstrap op field for
   consistency. (Bootstrap `MARIADB_*`/`POSTGRES_*` env only applies on an empty
   datadir, so it's not load-bearing on an existing one — but keep it in sync.)
7. **stop + rm the OLD db container** (frees the datadir so the renamed container
   can claim the same bind without a two-process lock).
8. **push** compose + compose.env → deploy → verify the app reconnects healthy.

---

## 3. Rotating an env-only secret (no rename)

1. Rotate the value: `op item edit …` (verify by `op read`).
2. Apply it: `gh workflow run "Deploy Docker Compose" -f force-deploy=true`.
   `force-deploy` re-resolves `op://` and recreates **only** the containers whose
   resolved env changed (unchanged stacks are a no-op) — the running app keeps the
   old value until then, so there's no lockout for app-internal secrets.

Special cases:
- **vaultwarden `ADMIN_TOKEN`**: must be an argon2id PHC string. `vaultwarden hash`
  needs a TTY (can't pipe), so generate it directly (argon2-cffi, preset
  m=65540,t=3,p=4); store the hash in `admin_token` and the plaintext in a
  separate op field for /admin login. The `$`s survive because op→env→compose
  substitution is single-pass.
- **Elasticsearch (tubearchivist)**: the bootstrap `ELASTIC_PASSWORD` env does
  **not** reset the password on an existing datadir — change it via the Security
  API (`POST /_security/user/elastic/_password`), then sync op, then recreate.

---

## 4. op CLI gotchas

- These items live in 1Password account **`MSLU2ENN65CNVMCAIWVKY73Q6Q`**. `op read`/
  `op item get` find them without `--account`, but **`op item edit` 404s unless you
  pass `--account MSLU2ENN65CNVMCAIWVKY73Q6Q --vault Docker`** (account-targeting
  quirk, not permissions). The deploy resolves refs via `OP_SERVICE_ACCOUNT_TOKEN`,
  a different context.
- **`op item edit --title` (rename) reports `(404) Not Found` but STILL commits**
  the change. Never trust the exit code — **always verify with `op read`.**

---

## 5. watchtower policy (zendc)

Everything in compose is Renovate-managed, so **every service carries
`com.centurylinklabs.watchtower.enable: "false"`** (watchtower must ignore it;
Renovate owns image updates). A single `watchtower` (in the `monitoring` stack,
no `WATCHTOWER_SCOPE`, self-update off, itself `enable=false`) handles only the
non-repo containers. Scoped watchtower instances and `watchtower.scope` labels
were removed once nothing carried a scope.
