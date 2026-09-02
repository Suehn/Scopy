# Bundled pngquant build

`Scopy/Resources/Tools/pngquant` is built from source, not downloaded from pngquant.org.

| | |
| --- | --- |
| CLI | `kornelski/pngquant` `main` at `913a90d` (version string `3.0.4`), plus `af354ef` on the fork's `perf` branch (submodule pointer, `Some(log_callback)` fix, `Cargo.lock`) |
| Engine | `ImageOptim/libimagequant` `main` at `9388d26` (4.5.0) plus the fork's `perf` branch at `fddcf09`: parallel histogram, speculative median cut, chunked/interleaved dithering, SIMD neighbor-list search |
| Cargo features | `static cocoa` (default `lcms2` + `threads`): libpng and lcms2 linked statically, Cocoa image reader, system `libz` |
| Architectures | universal `arm64` + `x86_64`, `lipo`-merged, ad-hoc signed (`codesign -s - --identifier pngquant`) |
| Toolchain | rustc 1.98.0 (Homebrew); the `x86_64` slice is cross-built with `RUSTC_BOOTSTRAP=1 cargo build --release --target x86_64-apple-darwin -Zbuild-std=std,panic_abort --features "static cocoa"` |

Behavior differences from the previously bundled official `3.0.3` build come from the newer upstream engine (`4.5.0`), not from the fork's speed work: the fork's output is verified against unchanged `4.5.0` on a 58-output bench set (MSE within -4%..+0.7%, all-threads and single-thread outputs byte-identical, x86_64 and arm64 outputs byte-identical). Images whose color count already fits the palette may now be reduced by one color and dithered when `--quality` max is below 100, which `--skip-if-larger` turns into "unchanged" (exit 98) for already-indexed inputs.

Both repositories are GPL-3.0-or-later (see `COPYRIGHT`); the fork's `perf` branches are the corresponding source for this binary.
