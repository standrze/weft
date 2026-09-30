# Working on weft

Keep the package, product, and module name `weft` lowercase.
Use four-space indentation and the checked-in `.swift-format` settings.
Keep application policy outside the library. Preserve terminal mode ownership,
Unicode cell geometry, and asynchronous input semantics.
Run `scripts/check-format.sh`, `swift test`, and
`python3 scripts/smoke.py .build/debug/weft-demo` after changes.
Never run simultaneous SwiftPM builds in the same build directory.
