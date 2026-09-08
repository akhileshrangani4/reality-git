# Reality Git: reusable components research

Checked September 8, 2026. This is a repository/source review, not a benchmark or a claim that these components already work together. Research covered GitHub metadata, recent default-branch commits, releases, selected source files and open issues; Apple and Hugging Face documentation; and live X searches for msplat, EdgeTAM and Brush. Search crawl dates were not treated as maintenance dates.

## Recommendation

Keep ARKit/LiDAR geometry and local Vision tracking. Following the user’s willingness to install iOS 27, evaluate native RealityKit splats first after upgrading the toolchain; retain MetalSplatter as the fallback. Evaluate Brush first for trained object appearance, with msplat as the alternative. Retain simple depth Gaussians as a preview/fallback rather than writing a reconstruction engine first. Benchmark temporal EdgeTAM on the Mac before replacing baseline Vision assistance. Do not assume a Core ML image segmenter includes video memory or identity recovery.

No dependencies have been installed or executed during this review. Exact dependency pins should be selected by a small compatibility test, not solely by recency.

## Reconstruction and rendering shortlist

| Project | Verified maintenance evidence | Fit and decision |
| --- | --- | --- |
| [Brush](https://github.com/ArthurBrussee/brush) | Code changes September 6, 2026; `5a9d4cfaa9`. Latest published release reviewed: v0.3.0, September 14, 2025. Apache-2.0. | First trainer to evaluate: Mac support, CLI, Nerfstudio camera poses, seed PLY and explicit mask/alpha handling. Current main has a reported regression; compare pinned versions. |
| [msplat](https://github.com/rayanht/msplat) | v1.1.4 released August 25, 2026; `6b819711fa`, correctness/memory fixes. Apache-2.0. | Strong native Metal alternative. C++ CLI and Swift bridge. Smaller development history than Brush. Mask behavior and coordinate normalization require attention. |
| [msplat-ios](https://github.com/frs0n/msplat-ios) | iOS example and memory work August 22, 2026; head `e861109858`. Apache-2.0. | Useful fork if on-device training becomes necessary; our agreed default remains Mac training. Read fixes rather than assume upstream and fork have identical behavior. |
| [MetalSplatter](https://github.com/scier/MetalSplatter) | Actual PLY/SH reader fixes September 2, 2026, `cd55a66abf`; head `464eb37c55`. Release 1.0.1 February 20, 2026. MIT. | Preferred renderer candidate; supplies splat parsing/rendering, not our AR anchoring or diff state. Check latest reader fixes against chosen output. |
| [SplatX Metal](https://github.com/PoSTMEDIA-AI/splatx-metal) | Public release snapshot August 26, 2026; `9ae5f66040`; created August 4. Apache-2.0. | Recent native alternative with test fixtures and CLI. Very young public history; secondary candidate, not a default based on benchmark claims. |
| [OpenSplat](https://github.com/WebODM/OpenSplat) | September 3, 2026; `687cc91bbe`. AGPL-3.0. | Maintained cross-platform alternative. Different license from preferred candidates; not selected for this MVP. |

Dates above come from each repository's default-branch commits and releases, not the GitHub `pushed_at` field alone. All listed repositories were unarchived when checked.

### Brush: the most directly useful interface

Its [Nerfstudio loader](https://github.com/ArthurBrussee/brush/blob/5a9d4cfaa9c4e167924fbed586e6def3fa20433b/crates/brush-dataset/src/formats/nerfstudio.rs) reads camera transforms/calibration and `ply_file_path`. That fits our calibrated ARKit capture plus LiDAR seed points. The README distinguishes transparent images, which constrain output transparency, from ignore masks, which exclude pixels from loss. For an isolated ghost, test alpha-aware training; an ignore mask alone does not guarantee removal of background Gaussians.

Do not blindly pin main: [issue #531](https://github.com/ArthurBrussee/brush/issues/531) reports disappearing splats on recent code versus v0.3.0 on AMD/Linux. This is an unconfirmed report on different hardware, not proof of a Mac failure. Compare the newer revision with the older release on identical input and retain the passing version.

### msplat: check geometry before trusting a good-looking output

The [Nerfstudio loader](https://github.com/rayanht/msplat/blob/6b819711fa7c90f054567cb4fb4937743367afdd/core/src/loaders/load_nerfstudio.cpp) invokes `autoScaleAndCenter`. Therefore we cannot assume exported positions remain in ARKit meters. Preserve/invert that transformation or disable normalization deliberately. The inspected loader does not read a mask path; alpha/loss behavior remains unverified. The [Swift package](https://github.com/rayanht/msplat/blob/6b819711fa7c90f054567cb4fb4937743367afdd/swift/Package.swift) targets macOS 15 and references a locally built XCFramework, so the README's package snippet is not a turnkey iOS dependency. Prefer its Mac CLI for initial comparison. Its [open memory issue](https://github.com/rayanht/msplat/issues/5) is another reason to measure peak memory on our capture.

## Tracking: what actually exists

| Option | Freshness and actual capability | Decision |
| --- | --- | --- |
| Apple Vision + foreground masks | System framework; no external model dependency. | Keep baseline phone tracking and Mac assistance. Short-term tracking is not durable semantic identity. |
| [EdgeTAM](https://github.com/facebookresearch/EdgeTAM) | Head January 27, 2026 is copyright maintenance; Core ML contributions November 2025. Apache-2.0. | Best temporal model candidate to benchmark on Mac. Do not call the existing Core ML example a complete temporal tracker. |
| [EdgeTAMVideo in Transformers](https://huggingface.co/docs/transformers/main/model_doc/edgetam_video) | Current maintained documentation includes streaming video inference. | Practical route to evaluate real temporal memory. Apple MPS operation/performance still needs testing; Python worker would be conditional, not an immediate server rewrite. |
| [SAM 2 Core ML conversion](https://github.com/huggingface/segment-anything-2/tree/coreml-conversion) | April 3, 2026 change only pins CI actions; conversion work October 2024. README explicitly limits conversion to image segmentation. | Useful image-segmentation reference, not a ready temporal solution. |
| [swift-object-cutout](https://github.com/arraypress/swift-object-cutout) | Actual changes August 31, 2026; `f1308ff022`. MIT text; no releases reviewed. Package requires iOS/macOS 26. | Promising small Swift selection helper; young, not selected as foundational tracking. Raises our current iOS 17 floor. |
| [SAM 3 / 3.1](https://github.com/facebookresearch/sam3) | August 26, 2026 code; `660a5e9e1b`. SAM-specific license, checkpoint access required. | Current model family, but documented CUDA setup and broader concept segmentation exceed our one-object Mac MVP. |

EdgeTAM's [current Core ML example](https://github.com/facebookresearch/EdgeTAM/blob/7711e012a30a2402c4eaab637bdb00a521302c91/coreml/inference_example.py) retains prompt points and reruns image segmentation. The [open temporal-export PR #26](https://github.com/facebookresearch/EdgeTAM/pull/26) explicitly adds memory encoder, propagator and client-owned memory bank; it has no bundled Swift wrapper. Its existence explains why published “Core ML tracking” demos are not sufficient evidence for our lost-object recovery path.

The [paper](https://openaccess.thecvf.com/content/CVPR2025/papers/Zhou_EdgeTAM_On-Device_Track_Anything_Model_CVPR_2025_paper.pdf) reports 16 FPS on iPhone 15 Pro Max. That is author-measured model performance on a different device/configuration, not a guarantee alongside our AR session. Temporal masks still do not establish that a lookalike is the original physical object; Astra reconciliation remains necessary.

## Existing capture and AR projects

| Project | Checked status | Reuse value |
| --- | --- | --- |
| [Voxelio iOS demo](https://github.com/Voxelio-app/ios-gaussian-splatting-demo) | July 16, 2026; `124c95e565`; small initial history. PolyForm Noncommercial original code. | Very close reference: ARKit capture → msplat → MetalSplatter. Read architecture; do not casually copy it as MIT/Apache code. Its README acknowledges device validation still needed. |
| [MetalGaussianSplatRelighting](https://github.com/john-rocky/MetalGaussianSplatRelighting) | August 25, 2026; `40d4ad9fc7`. MIT. | Inspect camera compositing and AR transforms. Do not import its relighting/PBR system just to tint a red ghost. |
| [lidar_gaussian_splatting](https://github.com/Kepitition/lidar_gaussian_splatting) | May 28, 2026; `ed582d6d64`. MIT. | Relevant ARKit/LiDAR dataset reference; training dependencies differ from our Mac-native preference. |
| [capture-splat](https://github.com/sandeep-devarapalli/capture-splat) | August 23, 2026; `efe9e8e87c`. Apache-2.0. | Capture packaging/guidance reference. COLMAP/Vulkan pipeline is not our direct integration. |
| [OOOSplat](https://github.com/ooolabdev/ooosplat) | September 7, 2026; `4bed6a9a6d`; v0.4.0 app. Apache-2.0. | Useful local desktop comparison. Mac Alpha bundles Brush v0.3.0 and CPU COLMAP. We already have ARKit poses, so skip importing the entire desktop/video workflow. |

## New Apple native splat support: useful, but beyond installed SDK

Apple now documents [GaussianSplatComponent](https://developer.apple.com/documentation/realitykit/gaussiansplatcomponent). Its documentation metadata specifies iOS/macOS 27 availability. The installed Xcode uses iOS SDK 26.5 and a source-interface search found no such symbol. Therefore it is not an available replacement in our currently installed toolchain. The user subsequently confirmed willingness to install iOS 27. Apple lists iOS 27 beta 8 and Xcode 27 beta 6 in its [release catalog](https://developer.apple.com/news/releases/), and [iPhone 15 Pro is compatible](https://www.apple.com/os/ios/). Evaluate native RealityKit rendering first once the required OS/SDK is installed; keep MetalSplatter as fallback. Neither upgrade nor native rendering has been tested. Native support still requires parsing source assets into buffers; it is not a reconstruction engine.

## X findings, verified against repositories

- [rayanhtt, March 8, 2026](https://x.com/rayanhtt/status/2030783843263766575): msplat author demo and M4 Max speed claim; repository/release verified. Do not transfer that benchmark to this Mac or iPhone.
- [Frs0n_, August 22, 2026](https://x.com/Frs0n_/status/2091157992653942936): iPhone trainer/memory announcement. The visible shortened repo link resolved to a missing path; checking the author's GitHub account located the actual `frs0n/msplat-ios` repository above.
- [djkesu1, November 12, 2025](https://x.com/djkesu1/status/1988690897928953886): Core ML export merged announcement. Source inspection and the later open temporal PR reveal the narrower integration scope.
- [aiwire_x, September 7, 2026](https://x.com/aiwire_x/status/2096883157295591610): led to OOOSplat; repo and bundled engine version checked independently. This is a discovery lead, not technical authority.

Live X was read through the browser because ordinary web search returned poor results. No posts/messages were sent. Technical conclusions above rely on code/docs, not social engagement or demo claims.

## Options excluded from the default

- [laanlabs/metal-splats](https://github.com/laanlabs/metal-splats): last default-branch commit October 22, 2023; explicitly a slow educational hack. Historical AR reference only.
- [RobotFlow-Labs/gsplat-mlx](https://github.com/RobotFlow-Labs/gsplat-mlx): activity concentrated March 15, 2026; no GitHub-detected license. Insufficient maintenance evidence for selection.
- [eisneim/sam2.1_mlx](https://github.com/eisneim/sam2.1_mlx): activity concentrated May 7, 2026; no GitHub-detected license. A recent creation date is not evidence of mature support.
- [Apple SHARP](https://github.com/apple/ml-sharp): December 19, 2025 head; single-image nearby-view synthesis, with MPS inference and separate code/model terms. Inference: less suitable for faithfully remembering all sides of a selected object than our guided multi-view capture.

## Changes to the implementation plan

1. Preserve core AR milestones and state reconciliation.
2. Export an interoperable Nerfstudio dataset with calibrated RGBA images, masked metric seed PLY, and explicit object/world transforms.
3. Replace custom reconstruction as the primary path with a pinned Brush-versus-msplat compatibility evaluation; use simple depth Gaussians only for preview/fallback.
4. Benchmark real temporal EdgeTAM on Mac after baseline tracking; adopt a worker only if it improves mask persistence within the frame/latency budget. Do not upgrade the phone OS merely to use a tiny wrapper.
5. Evaluate iOS 27 native RealityKit rendering after the OS/SDK upgrade, including red tint, opacity and metric alignment. Use MetalSplatter if that test fails.

## Compatibility gate before choosing dependencies

On one short masked capture, measure installation/build success, time to usable asset, peak memory, background leakage, silhouette quality, and metric alignment after training. Repeat one run to detect gross instability. Compare Brush v0.3.0 to reviewed current code; msplat v1.1.4 is the alternative. Pin the passing commit and record the transform conversion.

For tracking, use one labeled clip with occlusion, camera motion, removal and a similar-looking distractor. Compare Vision baseline to temporal EdgeTAM; measure mask accuracy, identity switches, memory growth and observation age. Keep the baseline if the model adds complexity without an observed benefit. These experiments are planned, not executed in this research pass.
