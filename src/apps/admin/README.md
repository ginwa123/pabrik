# Admin console

The owner of a Pabrik installation manages its accounts from here: create an
account, change its role, switch it off, and reset a password for somebody
who has lost theirs.

The console is a static page served by the Zig backend. There is no build
step, no bundler and no framework: three files and the endpoints behind them.

```
src/apps/admin/
  index.html      the page
  admin.css       the stylesheet
  admin.js        the script
  admin_page.zig  serves the three files
  admin_api.zig   the /api/admin endpoints
  admin_store.zig the reads and writes on `users`
  admin_common.zig who the owner is, and the pure helpers
  runtime.zig     the database + `--auth` switch the host installs
  mod.zig         the package's public face
  main.zig        `pabrik-admin`, the standalone program
  build.zig       its own build: `zig build run` right here
  build.zig.zon   the two packages it links (SQLite, the HTTP server)
```

## Opening it

Two ways to run it, and both serve the same page and the same endpoints.

### Inside pabrik (a normal installation)

```bash
zig build install:linux
./zig-out/bin/pabrikcore-linux-x86_64 --port 8080     # add --auth for a real login
```

Then open `http://127.0.0.1:8080/admin`. With `--auth` on, create the owner
first: `pabrik create-admin --email you@example.com --password …`, sign in,
and the console answers 401/403 to anyone else.

### On its own (`pabrik-admin`)

The console is also a program of its own. It links only the SQLite package
and the HTTP server package, not pabrik, so it builds in seconds:

```bash
cd src/apps/admin
zig build run -- --db ~/.config/pabrik/agent.db --port 8090
```

```
pabrik-admin ready
  console: http://127.0.0.1:8090/admin
  database: /home/you/.config/pabrik/agent.db
  owner: the local operator (no --auth)
```

| flag | meaning |
|---|---|
| `--db <path>` | the database to administer (default `~/.config/pabrik/agent.db`) |
| `--port <n>` | the port to listen on (default `8090`) |
| `--auth on\|off` | off (default): the local operator owns the installation. on: a `pabrik_session` cookie decides the owner |
| `-h`, `--help` | usage |

Point it at the database pabrik itself uses and it is the same console. Point
it at a new file and it creates the `users` and `auth_sessions` tables that
the console needs; start pabrik on that database afterwards and its
migrations fill in the rest.

`zig build test` in that folder runs the console's own 21 tests.

The folder is a Zig package of its own (`build.zig`, `build.zig.zon`), which
is why `src/http_handlers/auth_core.zig` exists: the session cookie, the token
hash and the bcrypt hash are declared as their own module, so the standalone
program can link that one file instead of all of pabrik.

## Who may use it

The console belongs to the **owner** of the installation.

| `--auth` | who the owner is |
|---|---|
| off | the operator running the installation |
| on | the account whose `users.role` is `admin` |

Every endpoint answers `401` without a usable session and `403` for a session
that is not an owner. The page itself is served without a session: it has to
load before it can ask who is asking.

## The endpoints

| method | path | what it does |
|---|---|---|
| `GET` | `/api/admin/overview` | the counts the page opens with |
| `GET` | `/api/admin/users` | every real account (the system account is not one) |
| `POST` | `/api/admin/users` | create an account |
| `PATCH` | `/api/admin/users/:id` | change the role, or switch the account off |
| `POST` | `/api/admin/users/:id/password` | reset a password |

### Creating an account

`POST /api/admin/users` with `{"email": "...", "name": "...", "role": "user"}`.

The email is required and must look like an address; the role is optional and
is one of `admin`, `user` or `bot`. Without a password the console mints a
temporary one and returns it **once**:

```json
{ "user": { "id": "user_…", "email": "…", "role": "user", … },
  "temporary_password": "k7m2pq4rx8ntvz3d" }
```

Hand it to the account holder. The server only stores its bcrypt hash.

### Resetting a password

`POST /api/admin/users/:id/password` with `{}` resets the password to a new
temporary one and returns it. Every session that account had open is closed,
so a session opened with the old password stops working.

### Resizing a workspace's VM

The console lists every workspace's microVM with the size it runs as, and can
change it. **This needs a restart**, and that is Firecracker, not the UI:
`machine-config` (vCPUs and RAM) is accepted only before `InstanceStart`, and
there is no live disk resize. So a resize is: stop that workspace's VM, record
the size it must boot with, start it again. The guest comes back in a few
seconds; the processes inside it do not.

| method | path | what it does |
|---|---|---|
| `GET` | `/api/admin/vms` | every workspace's VM: state, vCPUs, memory |
| `POST` | `/api/admin/vms/:workspace/resize` | stop, resize, start |

`POST` body: `{"vcpus": 2, "mem_mib": 1024}` — vCPUs `1..8`, memory
`128..16384` MiB **in 128 MiB steps** (Firecracker refuses anything off that
grid at boot, so the console refuses it first). The answer is the state the VM came back in (`ready`, or
`failed` with the guest's reason). A host with no manager answers
`503 NoVmManager` and the panel says so, instead of offering a control that
cannot work.

The size lives beside the VM: `pabrik-vmd` records it per workspace in
`<root>/workspaces/<id>/vm.spec`, so the manager needs no database and a
workspace with no record keeps the manager's defaults.

The same resize is a command, which is how CI proves it on a real guest:

```bash
pabrik-vmd resize --socket /run/user/$UID/pabrik-vmd.sock \
  --workspace-id ws_123 --vcpus 2 --mem 1024
scripts/vmd-resize-smoke.sh   # boots, resizes, and reads nproc + MemTotal inside the VM
```

### The last owner

An installation with no owner cannot be administered again, so the console
refuses to demote or switch off the last active owner (`409`). Make a second
owner first.

## The database

`users` (Migration 077) already carries `role`, `is_active`, `email` and
`password_hash`. The console needs no migration of its own.

## The design gate

The console is an app screen, so the landing-page pipeline (the direction
draw, the imagery hunt) does not apply. The house rules and the measurable
laws do, and both scanners were run against the live console.

```bash
node <taste-skill>/scripts/lint.mjs src/apps/admin/index.html \
  src/apps/admin/admin.css src/apps/admin/admin.js
CHROME_PATH=~/.cache/ms-playwright/chromium-1248/chrome-linux64/chrome \
  node <taste-skill>/scripts/inspect.mjs http://127.0.0.1:8083/admin
```

| scanner | reading |
|---|---|
| `lint.mjs` | 0 FAIL, 0 WARN |
| `inspect.mjs` @1440px | 0 FAIL, 3 WARN |

What the inspector measured: one typeface (system-ui), body 16px, the title at
32px, 4 interface fragments, 2 screens, no console errors.

The three warnings are landing-page rules that an operator console does not
answer, and each one is kept with its reason:

- **no-real-pictures** — a console has no subject's world to photograph. Its
  pictures are the interface fragments it is made of, and it has four.
- **no-footage** — the same. A video of a table of accounts would be a
  decoration, and the house rules ban decoration.
- **still-page** — the console moves once, when it arrives: 12 elements
  (the counts, the panels, the rows) rise into place over 240ms. Nothing
  loops, because a console that keeps moving is a console nobody can read.
  The motion floor of 16 is a landing-page figure; the page is two screens
  and one movement.

