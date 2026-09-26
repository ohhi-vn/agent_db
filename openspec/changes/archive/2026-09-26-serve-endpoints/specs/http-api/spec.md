# Spec Delta

## ADDED Requirements

### Requirement: HTTP listener lifecycle and binding

When HTTP is enabled the store SHALL open a listener on the configured port and serve requests on it. Enabling HTTP SHALL be observable as a reachable listening socket, not merely as a started endpoint process; a started endpoint that accepts no connection does not satisfy this requirement. When HTTP is disabled the store SHALL leave no listener open.

The listener SHALL bind the loopback interface by default, and the bind interface SHALL be configurable so that a deployment on a private network can select a specific address. The port SHALL be taken from a single configuration source, so that one configured value determines the port served and no second, competing port setting can silently disagree with it.

#### Scenario: Enabled HTTP serves requests
- **WHEN** the store starts with HTTP enabled and a port configured
- **THEN** a TCP listener accepts a request on that port
- **AND** the request is answered by the store rather than refused

#### Scenario: Disabled HTTP opens no listener
- **WHEN** the store starts with HTTP disabled
- **THEN** no TCP listener is open on the configured port
- **AND** a request to that port is refused

#### Scenario: The listener binds loopback by default
- **WHEN** the store starts with HTTP enabled and no bind interface configured
- **THEN** the listener is reachable on the loopback interface
- **AND** the listener is not bound to a non-loopback interface

#### Scenario: The bind interface is configurable
- **WHEN** the store starts with HTTP enabled and a bind interface configured
- **THEN** the listener is reachable on the configured interface
- **AND** the default loopback binding does not apply

#### Scenario: One configured port determines what is served
- **WHEN** the store starts with HTTP enabled and a port configured
- **THEN** the listener is opened on exactly that port
- **AND** no other port value overrides it

#### Scenario: Serving is observable rather than assumed
- **WHEN** the store reports that HTTP is enabled
- **THEN** a connection to the configured port succeeds
- **AND** reporting HTTP as enabled while refusing connections is a detectable failure
