import 'dart:io';

import 'hosts/hosts.dart';
import 'version.dart';

/// Topics for `podfly help [topic]`.
const helpTopics = <String>[
  'create',
  'deploy',
  'destroy',
  'doctor',
  'init',
  'smoke',
  'upgrade',
  'version',
  'hosts',
  'config',
  'workflow',
];

/// Print help. [topic] null / `help` → overview.
void printHelp([String? topic]) {
  final t = topic?.trim().toLowerCase();
  if (t == null || t.isEmpty || t == 'help' || t == 'overview') {
    _overview();
    return;
  }
  // Aliases
  final key = switch (t) {
    'nuke' => 'destroy',
    'up' => 'upgrade',
    'ver' || '-v' || '--version' => 'version',
    'host' || 'clouds' => 'hosts',
    'yaml' || 'podfly.yaml' => 'config',
    'getting-started' || 'quickstart' || 'start' => 'workflow',
    _ => t,
  };
  switch (key) {
    case 'create':
      _create();
    case 'deploy':
      _deploy();
    case 'destroy':
      _destroy();
    case 'doctor':
      _doctor();
    case 'init':
      _init();
    case 'smoke':
      _smoke();
    case 'upgrade':
      _upgrade();
    case 'version':
      _version();
    case 'hosts':
      _hosts();
    case 'config':
      _config();
    case 'workflow':
      _workflow();
    default:
      stderr.writeln('Unknown help topic: $topic');
      stderr.writeln('Topics: ${helpTopics.join(', ')}');
      _overview();
  }
}

void _header(String title) {
  stdout.writeln();
  stdout.writeln('podfly $podflyVersion — $title');
  stdout.writeln('=' * (18 + title.length));
  stdout.writeln();
}

void _overview() {
  ensureHostsRegistered();
  stdout.writeln('''
podfly $podflyVersion — scaffold + deploy Serverpod via existing cloud CLIs

  Not a host. Orchestrates fly / railway / wrangler / neonctl / … and encodes
  Serverpod + Flutter web quirks (Docker, publicHost, smoke, mobile CI).

USAGE
  podfly <command> [arguments]

COMMANDS
  create      Scaffold Serverpod monorepo + podfly.yaml (one shot)
  deploy      Doctor → init if needed → deploy API and/or web
  destroy     Tear down API + static web (opt-in database)
  nuke        Alias for destroy
  doctor      Check CLIs, auth, and config-aware requirements
  init        Write or refresh podfly.yaml only
  smoke       HTTP checks from smoke: in podfly.yaml
  upgrade     Update the podfly CLI (pub.dev / git / path)
  version     Print version
  help        Show this overview, or help <topic>

GLOBAL
  -h, --help     Show help (command-specific when used after a command)
  --version      Same as: podfly version

HELP TOPICS (detailed)
  podfly help create | deploy | destroy | doctor | init | smoke
  podfly help upgrade | version | hosts | config | workflow

  Also:  podfly create --help   podfly deploy --help   …

QUICK START
  podfly create my_app --yes
  cd my_app
  fly auth login          # once
  podfly deploy --smoke

  # Already have a Serverpod tree?
  cd my_serverpod_app && podfly deploy --yes --smoke

SEE ALSO
  https://pub.dev/packages/podfly
  https://github.com/127thousand/podfly
  doc/podfly.yaml.md · doc/database.md · doc/ci.md
''');
}

