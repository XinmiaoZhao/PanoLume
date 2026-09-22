# Public engineering notes

## Independently buildable source distribution (Codex, 2026-09-22)

PanoLume provides its native SwiftUI/AppKit, Core, C++/Objective-C++ and Metal
implementation as a self-contained development source tree. Plaintext project
parsing is independent of the input-byte reader. Source identity is generated from
all included behavior-bearing files; this distribution starts explicitly uncertified.

Synthetic geometry, projection scheduling and ordinary-image tests accompany the
source. Imported-project reconstruction preserves saved poses and reports unsupported
options rather than silently approximating them. Production export remains locked.

## Unified PanoLume source identity (Codex, 2026-09-22)

The package, modules, command-line tools, C ABI, app identity and renderer now use
PanoLume consistently. Metal API 6 requires the matching renderer. Projection,
geometry thresholds, native diagnostic fields and export certification policy are
unchanged. Source snapshots use the project maintainer's attribution and reviewed
change descriptions. Development builds remain uncertified.
