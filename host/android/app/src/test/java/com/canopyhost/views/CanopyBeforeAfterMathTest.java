// CanopyBeforeAfterMathTest.java — L-I4: the Android leg of the SHARED before/after wipe-compositor
// parity test-vector suite.
//
// This runs the SAME corpus the iOS XCTest runner (CanopyBeforeAfterVectorTests.mm) runs:
// host/shared/test-vectors/beforeafter-vectors.json — the SINGLE source of truth — against the REAL
// production Android compositor math. BeforeAfterView.java delegates every numeric rule to
// CanopyBeforeAfterMath (the line-for-line Android twin of host/shared/cpp/CanopyBeforeAfter.h, which
// the iOS view delegates to), so asserting CanopyBeforeAfterMath here is asserting exactly what ships.
// Together with the iOS runner this is the durable anti-drift control (master plan R5) for the wipe
// compositor: a vector green on one host and red on the other is the silent divergence the suite catches.
//
// It is a pure JVM unit test (no emulator, no Robolectric Android API needed) — the compositor math is
// platform-neutral arithmetic + a %g formatter, so it runs under `:app:testDebugUnitTest`, fast, on
// the build host. (Robolectric is on the classpath, which brings org.json for parsing the corpus.) The
// on-device draw/gesture behaviour is exercised by CanopyFixtureUiTest / CanopyHostUITests; the
// platform-neutral MATH is exercised here, where it is exact and density-free.
//
// Unlike the IOS-9 layout corpus there is NO density term: the wipe is a FRACTION of the view, never a
// dp, so the math is unit-agnostic and the SAME unitless fractions validate both hosts. The corpus is
// the canonical file read straight from host/shared/test-vectors/ (no second copy to drift); the
// device-free oracle host/shared/test-vectors/validate-beforeafter.js + scripts/check-beforeafter-parity.sh
// guard it on Linux every commit.

package com.canopyhost.views;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

// Robolectric runner so the REAL org.json (parsing the corpus) is on the classpath — without it the
// stubbed Android org.json on the unit-test classpath returns null/throws "Stub!". The math under test
// is pure Java (no Android API), but the corpus reader needs a working JSON parser, exactly like the
// other org.json-using JVM tests (CanopyScrollViewTest, CanopyHostCommandTest).
@RunWith(RobolectricTestRunner.class)
public class CanopyBeforeAfterMathTest {

  private static final double TOL_DEFAULT = 0.0001;

  // Read the CANONICAL corpus straight from host/shared/test-vectors/ (the ONE source of truth — no
  // second copy to drift). Gradle runs unit tests with the working dir at the module (host/android/app);
  // walk up to the repo root and resolve the shared path. A couple of fallbacks keep the suite from
  // silently becoming vacuous if the working dir differs.
  private JSONObject corpus() throws Exception {
    String[] candidates = {
        "../../host/shared/test-vectors/beforeafter-vectors.json",          // cwd = host/android/app
        "../../../host/shared/test-vectors/beforeafter-vectors.json",
        "host/shared/test-vectors/beforeafter-vectors.json",               // cwd = repo root
    };
    File found = null;
    for (String c : candidates) {
      File f = new File(c).getCanonicalFile();
      if (f.exists()) { found = f; break; }
    }
    assertNotNull("beforeafter-vectors.json must be findable from the module working dir "
        + "(cwd=" + new File(".").getCanonicalPath() + ")", found);
    String json = new String(Files.readAllBytes(found.toPath()), StandardCharsets.UTF_8);
    return new JSONObject(json);
  }

  private double tol(JSONObject c) { return c.optDouble("tolerance", TOL_DEFAULT); }

  @Test
  public void clampVectorsMatch() throws Exception {
    JSONObject c = corpus();
    JSONArray vecs = c.getJSONArray("clampVectors");
    assertTrue("clampVectors required", vecs.length() > 0);
    for (int i = 0; i < vecs.length(); i++) {
      JSONObject v = vecs.getJSONObject(i);
      double got = CanopyBeforeAfterMath.clampFraction(v.getDouble("input"));
      assertEquals(v.getString("id") + ": clampFraction", v.getDouble("expect"), got, tol(c));
    }
  }

  @Test
  public void splitVectorsMatch() throws Exception {
    JSONObject c = corpus();
    JSONArray vecs = c.getJSONArray("splitVectors");
    assertTrue("splitVectors required", vecs.length() > 0);
    for (int i = 0; i < vecs.length(); i++) {
      JSONObject v = vecs.getJSONObject(i);
      int got = CanopyBeforeAfterMath.splitColumn(v.getDouble("wipe"), v.getDouble("width"));
      assertEquals(v.getString("id") + ": splitColumn (clip/mask boundary)", v.getInt("expect"), got);
    }
  }

