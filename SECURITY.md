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
