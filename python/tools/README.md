# python/tools

Tooling that is not part of the package and not a conformance runner: measurements, sweeps and
one-off checks that need the reference encoder.

## `rd_benchmark.py` — rate and distortion for SH bit depths

```sh
python3 python/tools/rd_benchmark.py --degree 3            # the degree-3 table below
python3 python/tools/rd_benchmark.py --degree 2            # the degree-2 table below
python3 python/tools/rd_benchmark.py --degree 3 --csv rd.csv
```

The zstd rows need the optional extra (`pip install 'fourdgs[zstd]'`); without it the tool says so
and prints the deflate rows alone. The tool exits non-zero if any file's decoded coefficients fall
outside the bound that file declares, so it is a check as well as a measurement.

### What is being measured

A synthetic scene from the conformance generator's `MixedLifetimes` scenario — 512 gaussians, mixed
lifetimes, four windows — with **spherical harmonics drawn to look like a fit's**: a low-frequency
function of position plus noise, with band energy falling by degree. That last part is why the
corpus fixtures are not used here. They fill coefficients with a counter, which deflate codes almost
perfectly and which coarser quantization only disturbs, so a rate table built on them would show
quantizing making files _larger_ — true of the fixture and false of everything else.

Sizes are the bytes of a real file this package wrote. `SH bytes` is the sum of the band records the
chunk index frames, so it is what a reader that wanted every band would transfer. Error is measured
after decoding, per gaussian, against the coefficients that went in — the gaussians are matched by
their source index rather than by row, because an encoder reorders them freely. PSNR is over the
`[-4, +4]` interval spec §6.5 pins, so 0 dB would be an error the size of the whole range; `max err`
is in code units, and the `in bounds` column is the per-band declared bound checked on every
coefficient of every gaussian.

Both ratio columns are against **this format's own** deflate baseline at eight bits, which is what a
producer would otherwise have shipped.

### Degree 3

