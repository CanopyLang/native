#!/usr/bin/env python3
# pyright: reportMissingImports=false
#   ^ onnx + coremltools are OPTIONAL, install-on-demand deps (see the pip hints in die()); this
#     offline conversion tool is run on a machine that has them, not in CI/this checkout.
# convert_restore.py — convert the ESPCN super-resolution ONNX model to a Core ML .mlpackage for
# the iOS RestoreEngine (L-I3 / plans/06-ios-bringup §6, plans/11-lumen-critical-path L-I3).
#
# WHY THIS EXISTS
# ---------------
# The iOS host's RestoreEngine runs the photo super-resolution model on Apple's Neural Engine via
# Core ML (CanopyRestoreEngineModule.mm). Core ML cannot load a raw ONNX file; it needs an
# .mlpackage (ML program / NeuralNetwork). This script does that conversion OFFLINE so the build
# is reproducible and Mac-free up to the artifact: coremltools serializes the model spec on Linux;
# only RUNNING inference is Apple-only.
#
# THE MODEL (matches CanopyRestoreEngineModule.mm:59-62 and RestoreEngineModule.h)
# --------------------------------------------------------------------------------
# super-resolution-10.onnx (the same file shipped in the Android APK at
# host/android/app/src/main/assets/models/super-resolution-10.onnx) is the canonical ESPCN
# sub-pixel super-resolution network: a single-channel (luma Y) 4-conv body followed by a
# depth-to-space pixel shuffle with upscale factor 3.
#
#   input  "input"  : float32 [1, 1, 224, 224]   (Y plane in [0,1])
#   output "output" : float32 [1, 1, 672, 672]   (3x super-res Y)
#
# The .mm module packs/unpacks rank-4 MLMultiArrays of EXACTLY these shapes (kModelIn=224,
# kModelOut=672) and reads the IO feature names dynamically, so this converter declares the IO as
# rank-4 [1,1,H,W] named "input"/"output" to line up byte-for-byte with the host's memcpy.
#
# CONVERSION STRATEGY — rebuild-from-weights (Linux-clean, torch-free)
# -------------------------------------------------------------------
# Modern coremltools (7+) dropped the direct ONNX frontend (onnx-coreml). Rather than depend on a
# torch round-trip, we read the ESPCN convolution weights straight out of the ONNX initializers
# and rebuild the identical graph with coremltools' NeuralNetworkBuilder. ESPCN is a tiny, fixed
# topology (4 Conv+ReLU then a DepthToSpace shuffle), so the rebuild is exact and the resulting
# .mlpackage runs the same arithmetic the ORT path does on Android. The script VALIDATES the ONNX
# matches the expected topology (conv shapes, upscale factor) and fails loudly otherwise, so a
# swapped/retrained model can never silently produce a wrong artifact.
#
# RUN (from the repo root; see host/ios/BUILD-AND-VALIDATE.md §3.3):
#   python3 host/ios/CanopyHostCore/ML/tools/convert_restore.py \
#     --onnx host/android/app/src/main/assets/models/super-resolution-10.onnx \
#     --out  host/ios/CanopyHostApp/Resources/models/restore.mlpackage
#
# Dependencies (pip, Linux-ok):  coremltools>=7  onnx  numpy
#   python3 -m pip install coremltools onnx numpy
#
# The .mlpackage is then copied into the .app by the project.yml "Copy Canopy Bundle" build phase
# and located at boot by CanopyModuleHost -resolveRestoreModelPath. Xcode compiles .mlpackage ->
# .mlmodelc; if a raw .mlpackage reaches the device, the module compiles it on first use
# (-ensureModel:). Either way RestoreEngine resolves on iOS.

import argparse
import os
import shutil
import sys
from typing import NoReturn

# The fixed ESPCN contract (must match CanopyRestoreEngineModule.mm:59-62).
MODEL_IN = 224
MODEL_OUT = 672
UPSCALE = 3
IN_NAME = "input"
OUT_NAME = "output"


def die(msg: str) -> NoReturn:
    sys.stderr.write("convert_restore.py: error: %s\n" % msg)
    sys.exit(1)


