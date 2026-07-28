# 4dgs — Rust

**Planned for v1.x.** This crate compiles; its bodies are unimplemented. Python is the reference
implementation until this lands.

When it does, it becomes two things: the production-grade encoder, and the binding source for the
native tier — its C ABI is how the C++ and Swift packages are intended to be delivered rather than
as parallel hand-written implementations.

The crate is `fourdgs` because Cargo identifiers cannot start with a digit. The format is `4dgs`
everywhere else.
