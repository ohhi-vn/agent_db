# Tasks

## 1. Config defaults

- [x] 1.1 Change default port in `config/runtime.exs` from `4000` to `6060` and verify the file resolves `6060` when `AGENT_DB_HTTP_PORT` is unset
- [x] 1.2 Update `config/example.exs` fallback port to `6060` and verify no active `4000` default remains outside archive docs
- [x] 1.3 Update `README.md` port table and `ws://localhost` + env examples to `6060` and verify `grep -rn 4000 README.md config/` shows no stale active references

## 2. Verification

- [x] 2.1 Boot with HTTP enabled and no port env and verify TCP connect + `mix agent_db.doctor` succeed on `127.0.0.1:6060`
- [x] 2.2 Boot with `AGENT_DB_HTTP_PORT=4000` and verify listener serves `4000` (override still wins) via TCP connect
- [x] 2.3 Run `mix test` for HTTP/endpoint coverage and verify the suite passes
