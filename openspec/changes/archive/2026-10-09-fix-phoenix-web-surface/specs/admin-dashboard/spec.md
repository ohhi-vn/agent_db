# Spec Delta

## MODIFIED Requirements

### Requirement: Console renders with its current stylesheet
The console's pages SHALL be served with a stylesheet generated from the console's current markup that includes a base reset, so the classes the pages use are present and browser-default element styling does not leak through. The stylesheet build SHALL be reproducible by a documented project command rather than requiring an undocumented manual step.

#### Scenario: Console pages render styled
- **WHEN** an operator loads any console page
- **THEN** the served stylesheet contains the layout classes the page uses
- **AND** the page renders with the console's intended layout rather than unstyled content

#### Scenario: The linked stylesheet and script are served
- **WHEN** a browser requests the stylesheet or script a console page links
- **THEN** the server responds with the asset rather than a 404

#### Scenario: Browser defaults do not leak into console pages
- **WHEN** an operator loads any console page
- **THEN** body spacing, list markers, and form controls follow the console's stylesheet rather than the browser's defaults

#### Scenario: The editor and error pages share the console's stylesheet
- **WHEN** an operator opens the document editor or an error page
- **THEN** the page is served the console's stylesheet and renders with its intended layout

#### Scenario: The stylesheet build is reproducible
- **WHEN** a developer runs the documented asset build command after changing console markup
- **THEN** the generated stylesheet includes the classes the new markup uses

## ADDED Requirements

### Requirement: Operator feedback is rendered on console pages
A console page SHALL render the feedback it sets for an operator, so the outcome of an action is visible without leaving the page. A page SHALL NOT discard the feedback it set.

#### Scenario: A successful action reports its outcome
- **WHEN** an operator performs an action that succeeds, such as publishing a document
- **THEN** the console shows a success message for that action
- **AND** the message is visible on the page the operator is left on

#### Scenario: A failed action reports a classified reason
- **WHEN** an operator performs an action that fails, such as publishing a document
- **THEN** the console shows a failure message derived from the shared error taxonomy
- **AND** the message contains no raw `inspect/1` of the failure term
