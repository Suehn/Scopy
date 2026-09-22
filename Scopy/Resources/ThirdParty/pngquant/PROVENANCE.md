# Bundled pngquant build

`Scopy/Resources/Tools/pngquant` is built from source, not downloaded from pngquant.org.

| | |
| --- | --- |
| CLI | `kornelski/pngquant` `main` at `913a90d` (version string `3.0.4`), plus the fork's `perf2` branch at `624df85`: log-callback fix (`af354ef`); Rust PNG writer with parallel zlib-rs deflate and zero-copy PAM (`P7`, 8-bit `RGB_ALPHA`) input via `mmap` (`256e081`); deflate match hints for the byte before and the rows above, a shorter search for flat pieces of images of at least 8 MiB of scanlines, 8-bit rows compressed where they are, per-piece Adler-32 (`75f2503`, `624df85`); engine update (`a5c72be`) |
| Engine | `ImageOptim/libimagequant` `main` at `9388d26` (4.5.0), plus the fork's `perf2` branch at `b664d56`, which merges `perf` (`fddcf09`: parallel histogram, speculative median cut, chunked/interleaved dithering, SIMD neighbor-list search) with the flat-area dithering fast paths, the nearest-color cache and parallel speed-1 dithering (`75409e5`), and the 2026-09-05/06 phase 3/4 engine work (`f349658`: NEON contrast maps, blur and median-cut weights, same-alpha distances, a gamut fast path when adding dithering error, per-thread chunk buffers) |
| zlib | zlib-rs 0.6.7 vendored in the CLI fork as `vendor/zlib-rs` (Zlib license), used through `[patch.crates-io]`, plus `set_match_hints`: distances whose candidates are compared before the hash chain |
| Cargo features | `static cocoa` (default `lcms2` + `threads`): libpng and lcms2 linked statically (libpng only serves version info in the Cocoa build), Cocoa image reader, zlib-rs for output; no system `libz` in the write path |
| Architectures | universal `arm64` + `x86_64`, `lipo`-merged, ad-hoc signed (`codesign -s - --identifier pngquant`) |
| Toolchain | rustc 1.98.0 (Homebrew); `arm64` with `cargo build --release --features "static cocoa"`; the `x86_64` slice is cross-built with `RUSTC_BOOTSTRAP=1 cargo build --release --target x86_64-apple-darwin -Zbuild-std=std,panic_abort --features "static cocoa"` |

Compared with the previous bundled build (fork `perf`: CLI `256e081`, engine `fddcf09`; Scopy v0.74.0-v0.80.7):

- Speeds 2-10 decode to the same pixels, except that images taller than 2,816 rows are dithered in more, shorter chunks (16 per core instead of 8), so the chunk borders fall on other rows: 0.05% of the pixels of a 2160x29511 export differ, with MSE 0.5111 -> 0.5109 and 3x3/7x7-blurred MSE within 0.001. Output does not depend on the number of threads; the chunk count of tall images depends on the machine's core count, as before.
- Speed 1 dithers in parallel chunks of at least 256 rows, each starting with 16 rows of diffusion, instead of on one thread. The result is an equivalent dither pattern: 0.14% of the pixels of the 2160x29511 export at 16 colors and up to 3% of the 4-megapixel bench images differ, with MSE and blurred MSE within 0.1%.
- Compressed bytes differ; sizes are within -3.3%..+0.2% on the 58-output bench set (0.1% smaller in total) and -0.07%..+0.93% on real exports. The x86_64 and arm64 slices decode to identical pixels on the exports; 4 of 29 bench outputs differ in 0.0003-0.02% of their pixels (floating-point paths), with the same MSE to four digits.

Behavior inherited from upstream 4.5.0 (not from the fork): images whose color count already fits the palette may be reduced by one color and dithered when `--quality` max is below 100, which `--skip-if-larger` turns into "unchanged" (exit 98) for already-indexed inputs.

The Rust writer produces the same scanlines as libpng did; chunk order is `gAMA` before `sRGB`. Scopy's export path feeds the bitmap as PAM (see `PngquantService.compressPAMFile`), so pngquant neither decodes a PNG nor copies the pixels.

pngquant and libimagequant are GPL-3.0-or-later (see `COPYRIGHT`); zlib-rs is under the Zlib license. The fork's `perf2` branches (CLI `624df85`, engine `b664d56`) are the corresponding source for this binary.