def _require(cond, msg):
    if not cond:
        die(msg)


def load_onnx_weights(onnx_path):
    """Read the ESPCN initializers from the ONNX file and validate the topology.

    Returns a dict name -> numpy array of the conv weights/biases. Fails loudly if the model is
    not the expected single-channel 4-conv ESPCN with upscale 3.
    """
    try:
        import onnx
        from onnx import numpy_helper
    except ImportError:
        die("the 'onnx' package is required to read the model — "
            "run: python3 -m pip install onnx numpy")

    if not os.path.isfile(onnx_path):
        die("ONNX model not found: %s" % onnx_path)

    model = onnx.load(onnx_path)
    graph = model.graph
    inits = {init.name: numpy_helper.to_array(init) for init in graph.initializer}

    # Topology guard: the four ESPCN convs must be present with the canonical shapes. This is the
    # exact filter set of the canonical super-resolution-10.onnx (1->64->64->32->9 channels). A
    # retrained/face/colorize model with a different topology fails here rather than producing an
    # artifact the host's fixed 224/672 pipeline would mis-feed.
    expected = {
        "conv1.weight": (64, 1, 5, 5), "conv1.bias": (64,),
        "conv2.weight": (64, 64, 3, 3), "conv2.bias": (64,),
        "conv3.weight": (32, 64, 3, 3), "conv3.bias": (32,),
        "conv4.weight": (9, 32, 3, 3), "conv4.bias": (9,),
    }
    for name, shape in expected.items():
        _require(name in inits, "ONNX missing expected ESPCN initializer '%s' — is this the "
                                "canonical super-resolution-10.onnx? (got: %s)"
                 % (name, ", ".join(sorted(inits.keys()))))
        got = tuple(inits[name].shape)
        _require(got == shape, "ONNX initializer '%s' has shape %s, expected %s — model topology "
                               "does not match the host's 224->672 ESPCN pipeline"
                 % (name, got, shape))

    # The final conv emits UPSCALE^2 channels (9 = 3*3) so depth-to-space shuffles to a single
    # channel at 3x. Assert that invariant so a wrong upscale can't slip through.
    out_ch = inits["conv4.weight"].shape[0]
    _require(out_ch == UPSCALE * UPSCALE,
             "conv4 emits %d channels; expected %d for an upscale-%d pixel shuffle"
             % (out_ch, UPSCALE * UPSCALE, UPSCALE))

    return inits


