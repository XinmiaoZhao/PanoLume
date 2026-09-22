# PanoLume contributor instructions

Keep App presentation, Core policy, Engine geometry/I/O, and Metal boundaries
explicit. Long-running native calls must not block the main actor. Preserve request
identity, projection release barriers, manual-point accounting and observable CPU
fallback. Do not relax geometry thresholds or change certification to obtain a pass.

Run focused tests, the Swift suite and NativeSelfTest for engine/Core changes.
Use synthetic inputs by default. Builds, tests and the absence of Metal must keep
production export fail-closed. Do not install over an existing application without
an explicit request. Do not commit generated diagnostics, raw photographs or builds.

Keep public source self-contained. Document implementation sources and dependency
licenses for new algorithms. Preserve unrelated contributor changes.
