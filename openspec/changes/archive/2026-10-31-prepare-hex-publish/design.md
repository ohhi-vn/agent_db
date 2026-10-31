# Design

## Context

The package already builds and passes `tools/verify_package.exs`. The gap is the release path: no publish workflow, loose `ex_doc` constraint, missing `homepage_url`, and doc warnings that the delivery-quality gate forbids. See `proposal.md`.

## Goals / Non-Goals

**Goals:**
- Add a publish workflow triggered by version tags, gated on verification.
- Prefer trusted publishing (OIDC) with `HEX_API_KEY` fallback.
- Complete mix metadata (homepage_url, pinned ex_doc).
- Add secret_scan config.
- Make `mix docs` warning-free.
- Document the release process.

**Non-Goals:**
- Actually publishing to Hex (no credentials in this environment).
- Changing package identity (name, version scheme).
- Rewriting documentation content beyond fixing references.

## Decisions

### 1. Publish workflow trigger: version tags `v*`

Tag-based triggers keep ordinary pushes from publishing and align with the version in `mix.exs`. A manual `workflow_dispatch` is also allowed for re-publishing docs.

### 2. Trusted publishing first

Use `hex.pm` OIDC trusted publishing via `mix hex.publish` with `HEX_API_KEY` only as fallback. Document both in the guide.

### 3. Doc warnings

Resolve by (a) removing references to hidden functions or marking them public, and (b) fixing the `AgentDb.Runtime` reference in ARCHITECTURE.md. Prefer making the referenced helpers public (`@doc false` → documented) where they are legitimately referenced, rather than deleting references.

### 4. Secret scan

Add `secret_scan: [ignore: []]` (or with patterns if fixtures exist) to the package config to satisfy the metadata requirement. Audit the tree for secret-like fixtures first.

## Risks / Trade-offs

- [Risk] Docs warning fix may require exposing internal helpers. → Mitigation: use `@doc false` removal only for referenced helpers; otherwise adjust doc references.
- [Risk] Publish workflow untested without real credentials. → Mitigation: dry-run via `mix hex.publish --dry-run` where supported; document manual verification.

## Migration Plan

1. Fix docs warnings.
2. Update mix.exs metadata.
3. Add secret_scan config.
4. Add publish workflow.
5. Add publishing guide and README link.
6. Update delivery-quality spec and verify.

## Open Questions

- Whether to publish docs separately (`mix hex.publish docs`) or only with the package. Resolve during implementation; default to package-includes-docs.