---
id: compression
title: Compression — measured
---

# Compression — measured

Spherical harmonics dominate a coloured scene's bytes, and the format lets a writer pick a bit depth
per band. This page is what that buys, in numbers, measured rather than asserted: every row is the
size of a file this package wrote and the error between the coefficients that went in and the ones
that came back out of it. Reproduce the whole table with

```
python3 python/tools/rd_benchmark.py            # to stdout
python3 python/tools/rd_benchmark.py --csv out.csv
```

## What is being measured, and what is not

The scene is synthetic and its spherical harmonics are the point of it: coefficients drawn from a
low-frequency function of position plus noise, with band energy falling by degree — the property a
real fit has and the one both the quantizer and the entropy coder act on. (The conformance corpus
fills coefficients with a counter, which deflate codes almost perfectly and coarser quantization
only disturbs; measuring rate on that fixture would say quantizing makes files _bigger_, which is
true of the counter and false of everything else.)

**These numbers are against this format's own 8-bit deflate baseline. Nothing here is a comparison
with another format.** `file vs base` and `SH vs base` are ratios to the first row; `SH PSNR` is the
peak signal-to-noise of the reconstructed coefficients; `max err` is the largest single byte-level
deviation; `in bounds` confirms the encoder's declared per-band bound held on every gaussian.

## Degree-3 scene, deflate (the default codec)

On this scene the spherical harmonics are **49% of the file** at full precision (14,740 of 29,929
bytes), so the bit depth is where the bytes are.

| SH bits    | file bytes | SH bytes | file vs base | SH vs base | SH PSNR  | max err | in bounds |
| ---------- | ---------- | -------- | ------------ | ---------- | -------- | ------- | --------- |
| 8 (base)   | 29,929     | 14,740   | 1.000        | 1.000      | lossless | 0       | yes       |
| 7          | 27,415     | 12,171   | 0.916        | 0.826      | 51.2 dB  | 1       | yes       |
| 6          | 24,740     | 9,496    | 0.827        | 0.644      | 46.3 dB  | 2       | yes       |
| 5          | 21,732     | 6,488    | 0.726        | 0.440      | 41.1 dB  | 4       | yes       |
| 4          | 20,159     | 4,915    | 0.674        | 0.333      | 34.1 dB  | 8       | yes       |
| 3          | 19,540     | 4,292    | 0.653        | 0.291      | 26.6 dB  | 16      | yes       |
| balanced   | 24,229     | 8,985    | 0.810        | 0.610      | 44.0 dB  | 4       | yes       |
| aggressive | 21,267     | 6,021    | 0.711        | 0.408      | 28.5 dB  | 16      | yes       |

`balanced` and `aggressive` are the per-band ladders: they spend more bits on the low-degree bands
that carry most of the energy and fewer on the high-degree bands that carry little, so at a given
file size they hold more PSNR than a uniform cut does — the `balanced` row is smaller than uniform-6
and higher-quality than uniform-5.

## Degree-3 scene, zstd

The zstd rows tell the same story with a stronger backstop coder. At level 3 zstd trails deflate
slightly on this already-quantized data (the byte-plane shuffle leaves little for the entropy
stage); at level 19 it pulls ahead — uniform-5 reaches `0.691` of the baseline file where deflate
reaches `0.726`, at identical error, because the error is set by the bit depth and only the residual
coding differs.

| SH bits | zstd-3 file | zstd-3 vs base | zstd-19 file | zstd-19 vs base | SH PSNR  |
| ------- | ----------- | -------------- | ------------ | --------------- | -------- |
| 8       | 30,173      | 1.008          | 29,406       | 0.983           | lossless |
| 7       | 27,619      | 0.923          | 26,275       | 0.878           | 51.2 dB  |
| 6       | 25,285      | 0.845          | 23,483       | 0.785           | 46.3 dB  |
| 5       | 22,549      | 0.753          | 20,677       | 0.691           | 41.1 dB  |
| 4       | 21,182      | 0.708          | 19,068       | 0.637           | 34.1 dB  |
| 3       | 20,656      | 0.690          | 18,563       | 0.620           | 26.6 dB  |

## Reading the trade

The error is the bit depth's, not the codec's: every codec column at a given depth shares one
`SH PSNR` and one `max err`, because quantization sets the error and compression only codes what is
left. So the choice is two independent dials — pick the bit depth for the quality you will accept,
then pick the codec and level for how hard you want to squeeze the result. On this scene, dropping
SH from 8 to 5 bits costs about 41 dB of headroom (visually lossless for most content) and returns a
quarter of the whole file; 5-bit with zstd-19 returns nearly a third. The `in bounds` column is the
guarantee underneath all of it: the deviation the file declares is the deviation it holds, verified
per gaussian at encode.