| scene          | deg | SH bits       | codec   | lvl | file bytes | SH bytes | file vs base | SH vs base | SH PSNR dB | max err | in bounds |
| -------------- | --- | ------------- | ------- | --- | ---------- | -------- | ------------ | ---------- | ---------- | ------- | --------- |
| MixedLifetimes | 3   | none (8 bits) | deflate | 6   | 29,929     | 14,740   | 1.000        | 1.000      | lossless   | 0       | yes       |
| MixedLifetimes | 3   | uniform 8     | deflate | 6   | 29,984     | 14,740   | 1.002        | 1.000      | lossless   | 0       | yes       |
| MixedLifetimes | 3   | uniform 7     | deflate | 6   | 27,415     | 12,171   | 0.916        | 0.826      | 51.2       | 1       | yes       |
| MixedLifetimes | 3   | uniform 6     | deflate | 6   | 24,740     | 9,496    | 0.827        | 0.644      | 46.3       | 2       | yes       |
| MixedLifetimes | 3   | uniform 5     | deflate | 6   | 21,732     | 6,488    | 0.726        | 0.440      | 41.1       | 4       | yes       |
| MixedLifetimes | 3   | uniform 4     | deflate | 6   | 20,159     | 4,915    | 0.674        | 0.333      | 34.1       | 8       | yes       |
| MixedLifetimes | 3   | uniform 3     | deflate | 6   | 19,540     | 4,292    | 0.653        | 0.291      | 26.6       | 16      | yes       |
| MixedLifetimes | 3   | balanced      | deflate | 6   | 24,229     | 8,985    | 0.810        | 0.610      | 44.0       | 4       | yes       |
| MixedLifetimes | 3   | aggressive    | deflate | 6   | 21,267     | 6,021    | 0.711        | 0.408      | 28.5       | 16      | yes       |
| MixedLifetimes | 3   | none (8 bits) | zstd    | 3   | 30,173     | 14,662   | 1.008        | 0.995      | lossless   | 0       | yes       |
| MixedLifetimes | 3   | uniform 8     | zstd    | 3   | 30,228     | 14,662   | 1.010        | 0.995      | lossless   | 0       | yes       |
| MixedLifetimes | 3   | uniform 7     | zstd    | 3   | 27,619     | 12,053   | 0.923        | 0.818      | 51.2       | 1       | yes       |
| MixedLifetimes | 3   | uniform 6     | zstd    | 3   | 25,285     | 9,719    | 0.845        | 0.659      | 46.3       | 2       | yes       |
| MixedLifetimes | 3   | uniform 5     | zstd    | 3   | 22,549     | 6,983    | 0.753        | 0.474      | 41.1       | 4       | yes       |
| MixedLifetimes | 3   | uniform 4     | zstd    | 3   | 21,182     | 5,616    | 0.708        | 0.381      | 34.1       | 8       | yes       |
| MixedLifetimes | 3   | uniform 3     | zstd    | 3   | 20,656     | 5,086    | 0.690        | 0.345      | 26.6       | 16      | yes       |
| MixedLifetimes | 3   | balanced      | zstd    | 3   | 24,861     | 9,295    | 0.831        | 0.631      | 44.0       | 4       | yes       |
| MixedLifetimes | 3   | aggressive    | zstd    | 3   | 22,242     | 6,674    | 0.743        | 0.453      | 28.5       | 16      | yes       |
| MixedLifetimes | 3   | none (8 bits) | zstd    | 19  | 29,406     | 14,163   | 0.983        | 0.961      | lossless   | 0       | yes       |
| MixedLifetimes | 3   | uniform 8     | zstd    | 19  | 29,461     | 14,163   | 0.984        | 0.961      | lossless   | 0       | yes       |
| MixedLifetimes | 3   | uniform 7     | zstd    | 19  | 26,275     | 10,977   | 0.878        | 0.745      | 51.2       | 1       | yes       |
| MixedLifetimes | 3   | uniform 6     | zstd    | 19  | 23,483     | 8,185    | 0.785        | 0.555      | 46.3       | 2       | yes       |
| MixedLifetimes | 3   | uniform 5     | zstd    | 19  | 20,677     | 5,379    | 0.691        | 0.365      | 41.1       | 4       | yes       |
| MixedLifetimes | 3   | uniform 4     | zstd    | 19  | 19,068     | 3,770    | 0.637        | 0.256      | 34.1       | 8       | yes       |
| MixedLifetimes | 3   | uniform 3     | zstd    | 19  | 18,563     | 3,261    | 0.620        | 0.221      | 26.6       | 16      | yes       |
| MixedLifetimes | 3   | balanced      | zstd    | 19  | 23,238     | 7,940    | 0.776        | 0.539      | 44.0       | 4       | yes       |
| MixedLifetimes | 3   | aggressive    | zstd    | 19  | 20,175     | 4,875    | 0.674        | 0.331      | 28.5       | 16      | yes       |

### Degree 2