void _create() {
  ensureHostsRegistered();
  final hosts = HostRegistry.cliAllowedIds.join(' | ');
  _header('create');
  stdout.writeln('''
SYNOPSIS
  podfly create [name] [options]

DESCRIPTION
  One-shot project bootstrap for Serverpod (flagship path):

    1. serverpod create  (or flutter create for --kind app-only)
    2. Write podfly.yaml via init overrides (no second wizard)
    3. Write PODFLY.md with local + deploy next steps
    4. Print host CLI / login tips

  App-only (--kind app-only) is experimental: Flutter only, no Serverpod API.

ARGUMENTS
  name                 Project name (lowercase, [a-z0-9_]). Sanitized if needed.
                       Prompts when omitted (or my_app with --yes).

OPTIONS
  -d, --directory <dir>   Parent directory (default: current working directory).
                          Project lands at <dir>/<name>/.

  --kind <kind>           What to scaffold:
                            app-backend   Flutter + Serverpod (default)
                            backend-only  Serverpod server (+ client), no UI tree
                            app-only      Flutter only (experimental)

  --surfaces <list>       Client surfaces (comma-separated). Ignored for backend-only.
                            mobile,web    both (default with --yes)
                            mobile        API-only deploy + Codemagic on first API deploy
                            web           web only

  --host <id>             API cloud host (default: fly).
                            $hosts

  --mode <mode>           Web topology when web surface is on:
                            split      CDN / native web UI + API (default with --yes)
                            monolith   Flutter web + API on one host URL
                            fly        legacy alias for monolith

  --template <t>          serverpod create template:
                            mini | fullstack | server | module
                          Default: mini if no DB, fullstack if --database is set
                          (backend-only always uses server unless overridden).

  --database <provider>   podfly.yaml database provider; also drives template:
                            none | neon | fly_postgres | sqlite | supabase
                            railway_postgres | digitalocean_postgres | render_postgres
                          With --yes, default is none (fastest demo).

  -y, --yes               Non-interactive defaults:
                            kind=app-backend, surfaces=mobile+web, host=fly,
                            mode=split, database=none, template=mini

  --dry-run               Plan only (no serverpod create, no files).

EXAMPLES
  podfly create my_app --yes
  podfly create shop --database neon --yes
  podfly create api --kind backend-only --host cloud-run --yes
  podfly create mobile_app --surfaces mobile --yes
  podfly create plan --yes --dry-run -d /tmp

INTERACTIVE (TTY, without --yes)
  Asks: name → kind → surfaces → database → host → web topology (if web).

AFTER CREATE
  cd <project>
  serverpod start
  podfly doctor
  podfly deploy --smoke          # or --api --smoke for mobile-only

SEE ALSO
  podfly help deploy · podfly help workflow · podfly help config
''');
}

void _deploy() {
  ensureHostsRegistered();
  final hosts = HostRegistry.cliAllowedIds.join(' | ');
  _header('deploy');
  stdout.writeln('''
SYNOPSIS
  podfly deploy [options]
  podfly [options]                 # bare flags imply deploy (e.g. podfly --smoke)

DESCRIPTION
  End-to-end ship for a Serverpod monorepo with podfly.yaml:

    1. Doctor (tools + auth; Flutter only if web will be built)
    2. Init podfly.yaml if missing (or --init)
    3. Ensure API app / secrets / database / redis as configured
    4. Build & deploy API container (host adapter)
    5. Optionally build Flutter web + push CDN or native web service
    6. Optional --smoke HTTP checks

  Host behavior lives in HostAdapter (Fly, Railway, Cloud Run, …) — not
  hard-coded switches in the deploy driver.

OPTIONS
  --dry-run          Plan only: print commands, no create/deploy network side effects
  --smoke            After deploy, run smoke: endpoints from podfly.yaml
  --api              API only (skip Flutter web / Pages). Typical for mobile.
  --web              Web only, or force web even if web.enabled: false
  --yes, -y          Non-interactive init defaults when creating podfly.yaml
                     (skips host/CDN questions — omit for interactive pickers)
  --no-login         Never open browser logins (CI: use tokens)
  --init             Force init wizard; confirms before overwriting podfly.yaml
  --host <id>        Override / set API host for this run:
                       $hosts
  --mode <mode>      split | monolith | fly (legacy monolith alias)
  --root <dir>       Project root (default: cwd)
  --config <path>    Explicit path to podfly.yaml

FLAGS COMBINATIONS
  (default)          API + web if web.enabled
  --api              API only
  --web              Web only (forces web build/deploy)
  --api --web        Both

ENVIRONMENT (CI)
  FLY_API_TOKEN, RAILWAY_TOKEN, CLOUDFLARE_API_TOKEN, VERCEL_TOKEN,
  NETLIFY_AUTH_TOKEN, DIGITALOCEAN_ACCESS_TOKEN, NEON_API_KEY, …
  See: podfly help workflow · doc/ci.md

EXAMPLES
  podfly deploy --smoke
  podfly deploy --api --yes --smoke
  podfly deploy --host railway --yes
  podfly deploy --mode monolith --smoke
  podfly --smoke                   # shorthand

SEE ALSO
  podfly help destroy · podfly help smoke · podfly help hosts · podfly help config
''');
}

