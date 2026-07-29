# 4dgs — Python

Reference implementation of the [4dgs container format](https://github.com/avala-ai/4dgs).

```
pip install fourdgs
```

Reads and writes `.4dgs` files, converts sequences of gaussian splat PLY frames, and inspects and
validates existing files. See the [specification](../website/docs/spec/index.md) for the format and
the [feature matrix](../website/docs/reference/index.md) for what is implemented.

Audio is a collection of independently timed sources with fixed or keyframed scene-space poses. The
SDK reconstructs source state at time `t`; listener pose, HRTF/panning, attenuation and mixing
belong to the player. Indexed callers can read descriptors and source state without fetching payload
bytes, then request bounded encoded ranges per source.
