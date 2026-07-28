# Governance

This is an early-stage project and its governance is deliberately minimal. This document will grow
as the project does; it is a stub, not a constitution.

## Decisions

- **Specification changes** require an issue, a pull request, and two approvals from maintainers,
  plus a conformance scenario demonstrating the change.
- **SDK changes** follow ordinary review: one approval, conformance green.
- **Registry additions** (a new codec, profile, or well-known key) follow the SDK path unless they
  change the meaning of an existing value, in which case they are spec changes.
- **Changes to the project's charter** — the scope sentence in the README and CONTRIBUTING — require
  the same process as specification changes.

## Maintainers

Maintained by Avala AI. A formal maintainer list and a path to maintainership will be added when
there are contributors outside the founding organization.

## Licensing intent

The specification is intended to be implementable **royalty-free**, by anyone, without a licence
negotiation. Contributors are expected to make their contributions available on the same basis,
without asserting patents against implementations of the specification.

This is a statement of intent, not yet a formal policy: the precise language will follow legal
review. It is written down now because anyone deciding whether to implement this deserves to know
the direction before the paperwork exists.

## Compatibility commitment

Within a major version, files written by any conforming encoder remain readable by any conforming
decoder of the same or later minor version. Breaking that is a major version bump and a new magic
byte, not a patch.
