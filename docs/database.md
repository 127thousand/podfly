# Database providers & detection

## Providers

| `database.provider` | Best for | Scale-to-zero API | Multi-machine | Notes |
|---------------------|----------|-------------------|---------------|--------|
| **`none`** | Stateless APIs | Yes | Yes | Omit `database:` in production |
| **`sqlite`** | Tiny single-node apps | Yes (with volume) | No | Fly volume + `ha: false` |
| **`fly_postgres`** | Classic Serverpod | Partial* | Yes | *PG app keeps billing when API stops |
| **`neon`** | Serverless PG | Yes | Yes | SSL; store URL as Fly secret |

\* Fly Postgres is a separate always-on (or separately billed) resource.

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

- Optional `fly postgres create` + `attach`  
- Writes internal host-style `database:` block  

### `neon`

- Optional `neonctl projects create`  
- Expects `fly secrets set DATABASE_URL=…` (secret name configurable)  
- Writes `requireSsl: true` host block when host is known  

**Never commit DB passwords.** Use Fly secrets / `passwords.yaml` patterns Serverpod expects.

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
