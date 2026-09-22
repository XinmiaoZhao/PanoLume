# PanoLume

PanoLume is an independent macOS panorama-stitching project in active development,
led by Xinmiao Zhao with AI coding-agent assistance. It focuses on night-sky RAW
photographs and ordinary images. The application uses SwiftUI/AppKit, a Swift
state/policy layer, a C++/Objective-C++ engine, and Metal rendering.

## Build from source

Requires macOS 14+, Xcode Command Line Tools with Swift 6, and Homebrew dependencies:

```sh
brew install opencv@4 ceres-solver eigen libraw libtiff glog
bash scripts/build_metal_renderer.sh
cd macos/MyPTGuiNative
swift build --jobs 4
swift test --jobs 4
swift run MyPTGuiNativeSelfTest
swift run MyPTGuiNative
```

The package/product names retain `MyPTGui` for compatibility. Python is not an
application runtime dependency. No other source checkout or private module is
required. The optional source-extension hooks are inactive in this distribution.

## Capabilities and current limits

- Ordinary photographs: SIFT matching, homography preview, control-point editing
  and re-optimization. Homography production full-resolution export is not supported.
- Night skies: PSF measurements, star identities, camera optimization and independent
  geometry evaluation. Unverified drafts remain visibly distinct from verified results.
- Panorama viewport with zoom/pan and camera projection interaction. One active render,
  newest pending request, and a release barrier prevent stale drag callbacks replacing
  committed frames. Metal Fast/Quality has observable CPU fallback; multiband uses CPU.
- Diagnostics preserve per-pair failures and manual-point acceptance/rejection reasons.
- Read-only plaintext PTGui v55 JSON import for a checked subset of stereographic,
  rectilinear, undistorted projects. Basic imported-project reconstruction uses saved
  poses and native single-source ownership. Experimental refinement/owner modes are
  not supported by this renderer and are explicitly rejected. It is not a claim to
  reproduce proprietary optimization or blending.

**Production full-resolution export remains locked until a matching certification
is promoted.** Source builds are explicitly uncertified. Import reconstruction is
an independently validated saved-project path; it does not unlock the workbench
production gate. `capabilities` returning 3 for missing certification or unavailable
Metal is expected. A successful build or synthetic test is not release certification.

## Reproducible synthetic check

```sh
cd macos/MyPTGuiNative
swift run MyPTGuiRegression standard-image-regression \
  --case synthetic-crops --output-dir /tmp/panolume-synthetic
```

This generates its own inputs and uses the existing geometry and image-comparison
thresholds. It does not establish universal RAW quality or a performance speedup.
Delete the temporary output after reviewing it.

## License and contributions

Project-owned source is MIT licensed. Dependencies keep their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Artwork is separately identified
there. This repository distributes source, not a prebuilt signed application.

This repository receives tested source snapshots. Issues and pull requests are
welcome; accepted changes are integrated through the development source and then
synchronized back. Generated snapshots must remain independently buildable.

## 中文说明

PanoLume 是赵鑫淼主导的独立在研项目，面向星空 RAW 与普通照片拼接。
开源代码可独立构建 macOS 应用；生产全分辨率导出仍受严格认证门控制。
项目使用 AI agent 辅助实现与测试，重点展示星点测量、独立几何验证、
可诊断失败以及投影交互的并发控制。源码开放不代表已经完成生产认证。
