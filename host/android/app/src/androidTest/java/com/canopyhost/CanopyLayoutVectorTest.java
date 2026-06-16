package com.canopyhost;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import android.content.Context;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.MediumTest;
import androidx.test.platform.app.InstrumentationRegistry;

import com.facebook.yoga.YogaAlign;
import com.facebook.yoga.YogaDisplay;
import com.facebook.yoga.YogaEdge;
import com.facebook.yoga.YogaFlexDirection;
import com.facebook.yoga.YogaGutter;
import com.facebook.yoga.YogaJustify;
import com.facebook.yoga.YogaNode;
import com.facebook.yoga.YogaNodeFactory;
import com.facebook.yoga.YogaPositionType;
import com.facebook.yoga.YogaWrap;

import com.facebook.soloader.SoLoader;

import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * IOS-9 — the Android leg of the SHARED cross-platform layout/style test-vector suite.
 *
 * <p>This drives the SAME corpus the iOS XCTest runner (CanopyLayoutVectorTests.mm) runs:
 * {@code host/shared/test-vectors/layout-vectors.json}, copied verbatim into the test APK's assets
 * by the {@code copyLayoutVectors} Gradle task (one editable source of truth — no second copy to
 * drift). It is an INSTRUMENTATION test (src/androidTest), NOT a JVM unit test, because Yoga's layout
 * is computed by the native {@code libyoga.so} that ships in the {@code com.facebook.yoga:yoga} AAR:
 * the host uses that exact binary, and only an on-device/emulator run loads it. So this asserts
 * against the REAL Yoga the production host uses, not a re-implementation.
 *
 * <p>The anti-drift contract (master plan R5 / IOS-9): the host lays out in PHYSICAL PIXELS
 * (dp * density, see CanopyHost.dp), iOS in POINTS (dp == points, no density multiply). This runner
 * reproduces the host's px convention by sweeping every vector across the corpus's declared densities
 * ({@code 1.0, 2.0, 3.0}): each input dim is multiplied by density (exactly CanopyHost.dp), Yoga
 * computes the frame in px, then the frame is divided BACK by density to logical units and compared
 * to the corpus's {@code expect} (which is in logical units). A vector that is green on iOS but red
 * here — or green at density 1 but red at density 3 — is the silent divergence the suite exists to
 * catch. The dims in the corpus are chosen integral under the *density / /density round-trip, so the
 * normalization cancels exactly (no sub-pixel rounding gap).
 *
 * <p>The style->Yoga mapping below is a faithful port of CanopyHost.applyStyle's Yoga branch (the
 * portion that has a platform-neutral geometric effect); scripts/check-cross-platform-vectors.sh
 * asserts the host's applyStyle still carries each mapped key so this runner and the host cannot
 * diverge unnoticed.
 *
 * <p>Run (live emulator):
 * <pre>
 *   JAVA_HOME=... ANDROID_HOME=... host/android/gradlew -p host/android \
 *     :app:connectedDebugAndroidTest \
 *     -Pandroid.testInstrumentationRunnerArguments.class=com.canopyhost.CanopyLayoutVectorTest
 * </pre>
 */
@RunWith(AndroidJUnit4.class)
@MediumTest
public class CanopyLayoutVectorTest {

    private static final double TOL = 0.01;

    /**
     * Yoga's Java bindings load the native {@code libyoga.so} (from the yoga AAR) lazily on the first
     * {@code YogaNodeFactory.create()}; that load goes through SoLoader, which the host bootstraps in
     * MainActivity ({@code SoLoader.init}). This focused runner never launches the activity, so it must
     * initialize SoLoader itself against the TARGET (app-under-test) context — that is the process that
     * actually ships {@code libyoga.so}. Without this, the first node creation throws
     * ExceptionInInitializerError. Idempotent: SoLoader.init guards re-entry.
     */
    @Before
    public void initSoLoader() throws Exception {
        Context target = InstrumentationRegistry.getInstrumentation().getTargetContext();
        SoLoader.init(target, false);
    }

    // ---- corpus loading -----------------------------------------------------------------

