# Quickstart (5 minutes)

Get from zero to first write, read, search, and health check.

## Prerequisites

- Elixir 1.20+ with `mix` (`elixir --version`)
- `curl` (for daemon checks)
- SQLite and EXLA ship as dependencies — nothing to install separately

## 1. Install

```bash
mix deps.get
```

## 2. Start the daemon

```bash
iex -S mix
```

You should see the supervision tree boot with no errors. Leave it running.

With opt-in auth instead:

```bash
AGENT_DB_HTTP_AUTH=true AGENT_DB_HTTP_AUTH_TOKENS=<token> iex -S mix
```

## 3. First write and read

Inside `iex`:

```elixir
{:ok, _} = Application.ensure_all_started(:agent_db)
:ok = AgentDb.write("viking://resources/my_project/hello.md", "# Hello\n\nFirst doc!")
{:ok, content} = AgentDb.read("viking://resources/my_project/hello.md")
```

`content` is `"# Hello\n\nFirst doc!"`.

## 4. First search

```elixir
{:ok, results} = AgentDb.search("hello", mode: :keyword)
```

One result points at `viking://resources/my_project/hello.md`. Vector and
hybrid modes (`mode: :vector`, `mode: :hybrid`) need the embedding model
downloaded on first use; keyword works immediately with no model.

## 5. Verify

In a second terminal from the checkout root:

```bash
mix agent_db.doctor
tools/install.sh --check
```

`mix agent_db.doctor` reports database, models, queue, and inference
provider. `tools/install.sh --check` verifies prerequisites, required files,
and daemon reachability plus MCP `tools/list`.

If the daemon is not reachable, start it first (`iex -S mix`), then re-run.
If a model file fails to load, delete the truncated cache file and let it
re-download (see `docs/SETUP.md`).

## Next steps

- Full install and configuration: `docs/SETUP.md`
- Daily workflows (documents, memory, sessions, skills, CLI, MCP, WebSocket): `docs/USAGE.md`
- Agent setup (OpenCode, Zed): `docs/agents.md`