| scene          | deg | SH bits       | codec   | lvl | file bytes | SH bytes | file vs base | SH vs base | SH PSNR dB | max err | in bounds |
| -------------- | --- | ------------- | ------- | --- | ---------- | -------- | ------------ | ---------- | ---------- | ------- | --------- |
| MixedLifetimes | 2   | none (8 bits) | deflate | 6   | 24,004     | 8,883    | 1.000        | 1.000      | lossless   | 0       | yes       |
| MixedLifetimes | 2   | uniform 8     | deflate | 6   | 24,041     | 8,883    | 1.002        | 1.000      | lossless   | 0       | yes       |
| MixedLifetimes | 2   | uniform 7     | deflate | 6   | 22,715     | 7,557    | 0.946        | 0.851      | 51.2       | 1       | yes       |
| MixedLifetimes | 2   | uniform 6     | deflate | 6   | 21,198     | 6,040    | 0.883        | 0.680      | 46.4       | 2       | yes       |
| MixedLifetimes | 2   | uniform 5     | deflate | 6   | 19,791     | 4,633    | 0.824        | 0.522      | 40.7       | 4       | yes       |
| MixedLifetimes | 2   | uniform 4     | deflate | 6   | 18,212     | 3,054    | 0.759        | 0.344      | 35.3       | 8       | yes       |
| MixedLifetimes | 2   | uniform 3     | deflate | 6   | 17,592     | 2,431    | 0.733        | 0.274      | 27.8       | 16      | yes       |
| MixedLifetimes | 2   | balanced      | deflate | 6   | 22,288     | 7,130    | 0.929        | 0.803      | 48.5       | 2       | yes       |
| MixedLifetimes | 2   | aggressive    | deflate | 6   | 19,318     | 4,160    | 0.805        | 0.468      | 37.5       | 8       | yes       |
| MixedLifetimes | 2   | none (8 bits) | zstd    | 3   | 24,414     | 8,971    | 1.017        | 1.010      | lossless   | 0       | yes       |
| MixedLifetimes | 2   | uniform 8     | zstd    | 3   | 24,451     | 8,971    | 1.019        | 1.010      | lossless   | 0       | yes       |
| MixedLifetimes | 2   | uniform 7     | zstd    | 3   | 22,927     | 7,447    | 0.955        | 0.838      | 51.2       | 1       | yes       |
| MixedLifetimes | 2   | uniform 6     | zstd    | 3   | 21,495     | 6,015    | 0.895        | 0.677      | 46.4       | 2       | yes       |
| MixedLifetimes | 2   | uniform 5     | zstd    | 3   | 20,262     | 4,782    | 0.844        | 0.538      | 40.7       | 4       | yes       |
| MixedLifetimes | 2   | uniform 4     | zstd    | 3   | 18,898     | 3,418    | 0.787        | 0.385      | 35.3       | 8       | yes       |
| MixedLifetimes | 2   | uniform 3     | zstd    | 3   | 18,375     | 2,892    | 0.765        | 0.326      | 27.8       | 16      | yes       |
| MixedLifetimes | 2   | balanced      | zstd    | 3   | 22,574     | 7,094    | 0.940        | 0.799      | 48.5       | 2       | yes       |
| MixedLifetimes | 2   | aggressive    | zstd    | 3   | 19,960     | 4,480    | 0.832        | 0.504      | 37.5       | 8       | yes       |
| MixedLifetimes | 2   | none (8 bits) | zstd    | 19  | 24,059     | 8,884    | 1.002        | 1.000      | lossless   | 0       | yes       |
| MixedLifetimes | 2   | uniform 8     | zstd    | 19  | 24,096     | 8,884    | 1.004        | 1.000      | lossless   | 0       | yes       |
| MixedLifetimes | 2   | uniform 7     | zstd    | 19  | 22,397     | 7,185    | 0.933        | 0.809      | 51.2       | 1       | yes       |
| MixedLifetimes | 2   | uniform 6     | zstd    | 19  | 20,611     | 5,399    | 0.859        | 0.608      | 46.4       | 2       | yes       |
| MixedLifetimes | 2   | uniform 5     | zstd    | 19  | 19,298     | 4,086    | 0.804        | 0.460      | 40.7       | 4       | yes       |
| MixedLifetimes | 2   | uniform 4     | zstd    | 19  | 17,689     | 2,477    | 0.737        | 0.279      | 35.3       | 8       | yes       |
| MixedLifetimes | 2   | uniform 3     | zstd    | 19  | 17,185     | 1,970    | 0.716        | 0.222      | 27.8       | 16      | yes       |
| MixedLifetimes | 2   | balanced      | zstd    | 19  | 21,859     | 6,647    | 0.911        | 0.748      | 48.5       | 2       | yes       |
| MixedLifetimes | 2   | aggressive    | zstd    | 19  | 18,796     | 3,584    | 0.783        | 0.403      | 37.5       | 8       | yes       |

### Reading it

**The band streams are where the bytes are, and bit depth is what moves them.** At degree 3 the
coefficients are half the file; taking every band to five bits removes 56 % of them for 41 dB, and
the `balanced` ladder — band 1 exact, then 6 and 5 — removes 39 % for 44 dB while leaving the band a
viewer notices most untouched.

**The codec is not where the bytes are.** Across every row, zstd at its default level is within a
couple of percent of deflate and sometimes worse; at level 19 it wins by 4–8 % on the coefficient
streams. That is the same conclusion the registry already records for the other attributes, and it
is why `deflate` is the format's default: a decoder that exists everywhere is worth more than this.

**Below four bits the curve flattens.** Three bits buys about 7 % more of the SH stream than four
and costs 7 dB, because the stream is still one byte per coefficient and deflate is close to its
floor on eight distinct symbols. That is the honest limit of a scheme that changes no decoder: the
saving is entropy, not packing. Anything past it needs sub-byte packing, which is a wire change, a
decoder change in five SDKs, and a different conversation.

**Declaring eight bits costs 55 bytes** — the appended field and its three bound entries — and is
worth it only when a consumer benefits from the file saying so explicitly.
