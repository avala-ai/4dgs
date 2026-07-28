# 4dgs — Swift

**Planned.** Not started.

Target is visionOS and iOS. Delivery is intended via bindings over the Rust core's C ABI
when it lands, the same strategy as the C++ package, rather than a hand-written parallel
implementation.

Scope, when it exists: decoding a `.4dgs` file to gaussian state at a time `t`. RealityKit
and Metal rendering are out of scope for this repository — the SDK ends at decoded state.
