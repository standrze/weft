# Contributing to weft

Use Swift 6.4 or newer. From the package root:

```sh
swift format format --in-place --recursive Package.swift Sources Tests Examples
scripts/check-format.sh
swift test
swift build --product weft-demo
python3 scripts/smoke.py .build/debug/weft-demo
```

Keep `weft` lowercase. Use four-space indentation, a 120-column target,
and one primary responsibility per file. Add behavior-focused tests for fixes.
Terminal cells, graphemes, and bytes are distinct units: document which an API uses.
Run the demo in a real terminal to inspect colors, input, and resize behavior.

Contributions are under Apache-2.0; preserve third-party notices.
