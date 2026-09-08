# Native splat renderer notes

Verified September 8, 2026: Xcode 27 beta 6's iOS 27 SDK declares `GaussianSplatComponent`, `GaussianSplatResource`, and the throwing `BufferResource` initializer. Physical rendering remains untested.

Apple's [component documentation](https://developer.apple.com/documentation/realitykit/gaussiansplatcomponent) supplies a buffer-based example and specifies Apple7 GPU-family support. The renderer expects positions, scale, quaternion rotation, opacity and spherical-harmonic coefficients; the app must parse its asset format. Quaternion buffer order is scalar first (`r, x, y, z`), so do not copy SIMD quaternion storage blindly.

Use explicit offsets and strides, and align `LowLevelBuffer` capacity as required. Resource creation can throw for invalid descriptors or excessive splat counts. Keep the proxy on failure. The renderer blends transparent splats and does not require an app-authored shader. Uniform ghost tint must be applied to appearance data rather than a mesh material. [GaussianSplatResource](https://developer.apple.com/documentation/realitykit/gaussiansplatresource) exposes scale/opacity activation controls; match those to the asset's representation to avoid applying exponentials or sigmoid twice.

Before integrating captured assets: render a small known metric fixture, verify color/opacity, quaternion order, orientation and anchored motion on the actual iPhone. Degree-zero color interpretation, real depth interaction and the project splat budget still require this device check.
