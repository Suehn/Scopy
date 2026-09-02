# Bundled pngquant build

`Scopy/Resources/Tools/pngquant` is built from source, not downloaded from pngquant.org.

| | |
| --- | --- |
| CLI | `kornelski/pngquant` `main` at `913a90d` (version string `3.0.4`), plus the fork's `perf` branch at `256e081`: submodule pointer and log-callback fix (`af354ef`), then a Rust PNG writer (parallel zlib-rs deflate, level 9 / memLevel 5, thread-count-independent output) and zero-copy PAM (`P7`, 8-bit `RGB_ALPHA`) input via `mmap` |
| Engine | `ImageOptim/libimagequant` `main` at `9388d26` (4.5.0) plus the fork's `perf` branch at `fddcf09`: parallel histogram, speculative median cut, chunked/interleaved dithering, SIMD neighbor-list search |
| Cargo features | `static cocoa` (default `lcms2` + `threads`): libpng and lcms2 linked statically (libpng only serves version info in the Cocoa build), Cocoa image reader, zlib-rs for output; no system `libz` in the write path |
| Architectures | universal `arm64` + `x86_64`, `lipo`-merged, ad-hoc signed (`codesign -s - --identifier pngquant`) |
| Toolchain | rustc 1.98.0 (Homebrew); the `x86_64` slice is cross-built with `RUSTC_BOOTSTRAP=1 cargo build --release --target x86_64-apple-darwin -Zbuild-std=std,panic_abort --features "static cocoa"` |

Behavior differences from the previously bundled official `3.0.3` build come from the newer upstream engine (`4.5.0`), not from the fork's speed work: the fork's output is verified against unchanged `4.5.0` on a 58-output bench set (MSE within -4%..+0.7%, all-threads and single-thread outputs byte-identical). The x86_64 and arm64 slices are byte-identical on that bench set; on a 2160x29511 export the Rosetta-run x86_64 slice differs from arm64 in 0.002% of index bytes (1424 of 63.7M), which the previous build also did. Images whose color count already fits the palette may now be reduced by one color and dithered when `--quality` max is below 100, which `--skip-if-larger` turns into "unchanged" (exit 98) for already-indexed inputs.

The Rust writer produces the same scanlines as libpng did (verified byte-for-byte on palette, tRNS, 4-bit and truecolor-fallback outputs) with files within +0.1%/-0.6% of libpng level 9; the compressed bytes differ, and chunk order is `gAMA` before `sRGB`. Scopy's export path feeds the bitmap as PAM (see `PngquantService.writePAM`), so pngquant neither decodes a PNG nor copies the pixels.

Both repositories are GPL-3.0-or-later (see `COPYRIGHT`); the fork's `perf` branches are the corresponding source for this binary.