void _destroy() {
  _header('destroy');
  stdout.writeln('''
SYNOPSIS
  podfly destroy [options]
  podfly nuke [options]            # alias

DESCRIPTION
  Tear down cloud resources described by podfly.yaml:

    • API app / service on the configured host
    • Static web (Cloudflare Pages / Vercel / Netlify / GitHub Pages) when
      split mode used a CDN
    • Managed database only with --database (opt-in; never default)

  Requires confirmation: --yes when non-interactive.

OPTIONS
  --yes, -y          Confirm destruction (required without TTY)
  --api              Destroy API only
  --web              Destroy web only
  --database         Also delete managed Postgres (Supabase / Fly PG / Neon / …)
  --dry-run          Print plan only
  --root / --config  Project root or explicit podfly.yaml

EXAMPLES
  podfly destroy --yes
  podfly destroy --api --yes
  podfly destroy --yes --database --dry-run

WARNING
  --database is irreversible for provisioned clusters. Prefer --dry-run first.

SEE ALSO
  podfly help deploy · podfly help config
''');
}

void _doctor() {
  _header('doctor');
  stdout.writeln('''
SYNOPSIS
  podfly doctor [options]

DESCRIPTION
  Two scopes:

    baseline       flutter/dart, optional tools
    config-aware   host CLI + auth, CDN CLIs, neonctl, etc. from podfly.yaml

  On a TTY (or PODFLY_AUTO=1), may offer to install missing CLIs and open logins.

OPTIONS
  --dry-run          Skip version probes that would hit the network oddly;
                     treat missing tools as dry-run friendly where applicable
  --no-login         Do not open browser logins
  --root / --config  Load podfly.yaml for config-aware checks

EXAMPLES
  podfly doctor
  podfly doctor --no-login
  podfly doctor --config ./podfly.yaml

SEE ALSO
  podfly help upgrade · podfly help hosts
''');
}

void _init() {
  _header('init');
  stdout.writeln('''
SYNOPSIS
  podfly init [options]

DESCRIPTION
  Interactive (or --yes) wizard that writes podfly.yaml only:

    • Detect server / flutter packages
    • Pick API host and web topology
    • Database provider, Flutter web build mode, smoke defaults

  Prefer podfly create for greenfield Serverpod projects (scaffold + yaml).
  Prefer podfly deploy for existing trees (init runs automatically if yaml missing).

OPTIONS
  --yes, -y          Non-interactive defaults (Fly + Cloudflare split, etc.)
  --host <id>        Preferred API host for defaults
  --dry-run          Doctor dry-run; still writes config unless you avoid paths
  --root / --config  Project root or output path for podfly.yaml
  --no-login         Doctor: no browser logins

EXAMPLES
  podfly init
  podfly init --yes --host railway
  podfly init --config ./custom-podfly.yaml

SEE ALSO
  podfly help create · podfly help config
''');
}

void _smoke() {
  _header('smoke');
  stdout.writeln('''
SYNOPSIS
  podfly smoke [options]

DESCRIPTION
  Run HTTP checks defined under smoke: in podfly.yaml against the live API
  (and optional web) URLs. Used standalone or via podfly deploy --smoke.

  Typical Serverpod mini default:

    smoke:
      api:
        method: POST
        path: /greeting/hello
        body: "{}"
        expect_status: 200

OPTIONS
  --root / --config  Project root or podfly.yaml path

EXAMPLES
  podfly smoke
  podfly deploy --smoke

SEE ALSO
  podfly help deploy · podfly help config
''');
}

