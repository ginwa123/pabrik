# Pabrik

[![CI](https://github.com/ginwa123/pabrik/actions/workflows/ci.yml/badge.svg)](https://github.com/ginwa123/pabrik/actions/workflows/ci.yml)

**Pabrik** is an AI agent workspace. You chat with a model that can actually do
things — read and write files, run shell commands, search your code, move kanban
cards, edit a design canvas — and everything it does is saved in a local SQLite
database on your own machine.

One Zig backend, five ways to use it: a web app, a desktop app, two terminal
clients, and an Android phone.

## Status

Chat, kanban, memory and the web app are the settled parts. These still work,
but expect them to break and change:

> **Preview (alpha)** — the desktop app, the terminal UI (`pabrik-tui`), the
> Android app, and Design mode (the Figma-like canvas).

## What you get

- 💬 **Chat** — a tool-calling agent loop, conversation compaction, and
  full-text search over your history
- 📋 **Kanban** — columns, tasks, drag-to-reorder, pins, and routines
- 🎨 **Design canvas** _(preview)_ — pages of elements that the agent can read and edit
- 🧠 **Memory** — append-only agent memories, skills, and sub-agents
- 🔌 **Integrations** — MCP servers over stdio or HTTP, plus any
  Anthropic- or OpenAI-compatible model
- 🖥️ **Clients** — web app and `pabrikcli` are stable; the desktop app,
  `pabrik-tui` and the native Kotlin app for Android are still preview

## Installation

**Quick install** — prebuilt binaries from the latest green `main` build
(rolling `ci-latest` release). Linux x86_64 and Apple Silicon macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/ginwa123/pabrik/main/install.sh | bash
# or: wget -qO- https://raw.githubusercontent.com/ginwa123/pabrik/main/install.sh | bash
```

Windows (PowerShell, no admin):

```powershell
irm https://raw.githubusercontent.com/ginwa123/pabrik/main/install.ps1 | iex
```

What it does: installs `pabrik` + `pabrik-desktop` to `~/.local/bin`
(Linux/macOS) or `%LOCALAPPDATA%\pabrik\bin` + a Start Menu shortcut
(Windows), and adds the bindir to your PATH automatically
(`~/.bashrc` / `~/.zshrc` on Linux/macOS, user PATH on Windows —
new terminals pick it up; `PABRIK_NO_MODIFY_PATH=1` opts out). Options: `bash install.sh --system` for `/usr/local/bin`,
`--no-desktop` for the server only, `--version TAG` for a pinned release,
`--uninstall` to remove. macOS GUI users can also grab `Pabrik-*.zip`
(Pabrik.app) from the
[ci-latest release](https://github.com/ginwa123/pabrik/releases/tag/ci-latest).

**Build from source** — you need **Zig 0.16.0**. On Linux you also need the usual dev libraries:

```bash
sudo apt-get install -y build-essential libssl-dev libsqlite3-dev pkg-config
```

Then clone and build:

```bash
git clone https://github.com/ginwa123/pabrik.git
cd pabrik

zig build            # builds the server, the desktop app and both terminal clients
```

Node + pnpm are only needed if you want to work on the web app itself.

## Usage

**Desktop app** _(preview)_ — opens a window, and starts the server for you if
it is not already running:

```bash
./zig-out/bin/pabrik-desktop
```

**Web app in a browser** — the server serves the UI itself once you point it at a
built web app, so there is nothing else to start. `zig build run` does both halves
for you: it rebuilds `src/apps/desktop/dist` from the current `.vue` sources and
starts the server with `--static-dir` pointed at it.

```bash
zig build run                  # rebuild webapp → serve UI + API on :8081
zig build run -- --port 8090   # any flags the binary takes
```

Without a webapp build on disk, the direct binary invocation takes the dir
explicitly:

```bash
cd src/apps/desktop
pnpm install
pnpm run build          # → dist/
cd -
```

Then start the server with `--static-dir`:

```bash
./zig-out/bin/pabrik --port 8081 --static-dir src/apps/desktop/dist
```

Open <http://127.0.0.1:8081/app>.

**API only** — `--no-static-dir` serves the REST + SSE API on
<http://127.0.0.1:8081> with no UI (`zig build run -- --no-static-dir`), or drop
`--static-dir` entirely for the raw binary. That is what the terminal clients and
any script talk to. Build-wise, `-Dno-webapp-rebuild` skips the webapp build
entirely — use it on a box without node/pnpm (what Windows CI does).

> On Linux the plain `zig build` output is named `pabrikcore-linux-x86_64`. Run
> `zig build install:linux:system` first if you want the binary called `pabrik`.

The server starts on an empty config, so the UI loads but chat cannot answer yet.
Add a model under **Settings → Profiles** — a `base_url`, a `model` and an
`api_key` for any Anthropic- or OpenAI-compatible provider.

## Development

```bash
zig build test                                    # backend unit tests
zig build test:cli                                # terminal client
zig build test:tui                                # terminal UI
zig build run                                     # server + webapp (rebuilds dist/ first)
cd src/apps/desktop && pnpm install && pnpm run dev   # web app, with hot reload
zig build functional-test-all                     # API + browser tests (pytest)
```

## Documentation

- [AGENTS.md](AGENTS.md) / [CLAUDE.md](CLAUDE.md) — conventions for coding agents