# Supabase Postgres — `database.provider: supabase`

Managed **PostgreSQL** for Serverpod via the [Supabase CLI](https://supabase.com/docs/guides/cli).

podfly wires **Postgres only** (connection host + password). Supabase Auth, Storage,
Realtime, and Edge Functions are out of scope — use Serverpod’s own stack for those.

## Prerequisites

```bash
brew install supabase/tap/supabase   # or: npm i -g supabase
supabase login
# CI: SUPABASE_ACCESS_TOKEN
```

## Config

```yaml
database:
  provider: supabase
  supabase:
    project_name: my-app-db    # defaults to <name>-db
    region: us-east-1
    provision: true            # create if missing
    # project_ref / host filled after first provision
    # org_id: optional (defaults to first org from `supabase orgs list`)
```

| Key | Description |
|-----|-------------|
| `project_name` | Supabase project display name |
| `project_ref` | Stable ref (`db.<ref>.supabase.co`) |
| `org_id` | Organization id |
| `region` | Create region (e.g. `us-east-1`) |
| `provision` | Create when missing (default `true`) |
| `host` | Override (default `db.<project_ref>.supabase.co`) |
| `database` / `user` / `port` | Defaults `postgres` / `postgres` / `5432` |

## What podfly does

1. `supabase projects list` — reuse by `project_ref` or name  
2. `supabase projects create … --db-password <generated>` when provisioning  
3. Writes `*_server/config/.podfly_supabase_pg.json` (host, user, password, ref)  
4. Patches `production.yaml` (`requireSsl: true`) + `passwords.yaml` → `production.database`  
5. Persists `project_ref` + `host` into `podfly.yaml`

**Password is only available at create time.** The sidecar must be kept (gitignored)
for re-deploys. If you lose it, reset the DB password in the dashboard and rewrite
the sidecar, or delete the project and provision again.

## Deploy

```bash
# podfly.yaml: database.provider: supabase
podfly deploy --yes --smoke
```

Doctor requires `supabase` CLI + login / `SUPABASE_ACCESS_TOKEN`.

### Free-tier limit

Create fails if the account has no free project slots (often **2 active free projects**).
Pause, delete, or upgrade an unused project, then re-run. Paid compute may still hit the
same free-project count depending on plan.

### Example (bidirectional smoke)

[podfly_examples/supabase/notes](https://github.com/127thousand/podfly_examples/tree/main/supabase/notes)
— Fly API + Supabase PG; `POST /note/add` then `POST /note/list` proves write and read.

Verified end-to-end (then torn down): insert rows, list returns them, count matches; Flutter UI on Netlify.

### Migration integrity warning

On Supabase, Serverpod may apply migrations successfully then log
`Invalid date format` / `now()Z` while verifying schema (Supabase default expressions).
App CRUD can still work; treat as a known Serverpod↔Supabase analyzer quirk unless
endpoints fail.

## Teardown

```bash
supabase projects list
supabase projects delete --project-ref <ref>
# confirm prompts as required by CLI

rm -f *_server/config/.podfly_supabase_pg.json
# strip production.database from passwords.yaml if present
```

Never commit the sidecar or passwords.

## Related

- [database.md](database.md)  
- [podfly.yaml — database](podfly.yaml.md)  
- [Upstash Redis](upstash.md) (optional cache/PubSub; orthogonal to Supabase PG)  
