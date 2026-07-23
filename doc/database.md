# Database providers & detection

## Providers

| `database.provider` | Best for | Scale-to-zero API | Multi-machine | Notes |
|---------------------|----------|-------------------|---------------|--------|
| **`none`** | Stateless APIs | Yes | Yes | Omit `database:` in production |
| **`sqlite`** | Tiny single-node apps | Yes (with volume) | No | Fly volume + `ha: false` |
| **`fly_postgres`** | Classic Serverpod on Fly | Partial* | Yes | *PG app keeps billing when API stops |
| **`railway_postgres`** | Railway full stack | Partial* | Yes | *Postgres plugin does not sleep with API |
| **`digitalocean_postgres`** | DO App Platform | Partial* | Yes | *Managed DBaaS bills independently |
| **`neon`** | Serverless PG | Yes | Yes | SSL; store URL as host secret |
| **`supabase`** | Managed PG (Supabase) | Partial* | Yes | SSL; CLI provision + sidecar password |

\* Managed Postgres usually keeps billing when the API scales to zero.

## What podfly does on deploy

1. **Ensure** resources when configured (`create` / `provision` flags)  
2. **Patch** `server/config/production.yaml` (writes `.podfly.bak` once)  
3. Print next steps for secrets you must set by hand  

### `none`

- Removes or comments out active `database:` block  
- Prefers `sessionLogs.persistentEnabled: false`  

### `sqlite`

- Optional `fly volumes create`  
- Documents `[[mounts]]` for `fly.toml`  
- Notes that Serverpod is historically Postgres-first — verify your version  

### `fly_postgres`

- Ensures the **API Fly app exists** before attach (attach requires `-a <api>`)
- Optional `fly postgres create` + `fly postgres attach -y`
- Parses `DATABASE_URL` from attach output (attach creates app-specific user/db, not `postgres`)
- Writes `server/config/.podfly_fly_pg.json` sidecar + patches `production.yaml` and `passwords.yaml production.database`
- Re-deploys reuse the sidecar when attach reports “already attached” (Fly secrets are not readable)  

### `railway_postgres`

- Requires `host: railway`
- Optional add Postgres plugin; wire `DATABASE_URL` reference onto the API service
- Writes `.podfly_railway_pg.json` when plugin vars are readable; patches `production.yaml` / `passwords.yaml`

### `digitalocean_postgres`

- Requires `host: digitalocean`
- Optional `doctl databases create` (Managed Postgres / DBaaS)
- Uses **public** host + `requireSsl: true` (App Platform reaches DBaaS without a pre-wired VPC)
- Writes `server/config/.podfly_do_pg.json` + patches `production.yaml` / `passwords.yaml`
- After API app exists: `doctl databases firewalls append <db> --rule app:<app-id>`
- Do **not** open `0.0.0.0/0` (DO rejects `/0` masks)

### `neon`

- Optional `neonctl projects create`  
- Expects host secret set (e.g. `fly secrets set DATABASE_URL=…`)  
- Writes `requireSsl: true` host block when host is known  

### `supabase`

- Optional `supabase projects create` (`provision: true`) with generated DB password  
- Direct host `db.<project_ref>.supabase.co`, `requireSsl: true`  
- Writes `server/config/.podfly_supabase_pg.json` + patches `production.yaml` / `passwords.yaml`  
- Password is **not** recoverable via CLI after create — keep the sidecar  

See [supabase.md](supabase.md).

**Never commit DB passwords or sidecar JSON** (`.podfly_fly_pg.json`, `.podfly_railway_pg.json`, `.podfly_do_pg.json`, `.podfly_supabase_pg.json`). Prefer CI attach/patch (see [ci.md](ci.md)) or secrets managers.

## Automatic detection

During `podfly init` (and `--yes` defaults), podfly inspects the server (and
sibling Flutter package) and sets a recommended provider.

### Hard “needs database” (`DatabaseNeed.required`)

Any of:

- Active `table:` in `*.spy.yaml` (uncommented)  
- Migration **app** tables (not only `serverpod_*` core)  
- App code using `session.db` / `.insertRow` / `.find(` outside `generated/` and not under template `auth/`  
- App endpoint `bool get requireLogin => true`  
- App code checking `session.authenticated` / similar  
- Flutter **home / initialRoute is sign-in**  
- `sessionLogs.persistentEnabled: true`  
- Active `database:` already in production.yaml (mild signal)  

Default suggestion: **`neon`** (scale-to-zero friendly) unless you pick another.

### Soft “template auth only” (warnings, still `none` OK)

Serverpod **create** scaffolds often include auth you never use:

- `serverpod_auth_*` pubspec dependencies  
- `initializeAuthServices` in `server.dart`  
- Many `serverpod_auth_*` migration tables  
- Flutter `sign_in_screen.dart` that is **not** the app home  
- `client.auth.initialize()` without an auth-gated shell  

These produce **warnings**, not a hard requirement:

```text
need: none
authScaffolded: true
authActivelyUsed: false
! template auth deps… strip if unused, else need a DB for login
! sign_in_screen exists but is not app home
! production omits database — fine if you never call login
```

### Why this matters

Example: **Sacred Draw** ships draw-only UI with no login product feature, but
still has IDP init + auth migration tables from the template. Runtime works
with `database: none` for `/tarot/draw`. Enabling real login later **requires**
Postgres (Neon or Fly).

## Choosing at init

Wizard labels reflect detection:

- “looks stateless; template auth unused — none OK”  
- “app uses tables/auth — DB recommended”  

You can always override.

## Migrations

- If provider ≠ `none` and `migrations/` is non-empty: apply migrations with your usual Serverpod workflow after first deploy.  
- If provider = `none` but migrations exist: doctor/init may warn (template or unused schema).  

## Stripping unused auth (optional)

If you want a truly auth-free server:

1. Remove `serverpod_auth_*` deps from server / client / flutter  
2. Remove `initializeAuthServices` and `lib/src/auth/*` endpoints  
3. Remove Flutter sign-in screen and `FlutterAuthSessionManager` wiring  
4. Regenerate (`serverpod generate`)  
5. Optionally clean migrations (advanced)  

Then detection reports a clean **none** with few or no auth warnings.
