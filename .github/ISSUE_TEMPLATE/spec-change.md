---
name: Specification change
about: Propose a change to the wire format or its normative rules
labels: spec
---

## Motivation

What cannot be expressed today, or what is ambiguous.

## Wire impact

Which records change, and how. New opcode, appended field, or a change to an existing
field — note that the last of these is not permitted for frozen records.

## Backward compatibility

What an existing decoder does when it meets a file written under this change, and what a
new decoder does with an existing file.

## Affected SDKs

Which implementations need work, and whether a partial rollout is acceptable in the
meantime.

## Conformance

The scenario or flag that would fail without this change.
