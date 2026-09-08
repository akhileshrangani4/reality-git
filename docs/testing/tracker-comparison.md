# Local and Mac tracker comparison

## Current status — September 8, 2026

Vision is the implementation baseline. No physical iPhone capture or tracker comparison has been run. The Mac runs macOS 26.5.2 with Xcode 27 beta 6. The iPhone is not currently available to the development tools.

The [component review](../research/2026-09-08-reusable-components.md) identifies temporal EdgeTAM as an evaluation candidate. Its image-only Core ML example does not establish temporal tracking; the streaming implementation must preserve memory across observations. There is no evidence yet to justify adding a Python service or replacing Vision.

## Device comparison to run

Use the same short recorded sequence for both trackers: stationary object while the camera moves, brief occlusion, turn away and return, relocation, and a similar-looking distractor. Save capture timestamps and source IDs with the sequence. Keep the selected reference identical.

Record:

| Measurement | Vision | Temporal EdgeTAM |
|---|---|---|
| Revision / runtime | Pending | Pending |
| Mask or box remains on selected object | Unrun | Unrun |
| Wrong-object switches | Unrun | Unrun |
| Recovery after occlusion | Unrun | Unrun |
| Observation latency and dropped samples | Unrun | Unrun |
| Memory over repeated streaming | Unrun | Unrun |
| Compute device | Unmeasured | MPS must be verified |
| Matching source IDs and geometry | Unrun | Unrun |

Retain Vision unless the temporal model improves the same sequence while keeping latency and memory bounded. Neither a compile nor a mocked route test demonstrates visual tracking accuracy.