def build_mlmodel(inits, out_path):
    """Rebuild the ESPCN graph with coremltools' NeuralNetworkBuilder and save the .mlpackage."""
    try:
        import numpy as np
        import coremltools as ct
        from coremltools.models.neural_network import NeuralNetworkBuilder
        from coremltools.models import datatypes
    except ImportError:
        die("coremltools (>=7) and numpy are required — "
            "run: python3 -m pip install coremltools onnx numpy")

    # Rank-4 [1,1,H,W] IO to match the host's MLMultiArray packing exactly (.mm initWithShape
    # @[@1,@1,@224,@224] / count check 672*672). disable_rank5_shape_mapping keeps the declared
    # ranks verbatim instead of the legacy rank-5 mapping.
    input_features = [(IN_NAME, datatypes.Array(1, 1, MODEL_IN, MODEL_IN))]
    output_features = [(OUT_NAME, datatypes.Array(1, 1, MODEL_OUT, MODEL_OUT))]
    builder = NeuralNetworkBuilder(input_features, output_features,
                                   disable_rank5_shape_mapping=True)

    def add_conv(name, x, y, wkey, bkey, has_relu):
        W = inits[wkey]            # ONNX weight layout [O, I, kh, kw]
        bias = inits[bkey]
        out_c, in_c, kh, kw = W.shape
        builder.add_convolution(
            name=name, kernel_channels=in_c, output_channels=out_c,
            height=kh, width=kw, stride_height=1, stride_width=1,
            border_mode="same", groups=1,
            # CoreML's add_convolution wants W as [kh, kw, in_c, out_c].
            W=np.transpose(W, (2, 3, 1, 0)),
            b=bias, has_bias=True,
            input_name=x, output_name=(y + "_pre" if has_relu else y))
        if has_relu:
            builder.add_activation(name=name + "_relu", non_linearity="RELU",
                                   input_name=y + "_pre", output_name=y)

    add_conv("conv1", IN_NAME, "c1", "conv1.weight", "conv1.bias", True)
    add_conv("conv2", "c1", "c2", "conv2.weight", "conv2.bias", True)
    add_conv("conv3", "c2", "c3", "conv3.weight", "conv3.bias", True)
    add_conv("conv4", "c3", "c4", "conv4.weight", "conv4.bias", False)

    # ESPCN sub-pixel shuffle: depth-to-space, block_size=UPSCALE. Takes the [9,224,224] feature
    # map to [1,672,672] — the same reshape/transpose/reshape the ONNX graph encodes.
    builder.add_reorganize_data("pixelshuffle", input_name="c4", output_name=OUT_NAME,
                                mode="DEPTH_TO_SPACE", block_size=UPSCALE)

    # Human-readable metadata (shows in Xcode's model viewer / the .mlmodelc Manifest).
    builder.spec.description.metadata.shortDescription = (
        "Canopy RestoreEngine ESPCN super-resolution (Y plane, 3x: 224x224 -> 672x672). "
        "Rebuilt from super-resolution-10.onnx for Core ML / ANE.")
    builder.spec.description.metadata.author = "canopy/native convert_restore.py"

    mlmodel = ct.models.MLModel(builder.spec)

    # .save overwrites a file but not a populated directory; clear a stale package first.
    if os.path.isdir(out_path):
        shutil.rmtree(out_path)
    elif os.path.isfile(out_path):
        os.remove(out_path)
    parent = os.path.dirname(os.path.abspath(out_path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)

    mlmodel.save(out_path)
    return mlmodel


def verify_saved(out_path):
    """Re-load the saved spec and assert the IO contract the .mm host depends on."""
    import coremltools as ct
    ml = ct.models.MLModel(out_path)
    spec = ml.get_spec()
    ins = {f.name: list(f.type.multiArrayType.shape) for f in spec.description.input}
    outs = {f.name: list(f.type.multiArrayType.shape) for f in spec.description.output}
    _require(ins.get(IN_NAME) == [1, 1, MODEL_IN, MODEL_IN],
             "saved model input '%s' shape %s != [1,1,%d,%d]"
             % (IN_NAME, ins.get(IN_NAME), MODEL_IN, MODEL_IN))
    _require(outs.get(OUT_NAME) == [1, 1, MODEL_OUT, MODEL_OUT],
             "saved model output '%s' shape %s != [1,1,%d,%d]"
             % (OUT_NAME, outs.get(OUT_NAME), MODEL_OUT, MODEL_OUT))
    return ins, outs


def main(argv):
    ap = argparse.ArgumentParser(
        description="Convert the ESPCN super-resolution ONNX model to a Core ML .mlpackage for "
                    "the iOS RestoreEngine.")
    ap.add_argument("--onnx", required=True,
                    help="path to super-resolution-10.onnx (e.g. "
                         "host/android/app/src/main/assets/models/super-resolution-10.onnx)")
    ap.add_argument("--out", required=True,
                    help="output .mlpackage path (e.g. "
                         "host/ios/CanopyHostApp/Resources/models/restore.mlpackage)")
    args = ap.parse_args(argv)

    if not args.out.endswith(".mlpackage"):
        die("--out must end in .mlpackage (got %s)" % args.out)

    inits = load_onnx_weights(args.onnx)
    build_mlmodel(inits, args.out)
    ins, outs = verify_saved(args.out)

    sys.stdout.write(
        "convert_restore.py: wrote %s\n"
        "  input  %s -> %s\n"
        "  output %s -> %s\n"
        "  copy into the .app via project.yml 'Copy Canopy Bundle'; "
        "Xcode compiles .mlpackage -> .mlmodelc at build, or the host compiles it on first use.\n"
        % (args.out, IN_NAME, ins.get(IN_NAME), OUT_NAME, outs.get(OUT_NAME)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
