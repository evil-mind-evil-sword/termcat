# termcat Departures Index

Status: Active
Last updated: 2026-01-28
Owner: termcat
Scope: termcat departures from references
Related issues: workshop-055pg40, workshop-7nmgecy, workshop-cglbt7q
References: None

This document is the canonical index for termcat departures. The legacy
pointer at `docs/termcat/departures/index.md` redirects here.

Departures document intentional deviations from reference implementations and
papers that inform termcat's design. The departure content itself lives in jwz,
not in markdown files.

## Storage (jwz)

```bash
# List all termcat departures
jwz search "departures:termcat"

# Read a specific departure
jwz read departures:termcat:notcurses

# Post a new departure
jwz post departures:termcat:<reference-name> -m '<content>'
```

## Format

When posting a departure to jwz, use this structure:

```markdown
# Departures from [Reference Name]

**Reference**: [Link or citation] **Version/Date**: [Version of reference
reviewed]

## Overview

Brief description of what this reference covers and why we reference it.

## Departures

### [Component/Feature Name]

**Reference behavior**: What the reference does **Our behavior**: What we do
instead **Rationale**: Why we departed **Issue/Discussion**: Link to tissue
issue or jwz thread if applicable **Revisit**: [Yes/No] - Should this be
reconsidered later?
```

## Maintenance

The backward pass prompt (`prompts/termcat-backward.md`) includes a task to
review and update departures via jwz.

## Related issues

- workshop-055pg40 - add metadata + canonical location for departures index
- workshop-7nmgecy - docs validation tooling
- workshop-cglbt7q - termcat docs reconciliation
