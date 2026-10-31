# Publishing to Hex

This guide describes how to cut and publish a release of AgentDb to
[hex.pm](https://hex.pm). The CI workflow (`.github/workflows/publish.yml`)
automates the publish step once a version tag is pushed.

## Prerequisites

- A Hex account with publish rights to the `agent_db` package.
- For local publishing: run `mix hex.user auth` once.
- For CI: configure trusted publishing (OIDC) or set the `HEX_API_KEY` secret.

## Steps

1. **Bump the version** in `mix.exs` (`@version`) and update `CHANGELOG`/release notes.
2. **Verify locally**:
   ```bash
   mix format --check-formatted
   mix compile --warnings-as-errors
   mix test
   mix lint
   mix hex.build
   mix run --no-start tools/verify_package.exs
   mix docs
   ```
3. **Commit and tag**:
   ```bash
   git commit -am "Release v0.1.1"
   git tag v0.1.1
   git push origin main --tags
   ```
4. **CI publishes** the package and documentation once verification passes.

## Reverting a release

A publication can be reverted within the allowed window:

```bash
mix hex.publish --revert 0.1.1
```

## Versioning

Follow semantic versioning. While the major version is `0`, breaking changes
increment the minor version (e.g. `0.1.0` -> `0.2.0`).