# L-I3 — RestoreEngine on iOS (Core ML / ANE)

| | |
|---|---|
| **Track** | ios |
| **Status** | partial |
| **Effort** | ~2.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | L-I1 (todo) |
| **Open blockers** | L-I1 (todo) |
| **Source plan** | plans/11-lumen-critical-path.md |

Compile CanopyRestoreEngineModule.mm, fix the dead CanopyMakeCoreMLRestoreModule weak-symbol, and convert/ship the Core ML model for the ANE restore path.

**Notes:** Weak-symbol now defined (CanopyRestoreEngineModule.mm). This wave: authored the ESPCN->Core ML
converter (host/ios/CanopyHostCore/ML/tools/convert_restore.py — rebuilds the 4-conv+pixel-shuffle ESPCN
graph from the ONNX initializers, Linux-runnable, torch-free), RAN it to SHIP the model artifact
(host/ios/CanopyHostApp/Resources/models/restore.mlpackage, [1,1,224,224]->[1,1,672,672] rank-4 IO matching
the .mm's MLMultiArray packing), and VERIFIED arithmetic equivalence to the Android ORT path (rebuilt
graph vs the ONNX reference: max abs err 1.5e-6). Added a device-free structural gate
(scripts/check-ios-restore-coreml.sh, wired into ci-test.sh) + device-free RestoreEngine XCTest legs
(CanopyCapabilityParityTests.mm). STILL Mac-gated: linking the .mm (CoreML/Xcode) + RUNNING the Core ML
inference on the ANE — exercised on a device by CanopyHostUITests. Blocked-on-L-I1 only for the on-device run.
