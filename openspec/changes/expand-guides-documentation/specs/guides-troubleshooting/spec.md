# Spec Delta

## Purpose

Provides a symptom-driven diagnostic guide with resolutions and diagnostic commands for common operational issues including model loading failures, database errors, queue backpressure, inference latency, authentication issues, and WSL2-specific problems so operators can resolve incidents without escalating to developers.

## ADDED Requirements

### Requirement: Troubleshooting guide organizes issues by observable symptom
The system SHALL provide `guides/TROUBLESHOOTING.md` with a top-level index of symptoms (e.g., "Daemon won't start", "Model fails to load", "Search returns model_loading", "Queue grows without draining", "High inference latency", "Authentication rejected", "WSL2 daemon unreachable", "Admin console shows errors", "Export/import fails") each linking to a diagnostic section with cause, verification commands, and resolution steps.

#### Scenario: Operator follows symptom to resolution
- **WHEN** an operator sees "Search returns {:error, :model_loading}"
- **THEN** they find the "Model fails to load" section, run the listed diagnostic commands (`AgentDb.model_status/0`, check logs for download errors), and apply the resolution (delete truncated cache file, verify backend config, re-download)

#### Scenario: Operator diagnoses queue backpressure
- **WHEN** an operator sees pending jobs accumulating
- **THEN** they find the "Queue grows without draining" section, run `AgentDb.queue_stats/0` and `mix agent_db.doctor --json`, read the failed job reasons from the console, and apply the resolution (increase `job_workers`, check model loading, restart workers)

### Requirement: Troubleshooting guide provides diagnostic commands with expected output
Each diagnostic section SHALL list the exact commands to run (Elixir function calls, CLI tasks with `--json`, `mix agent_db.doctor`, `tools/install.sh --check`) and show example healthy vs unhealthy output so operators can compare.

#### Scenario: Operator verifies model status
- **WHEN** an operator runs `AgentDb.model_status()` as shown in the guide
- **THEN** they can interpret the `%{embedding: %{state: :ready, ...}, llm: %{state: :loading, ...}}` output and know which state requires action

#### Scenario: Operator checks database health
- **WHEN** an operator runs `mix agent_db.doctor --json`
- **THEN** they see the JSON structure with `checks: %{db: true, models: true, queue: true, pubsub: true, inference_provider: true}` and know which `false` value maps to which symptom section

### Requirement: Troubleshooting guide documents log interpretation for common error patterns
The system SHALL document how to read structured logs for the most common failure modes: model download failures (HTTP errors, checksum mismatches), SQLite busy/locked errors, inference OOM or backend mismatches, job retry exhaustion, and authentication token parsing failures. Each pattern SHALL show the log fields (`component`, `operation`, `outcome`, `code`, `trace_id`) and the corresponding guide section.

#### Scenario: Operator identifies a model download failure from logs
- **WHEN** an operator sees a log entry with `component: "ModelManager"`, `code: "download_failed"`
- **THEN** the guide maps this to the "Model fails to load" section and the resolution steps

### Requirement: Troubleshooting guide covers WSL2-specific issues
The system SHALL document WSL2-specific failure modes: Windows firewall blocking port 6060, WSL2 localhost forwarding not working, `tools/install.ps1` refusing native execution, and the correct workflow (run daemon and installer inside WSL2, point Windows editors at `http://localhost:6060/mcp`).

#### Scenario: Windows user cannot connect from OpenCode/Zed
- **WHEN** a Windows user follows the WSL2 section
- **THEN** they verify the daemon runs in WSL2 (`wsl bash -c "curl localhost:6060/api/v1/health"`), configure the editor to `http://localhost:6060/mcp`, and understand why `tools/install.ps1` refuses to run natively

### Requirement: Troubleshooting guide links to monitoring guide for ongoing observability
The system SHALL cross-reference `guides/MONITORING.md` for setting up proactive alerting so operators can catch issues before they become symptoms, and to `guides/ARCHITECTURE.md` for understanding component interactions when debugging novel failures.

#### Scenario: Operator sets up alerts after resolving an incident
- **WHEN** an operator resolves a queue backpressure incident using the troubleshooting guide
- **THEN** the guide directs them to the monitoring guide's alerting recommendations to prevent recurrence