    private JSONObject loadCorpus() throws Exception {
        Context testCtx = InstrumentationRegistry.getInstrumentation().getContext();
        try (InputStream in = testCtx.getAssets().open("layout-vectors.json")) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) bos.write(buf, 0, n);
            return new JSONObject(bos.toString("UTF-8"));
        }
    }

    private double[] densities(JSONObject corpus) {
        JSONArray a = corpus.optJSONArray("densities");
        if (a == null || a.length() == 0) return new double[]{1.0};
        double[] d = new double[a.length()];
        for (int i = 0; i < a.length(); i++) d[i] = a.optDouble(i, 1.0);
        return d;
    }

    // ---- the test ------------------------------------------------------------------------

    @Test
    public void layoutVectorsMatchAcrossDensities() throws Exception {
        JSONObject corpus = loadCorpus();
        JSONArray vectors = corpus.getJSONArray("layoutVectors");
        double[] densities = densities(corpus);
        assertTrue("corpus must declare at least one layout vector", vectors.length() > 0);

        List<String> failures = new ArrayList<>();
        int checked = 0;

        for (int vi = 0; vi < vectors.length(); vi++) {
            JSONObject v = vectors.getJSONObject(vi);
            String id = v.getString("id");
            JSONObject root = v.getJSONObject("root");
            JSONObject tree = v.getJSONObject("tree");

            for (double density : densities) {
                // Build the Yoga tree at this density (inputs in px = dp * density, exactly CanopyHost.dp).
                List<NodeBinding> bindings = new ArrayList<>();
                YogaNode rootNode = buildNode(tree, density, bindings, "root");

                // Calculate against the available surface in px (the root may take its own size).
                float availW = (float) (root.getDouble("width") * density);
                float availH = (float) (root.getDouble("height") * density);
                rootNode.calculateLayout(availW, availH);

                // Compare every node's frame, normalized back to logical units (/density).
                for (NodeBinding b : bindings) {
                    JSONObject expect = b.spec.optJSONObject("expect");
                    if (expect == null) {
                        failures.add(id + " @density " + density + ": a node is missing its 'expect' frame");
                        continue;
                    }
                    float left = b.node.getLayoutX() / (float) density;
                    float top = b.node.getLayoutY() / (float) density;
                    float width = b.node.getLayoutWidth() / (float) density;
                    float height = b.node.getLayoutHeight() / (float) density;
                    check(failures, id, density, b.path, "left", left, expect.getDouble("left"));
                    check(failures, id, density, b.path, "top", top, expect.getDouble("top"));
                    check(failures, id, density, b.path, "width", width, expect.getDouble("width"));
                    check(failures, id, density, b.path, "height", height, expect.getDouble("height"));
                    checked++;
                }
                // The Yoga JNI base owns the native subtree and frees it on GC; do NOT reset() the
                // root here (Yoga aborts on "reset a node which still has children attached"). Drop
                // the references and let the next density build a fresh tree.
                rootNode = null;
                bindings = null;
            }
        }

        if (!failures.isEmpty()) {
            StringBuilder sb = new StringBuilder("Cross-platform layout vectors DIVERGED on Android (real Yoga):\n");
            for (String f : failures) sb.append("  - ").append(f).append('\n');
            sb.append("Corpus: host/shared/test-vectors/layout-vectors.json (the single source of truth).");
            fail(sb.toString());
        }
        assertTrue("at least one frame must have been checked", checked > 0);
    }

    /**
     * The color contract is platform-neutral and the corpus pins it; assert Android's CanopyColor
     * (via the host's parseColor entry the JNI bridge uses) agrees with the corpus expectation, so the
     * SAME color vectors are validated on both hosts. CanopyColor on Android lives in CanopyHost; we
     * use its public {@code parseColorForTest} shim (added for this suite) to avoid coupling to UIKit.
     */
    @Test
    public void colorVectorsMatch() throws Exception {
        JSONObject corpus = loadCorpus();
        JSONArray vectors = corpus.optJSONArray("colorVectors");
        if (vectors == null) return; // color vectors are validated device-free + on iOS; optional here.
        List<String> failures = new ArrayList<>();
        for (int i = 0; i < vectors.length(); i++) {
            JSONObject v = vectors.getJSONObject(i);
            // The REAL host color implementation (the same one CanopyHost.parseColor delegates to).
            int argb = com.canopyhost.views.CanopyColor.parse(v.getString("input"));
            JSONObject e = v.getJSONObject("expect");
            int r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
            double a = ((argb >> 24) & 0xFF) / 255.0;
            if (r != e.getInt("r") || g != e.getInt("g") || b != e.getInt("b")
                    || Math.abs(a - e.getDouble("a")) > TOL) {
                failures.add(v.getString("id") + " (" + v.getString("input") + "): expected "
                        + e + " got rgba(" + r + "," + g + "," + b + "," + a + ")");
            }
        }
        if (!failures.isEmpty()) {
            StringBuilder sb = new StringBuilder("Color vectors DIVERGED on Android:\n");
            for (String f : failures) sb.append("  - ").append(f).append('\n');
            fail(sb.toString());
        }
    }

    // ---- Yoga tree construction (faithful port of CanopyHost.applyStyle's geometric branch) ----

    private static final class NodeBinding {
        final YogaNode node;
        final JSONObject spec;
        final String path;
        NodeBinding(YogaNode n, JSONObject s, String p) { node = n; spec = s; path = p; }
    }

    private YogaNode buildNode(JSONObject spec, double density, List<NodeBinding> out, String path)
            throws org.json.JSONException {
        YogaNode node = YogaNodeFactory.create();
        JSONObject style = spec.optJSONObject("style");
        if (style != null) applyStyle(node, style, density);
        out.add(new NodeBinding(node, spec, path));
        // path: pre-order index path (root, root/0, root/0/1, ...) — matches the corpus validator.
        JSONArray children = spec.optJSONArray("children");
        if (children != null) {
            for (int i = 0; i < children.length(); i++) {
                YogaNode child = buildNode(children.getJSONObject(i), density, out, path + "/" + i);
                node.addChildAt(child, i);
            }
        }
        return node;
    }

    private float dp(double v, double density) { return (float) (v * density); }

    private Float asFloat(String s) {
        if (s == null) return null;
        try { return Float.parseFloat(s); } catch (NumberFormatException e) { return null; }
    }

    /** Port of CanopyHost.applyStyle — only the keys with a platform-neutral GEOMETRIC effect. */
    private void applyStyle(YogaNode y, JSONObject style, double density) {
        for (java.util.Iterator<String> it = style.keys(); it.hasNext();) {
            String key = it.next();
            String s = style.isNull(key) ? null : style.optString(key);
            Float f = asFloat(s);
            switch (key) {
                case "width":  setDim(y, s, f, density, true); break;
                case "height": setDim(y, s, f, density, false); break;
                case "minWidth":  if (f != null) y.setMinWidth(dp(f, density)); break;
                case "minHeight": if (f != null) y.setMinHeight(dp(f, density)); break;
                case "maxWidth":  if (f != null) y.setMaxWidth(dp(f, density)); break;
                case "maxHeight": if (f != null) y.setMaxHeight(dp(f, density)); break;
                case "flex":       if (f != null) y.setFlex(f); break;
                case "flexGrow":   if (f != null) y.setFlexGrow(f); break;
                case "flexShrink": if (f != null) y.setFlexShrink(f); break;
                case "flexBasis":  if (f != null) y.setFlexBasis(dp(f, density)); break;
                case "flexWrap":   y.setWrap("wrap".equals(s) ? YogaWrap.WRAP : YogaWrap.NO_WRAP); break;
                case "gap":        if (f != null) y.setGap(YogaGutter.ALL, dp(f, density)); break;
                case "padding":            if (f != null) y.setPadding(YogaEdge.ALL, dp(f, density)); break;
                case "paddingTop":         if (f != null) y.setPadding(YogaEdge.TOP, dp(f, density)); break;
                case "paddingBottom":      if (f != null) y.setPadding(YogaEdge.BOTTOM, dp(f, density)); break;
                case "paddingLeft":        if (f != null) y.setPadding(YogaEdge.LEFT, dp(f, density)); break;
                case "paddingRight":       if (f != null) y.setPadding(YogaEdge.RIGHT, dp(f, density)); break;
                case "paddingHorizontal":  if (f != null) y.setPadding(YogaEdge.HORIZONTAL, dp(f, density)); break;
                case "paddingVertical":    if (f != null) y.setPadding(YogaEdge.VERTICAL, dp(f, density)); break;
                case "margin":             if (f != null) y.setMargin(YogaEdge.ALL, dp(f, density)); break;
                case "marginTop":          if (f != null) y.setMargin(YogaEdge.TOP, dp(f, density)); break;
                case "marginBottom":       if (f != null) y.setMargin(YogaEdge.BOTTOM, dp(f, density)); break;
                case "marginLeft":         if (f != null) y.setMargin(YogaEdge.LEFT, dp(f, density)); break;
                case "marginRight":        if (f != null) y.setMargin(YogaEdge.RIGHT, dp(f, density)); break;
                case "marginHorizontal":   if (f != null) y.setMargin(YogaEdge.HORIZONTAL, dp(f, density)); break;
                case "marginVertical":     if (f != null) y.setMargin(YogaEdge.VERTICAL, dp(f, density)); break;
                case "top":    if (f != null) y.setPosition(YogaEdge.TOP, dp(f, density)); break;
                case "bottom": if (f != null) y.setPosition(YogaEdge.BOTTOM, dp(f, density)); break;
                case "left":   if (f != null) y.setPosition(YogaEdge.LEFT, dp(f, density)); break;
                case "right":  if (f != null) y.setPosition(YogaEdge.RIGHT, dp(f, density)); break;
                case "position":
                    y.setPositionType("absolute".equals(s) ? YogaPositionType.ABSOLUTE : YogaPositionType.RELATIVE);
                    break;
                case "flexDirection":
                    y.setFlexDirection("row".equals(s) ? YogaFlexDirection.ROW
                        : "row-reverse".equals(s) ? YogaFlexDirection.ROW_REVERSE
                        : "column-reverse".equals(s) ? YogaFlexDirection.COLUMN_REVERSE
                        : YogaFlexDirection.COLUMN);
                    break;
                case "justifyContent": y.setJustifyContent(justify(s)); break;
                case "alignItems":     y.setAlignItems(align(s)); break;
                case "alignSelf":      y.setAlignSelf(align(s)); break;
                case "aspectRatio":    if (f != null) y.setAspectRatio(f); break;
                case "display":        y.setDisplay("none".equals(s) ? YogaDisplay.NONE : YogaDisplay.FLEX); break;
                default: break; // non-geometric keys (color/opacity/border) are asserted in the runners.
            }
        }
    }

    private void setDim(YogaNode y, String s, Float f, double density, boolean width) {
        if (s != null && s.endsWith("%")) {
            Float p = asFloat(s.substring(0, s.length() - 1));
            if (p != null) { if (width) y.setWidthPercent(p); else y.setHeightPercent(p); }
        } else if ("auto".equals(s)) {
            if (width) y.setWidthAuto(); else y.setHeightAuto();
        } else if (f != null) {
            if (width) y.setWidth(dp(f, density)); else y.setHeight(dp(f, density));
        }
    }

    private YogaJustify justify(String s) {
        if ("center".equals(s)) return YogaJustify.CENTER;
        if ("flex-end".equals(s)) return YogaJustify.FLEX_END;
        if ("space-between".equals(s)) return YogaJustify.SPACE_BETWEEN;
        if ("space-around".equals(s)) return YogaJustify.SPACE_AROUND;
        if ("space-evenly".equals(s)) return YogaJustify.SPACE_EVENLY;
        return YogaJustify.FLEX_START;
    }

    private YogaAlign align(String s) {
        if ("center".equals(s)) return YogaAlign.CENTER;
        if ("flex-start".equals(s)) return YogaAlign.FLEX_START;
        if ("flex-end".equals(s)) return YogaAlign.FLEX_END;
        if ("stretch".equals(s)) return YogaAlign.STRETCH;
        if ("baseline".equals(s)) return YogaAlign.BASELINE;
        return YogaAlign.AUTO;
    }

    // ---- comparison ----------------------------------------------------------------------

    private void check(List<String> failures, String id, double density, String path,
                       String field, float got, double expect) {
        if (Math.abs(got - expect) > TOL) {
            failures.add(id + " @density " + density + " " + path + ": " + field
                    + " expected " + expect + " but real Yoga computed " + got + " (logical units)");
        }
    }
}
