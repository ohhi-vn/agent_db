# Spec Delta

## Purpose

Lets long-running agents react when watched context changes instead of polling, by subscribing to `viking://` subtrees over the store's existing PubSub.

## ADDED Requirements

### Requirement: Subscribe to a context subtree
The system SHALL provide `subscribe/1` and `unsubscribe/1` for any syntactically valid `viking://` URI, including a URI that holds nothing yet. Scope membership SHALL be exact-URI-or-descendant, so a subscription to `viking://resources/project` never fires for a sibling `viking://resources/project-old`. An invalid URI SHALL return `{:error, :invalid_uri}` and subscribe to nothing. Unsubscribing from a subscription that does not exist SHALL succeed without side effects.

#### Scenario: Subscribe to an existing subtree
- **WHEN** a caller subscribes to `viking://resources/project`
- **THEN** the subscription succeeds and later changes beneath that URI are delivered to the caller

#### Scenario: Subscribe to a missing URI watches for creation
- **WHEN** a caller subscribes to `viking://resources/future` which holds nothing
- **AND** a document is later written at `viking://resources/future/readme.md`
- **THEN** the subscriber receives a change event for that write

#### Scenario: Invalid URI subscribes to nothing
- **WHEN** a caller subscribes to `not-a-uri`
- **THEN** the system returns `{:error, :invalid_uri}` and delivers no later events

#### Scenario: Scope boundary is exact
- **WHEN** a caller is subscribed to `viking://resources/project`
- **AND** a write lands at `viking://resources/project-old/readme.md`
- **THEN** no event is delivered to that subscriber

### Requirement: Change notifications for writes, removals, and commits
Every committed write, subtree removal, skill replacement, memory revision, and session commit SHALL publish exactly one event per affected URI root to current subscribers of any ancestor-or-self scope. Each event SHALL carry the changed URI, a change kind of `written | removed | replaced | committed`, and a monotonic version that increases per change at that URI. Events SHALL NOT carry document content, prompts, or credentials. A subscriber crash or slow consumer SHALL NOT block or fail the write that produced the event.

#### Scenario: Write notifies subscribers
- **WHEN** a subscriber watches `viking://resources/project` and a document is written at `viking://resources/project/docs/api.md`
- **THEN** the subscriber receives `{:context_changed, uri, version}` with kind `written` within a bounded delay
- **AND** the write itself returns `:ok` regardless of subscriber state

#### Scenario: Removal notifies and stops further events for removed URIs
- **WHEN** a subscriber watches `viking://resources/sub` and that subtree is removed
- **THEN** the subscriber receives a `removed` event for the removal root
- **AND** no later embedding or summarization result for a removed URI produces an event

#### Scenario: Session commit notifies
- **WHEN** a subscriber watches `viking://user/u1/memories` and a session is committed beneath it
- **THEN** the subscriber receives a `committed` event for the destination URI

#### Scenario: Events carry no content
- **WHEN** any change event is delivered for URIs holding different documents or users
- **THEN** the event contains only URI, kind, and version and never document content or user identifiers beyond the URI itself

### Requirement: Subscription delivery is local-first and non-durable
Subscriptions SHALL be delivered via the application's `Phoenix.PubSub` instance, SHALL be scoped to the subscribing process lifetime, and SHALL NOT survive process exit or application restart. Re-subscribing after restart SHALL be required to receive further events. Pending events SHALL NOT be persisted in SQLite or the durable job queue.

#### Scenario: Subscriber exit ends delivery
- **WHEN** a subscribed process exits
- **AND** a later write lands in its former scope
- **THEN** no event is delivered to the exited process and the write still succeeds

#### Scenario: Restart clears subscriptions
- **WHEN** the application restarts
- **THEN** no pre-restart subscription receives post-restart events until it subscribes again
