# Public engineering notes

## Independently buildable source distribution (Codex, 2026-09-22)

PanoLume provides its native SwiftUI/AppKit, Core, C++/Objective-C++ and Metal
implementation as a self-contained development source tree. Plaintext project
parsing is independent of the input-byte reader. Source identity is generated from
all included behavior-bearing files; this distribution starts explicitly uncertified.

Synthetic geometry, projection scheduling and ordinary-image tests accompany the
source. Imported-project reconstruction preserves saved poses and reports unsupported
options rather than silently approximating them. Production export remains locked.