  @Test
  public void dragVectorsMatch() throws Exception {
    JSONObject c = corpus();
    JSONArray vecs = c.getJSONArray("dragVectors");
    assertTrue("dragVectors required", vecs.length() > 0);
    for (int i = 0; i < vecs.length(); i++) {
      JSONObject v = vecs.getJSONObject(i);
      double got = CanopyBeforeAfterMath.dragFraction(v.getDouble("x"), v.getDouble("width"));
      assertEquals(v.getString("id") + ": dragFraction", v.getDouble("expect"), got, tol(c));
    }
  }

  @Test
  public void snapTargetVectorsMatch() throws Exception {
    JSONObject c = corpus();
    JSONArray vecs = c.getJSONArray("snapTargetVectors");
    assertTrue("snapTargetVectors required", vecs.length() > 0);
    for (int i = 0; i < vecs.length(); i++) {
      JSONObject v = vecs.getJSONObject(i);
      double got = CanopyBeforeAfterMath.snapTarget(v.getDouble("wipe"));
      assertEquals(v.getString("id") + ": snapTarget", v.getDouble("expect"), got, 0.0);
    }
  }

  @Test
  public void snapEasedVectorsMatch() throws Exception {
    JSONObject c = corpus();
    JSONArray vecs = c.getJSONArray("snapEasedVectors");
    assertTrue("snapEasedVectors required", vecs.length() > 0);
    for (int i = 0; i < vecs.length(); i++) {
      JSONObject v = vecs.getJSONObject(i);
      double got = CanopyBeforeAfterMath.snapEased(v.getDouble("t"));
      assertEquals(v.getString("id") + ": snapEased (decelerate)", v.getDouble("expect"), got, tol(c));
    }
  }

  @Test
  public void snapTweenVectorsMatch() throws Exception {
    JSONObject c = corpus();
    double dur = c.optDouble("snapDurationSeconds", CanopyBeforeAfterMath.SNAP_DURATION_SECONDS);
    JSONArray vecs = c.getJSONArray("snapTweenVectors");
    assertTrue("snapTweenVectors required", vecs.length() > 0);
    for (int i = 0; i < vecs.length(); i++) {
      JSONObject v = vecs.getJSONObject(i);
      double got = CanopyBeforeAfterMath.snapValue(
          v.getDouble("from"), v.getDouble("to"), v.getDouble("elapsed"), dur);
      assertEquals(v.getString("id") + ": snapValue (tween)", v.getDouble("expect"), got, tol(c));
    }
    // The corpus's declared duration must equal the shared constant the host actually tweens over.
    assertEquals("corpus snapDurationSeconds must match the host snap duration",
        CanopyBeforeAfterMath.SNAP_DURATION_SECONDS, dur, 1e-9);
  }

  @Test
  public void coverVectorsMatch() throws Exception {
    JSONObject c = corpus();
    JSONArray vecs = c.getJSONArray("coverVectors");
    assertTrue("coverVectors required", vecs.length() > 0);
    for (int i = 0; i < vecs.length(); i++) {
      JSONObject v = vecs.getJSONObject(i);
      float[] r = CanopyBeforeAfterMath.coverRect(
          v.getDouble("viewW"), v.getDouble("viewH"), v.getDouble("bmpW"), v.getDouble("bmpH"));
      JSONObject e = v.getJSONObject("expect");
      String id = v.getString("id");
      assertEquals(id + ": cover left", e.getDouble("left"), r[0], tol(c));
      assertEquals(id + ": cover top", e.getDouble("top"), r[1], tol(c));
      assertEquals(id + ": cover width", e.getDouble("width"), r[2], tol(c));
      assertEquals(id + ": cover height", e.getDouble("height"), r[3], tol(c));
    }
  }

  // The wipeCommit payload is the wire-format leg — the EXACT bytes that cross into Canopy. This is the
  // piece that previously drifted (Java Float.toString here vs C printf %g on iOS); the shared formatter
  // removes that gap and this pins the bytes byte-for-byte against the corpus.
  @Test
  public void payloadVectorsMatch() throws Exception {
    JSONObject c = corpus();
    JSONArray vecs = c.getJSONArray("payloadVectors");
    assertTrue("payloadVectors required", vecs.length() > 0);
    for (int i = 0; i < vecs.length(); i++) {
      JSONObject v = vecs.getJSONObject(i);
      String got = CanopyBeforeAfterMath.commitPayloadJson(v.getDouble("fraction"));
      assertEquals(v.getString("id") + ": commitPayloadJson (exact wipeCommit wire bytes)",
          v.getString("expect"), got);
      // And the payload must be JSON that decodes back to a numeric fraction (the Canopy side decodes it).
      JSONObject parsed = new JSONObject(got);
      assertTrue(v.getString("id") + ": payload carries a numeric fraction", parsed.has("fraction"));
    }
  }
}
