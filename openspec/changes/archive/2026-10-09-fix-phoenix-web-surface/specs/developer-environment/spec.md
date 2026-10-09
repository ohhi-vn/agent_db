# Spec Delta

## Purpose

Lets a developer run the Phoenix web surface locally with the configuration,
reloading, and diagnostics the development workflow needs, distinct from what the
test and production environments require.

## ADDED Requirements

### Requirement: Each environment is configured explicitly

The application SHALL resolve environment-specific configuration from the
environment it was started in, so behavior that differs between development,
test, and production is declared per environment rather than left to a shared
default.

#### Scenario: The running environment's configuration is applied

- **WHEN** the application boots in a given environment
- **THEN** the configuration for that environment is applied

#### Scenario: The test environment opens no listener

- **WHEN** the application starts in the test environment
- **THEN** the web endpoint does not bind a network listener

#### Scenario: Production refuses to start without its secrets

- **WHEN** the application starts in production without the secret material production requires
- **THEN** startup fails naming the missing secret rather than serving with a development value

### Requirement: Development reloads code and rebuilds assets

In development, the running server SHALL apply changed source and rebuild the
console's generated stylesheet and scripts when their sources change, so a
change is visible without restarting the server.

#### Scenario: Changed source is reloaded

- **WHEN** a developer changes a project source file while the development server is running
- **THEN** the server serves the changed code without a restart

#### Scenario: The browser reloads on a change

- **WHEN** a developer changes a template or an asset source in development
- **THEN** the open browser page reloads to show the change

#### Scenario: Console markup changes reach the stylesheet

- **WHEN** console markup that introduces a new style class changes in development
- **THEN** the generated stylesheet is rebuilt so the class is present when the page is served

### Requirement: A development dashboard is reachable and renders

In development, the server SHALL expose a dashboard for inspecting the running
node, and its pages SHALL render without error.

#### Scenario: The dashboard renders

- **WHEN** a developer opens the development dashboard
- **THEN** the dashboard and its pages render without raising an error

#### Scenario: Metrics are real or absent

- **WHEN** the application provides no telemetry metrics source
- **THEN** the dashboard shows no metrics view rather than a metrics view that fails