void _upgrade() {
  _header('upgrade');
  stdout.writeln('''
SYNOPSIS
  podfly upgrade [options]

DESCRIPTION
  Reinstall/update the podfly CLI via dart pub global activate.

  Compares dart pub global list before/after and prints the new version.
  The running process may still report the old version until you invoke
  podfly again.

OPTIONS
  --dry-run          Print the activate command only
  --git              Activate from GitHub (127thousand/podfly) instead of pub.dev
  --git-url <url>    Custom git URL (implies git source)
  --path <dir>       Activate from a local path (contributors)
  -y, --yes          Reserved for non-interactive confirms (activate is always run)

EXAMPLES
  podfly upgrade
  podfly upgrade --dry-run
  podfly upgrade --git
  podfly upgrade --path /Users/you/projects/127k/podfly

SEE ALSO
  podfly version · podfly help doctor
  https://pub.dev/packages/podfly
''');
}

void _version() {
  _header('version');
  stdout.writeln('''
SYNOPSIS
  podfly version
  podfly --version

DESCRIPTION
  Print the version embedded in this binary ($podflyVersion).

  For the version activated via pub global, run:

    dart pub global list | grep podfly

  Or:  podfly upgrade --dry-run   (shows this binary + global list)
''');
}

void _hosts() {
  ensureHostsRegistered();
  _header('hosts');
  stdout.writeln('''
SYNOPSIS
  API clouds implemented as HostAdapter plugins (podfly.yaml host:).

HOSTS
''');
  for (final a in HostRegistry.all) {
    final mark = a.canDeploy ? '✅' : '🗺️';
    stdout.writeln(
      '  $mark ${a.id.padRight(14)} ${a.label}\n'
      '       CLI: ${a.cliBinaries.join(', ')}\n'
      '       ${a.capabilitySummary}\n'
      '       Install: ${a.installHint}\n',
    );
  }
  stdout.writeln('''
WEB (split mode CDN)
  cloudflare (wrangler) · vercel · netlify · github_pages (gh)

SEE ALSO
  podfly help deploy · podfly help config · doc/podfly.yaml.md
''');
}

void _config() {
  _header('config (podfly.yaml)');
  stdout.writeln('''
SYNOPSIS
  Project file written by create/init, read by deploy/destroy/smoke/doctor.

IMPORTANT KEYS
  host:                 API cloud (fly | railway | cloud_run | …)
  mode:                 split | monolith
  web_host:             cloudflare | vercel | netlify | github_pages
  name / server / flutter
  fly: / railway: / …   Host-specific blocks
  database:             provider: none | neon | fly_postgres | …
  web:
    enabled:            false → API-only (mobile)
    api_url:            Public API base (trailing slash)
    build:              canvaskit | canvaskit_cdn | wasm
  smoke:
    api: / web:         HTTP checks for --smoke
  mobile:
    provider:           none | codemagic | github_actions

DOCS
  https://github.com/127thousand/podfly/blob/main/doc/podfly.yaml.md
  https://github.com/127thousand/podfly/blob/main/doc/database.md

SEE ALSO
  podfly help create · podfly help init · podfly help deploy
''');
}

void _workflow() {
  _header('workflow');
  stdout.writeln('''
GREENFIELD
  1. dart pub global activate podfly
  2. dart pub global activate serverpod_cli
  3. podfly create my_app --yes
  4. cd my_app && serverpod start          # local
  5. fly auth login                        # or host login
  6. podfly deploy --smoke

EXISTING SERVERPOD TREE
  1. cd my_app
  2. podfly deploy --yes --smoke           # writes podfly.yaml if missing
  # Interactive host pick: omit --yes on first deploy

MOBILE / API ONLY
  podfly create app --surfaces mobile --yes
  podfly deploy --api --smoke
  # codemagic.yaml synced on deploy when mobile.provider: codemagic

WITH POSTGRES
  podfly create shop --database neon --yes
  podfly deploy --smoke                    # wires DB per host adapter

CI
  Use tokens + --yes --no-login [--smoke]
  See doc/ci.md

UPGRADE CLI
  podfly upgrade

SEE ALSO
  podfly help create · podfly help deploy · podfly help upgrade
''');
}
