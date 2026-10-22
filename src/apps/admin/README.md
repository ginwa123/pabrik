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
```

## Opening it

`http://localhost:<port>/admin` — the page, its stylesheet and its script.

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

