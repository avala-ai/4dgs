# 4dgs — C++

**Planned.** Not started.

When the Rust implementation lands, the intended path is to generate this surface from
Rust's C ABI — a header plus a thin shim — rather than hand-writing and then maintaining a
parallel implementation. The same strategy covers the Swift package.

Scope, when it exists: decoding a `.4dgs` file to gaussian state at a time `t`, and
writing one. Rendering is out of scope for this repository.
