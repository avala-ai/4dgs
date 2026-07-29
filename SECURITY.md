# Security policy

## Reporting a vulnerability

Report privately via GitHub's "Report a vulnerability" flow on this repository's Security tab, or by
email to security@avala.ai. Please do not open a public issue for a vulnerability.

Expect an acknowledgement within three working days and an assessment within ten.

## Threat model

**Decoders in this repository parse untrusted bytes.** A `.4dgs` file may arrive from anywhere, and
a decoder must treat every field in it as hostile until validated. That makes the following in scope
for a security report:

- Memory-safety failures, out-of-bounds reads, or crashes from a malformed file
- Unbounded allocation driven by a header field (a decompression bomb, an implausible count, a
  length that exceeds the resource)
- Infinite loops or pathological runtime from crafted input
- Path traversal or arbitrary writes from names embedded in a file

Out of scope: denial of service from a legitimately enormous but well-formed file, and issues in
applications that consume these libraries.

## Expectations of implementations

Every decoder here validates before it allocates: lengths are checked against the resource size,
decompressed sizes against the declared size, and counts against a documented ceiling. A file that
fails validation is refused with a message that names the offending field — never partially decoded
into a caller's buffer.

## How that is checked

The section above is a claim, so it is fuzzed rather than asserted. Every implementation holds one
invariant:

> For any input at all, a decoder either succeeds or raises the format's own error type.

Never an uncaught error from a codec library, a transport or a maths function; never unbounded
allocation; never a hang. A single input that takes longer than the ceiling is a failure, not a slow
test.

`tests/fuzz/` has the operator list, the shared seed scheme — the same seed names the same bytes in
Python and TypeScript, so a crash found by one implementation is handed to the other as two integers
— and `regressions.json`, which records every input that has ever found something and replays all of
them on every run. Rust fuzzes separately in `rust/fourdgs/tests/fuzz.rs`, against seeds it encodes
itself and across the C ABI as well as the two read paths. All three run in CI.

The first pass found ten crash classes, including one that was not an exception at all: a
constant-mode attribute stream declaring 2^30 elements, which expanded a one-byte payload into
gigabytes. The cap it evaded bounded what arrives rather than what it becomes — the distinction is
now checked in both decoders, and the input that found it is case `constant-stream-expansion-bomb`.
