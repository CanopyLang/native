// CanopyHostCommandTest.java — JVM unit test for the AND-4 imperative-command JSON contract.
//
// Runs on the host JVM via `:app:testDebugUnitTest` (no device). The AND-4 command() handlers
// dispatch focus/blur/measure/scrollTo/scrollToIndex and return their result ASYNC via emitEvent
// — the device behaviours (requestFocus()+IME, getLocationInWindow, smoothScrollTo) need an
// emulator (covered by CanopyFixtureUiTest). What IS unit-testable here, device-free, is the pure
// JSON marshalling that frames every result and routes it back to the right JS callback:
//
//   (a) parseCallId() echoes the JS-supplied __callId verbatim (number / quoted string / "null").
//   (b) measureResultJson() emits the RN UIManager.measure field contract with compact numbers.
//   (c) mergeCallId() splices "__callId" as the result's first member so the walker routes by it.
//
// These three are the load-bearing seam between the Java op and the walker's callId-keyed
// _Native_dispatchCommandResult; a regression here silently mis-routes (or drops) every async
// imperative result, so they are pinned directly.

package com.canopyhost;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.json.JSONException;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public final class CanopyHostCommandTest {

  // (a) parseCallId: a numeric callId (the walker's default) echoes as a bare number literal.
  @Test
  public void parseCallId_numericEchoesAsBareNumber() throws JSONException {
    JSONObject args = new JSONObject("{\"select\":true,\"__callId\":42}");
    assertEquals("42", CanopyHost.parseCallId(args));
  }

  // A string callId echoes as a QUOTED JSON string (so the merged result stays valid JSON).
  @Test
  public void parseCallId_stringEchoesAsQuotedLiteral() throws JSONException {
    JSONObject args = new JSONObject("{\"__callId\":\"abc\"}");
    assertEquals("\"abc\"", CanopyHost.parseCallId(args));
  }

  // An absent or explicit-null __callId falls back to "null" → the walker uses its per-handle
  // one-shot (AND-3 compatibility), never throws.
  @Test
  public void parseCallId_absentOrNullIsNullLiteral() throws JSONException {
    assertEquals("null", CanopyHost.parseCallId(new JSONObject("{}")));
    assertEquals("null", CanopyHost.parseCallId(new JSONObject("{\"__callId\":null}")));
    assertEquals("null", CanopyHost.parseCallId(null));
  }

  // (b) measureResultJson: the RN measure field contract, with integers compacted (no ".0").
  @Test
  public void measureResultJson_emitsRnMeasureContract() throws JSONException {
    String json = CanopyHost.measureResultJson(4f, 8f, 100f, 40f, 12f, 200f);
    JSONObject o = new JSONObject(json); // must parse — proves it is well-formed JSON
    assertEquals(4, o.getInt("x"));
    assertEquals(8, o.getInt("y"));
    assertEquals(100, o.getInt("width"));
    assertEquals(40, o.getInt("height"));
    assertEquals(12, o.getInt("pageX"));
    assertEquals(200, o.getInt("pageY"));
    // an integral float must NOT carry a trailing ".0" (compact wire form)
    assertTrue("integral lengths are compacted", json.contains("\"width\":100") && !json.contains("100.0"));
  }

  // A fractional length is preserved (dp coordinates need not be integral on every density).
  @Test
  public void measureResultJson_keepsFractionalLengths() throws JSONException {
    String json = CanopyHost.measureResultJson(0f, 0f, 12.5f, 0f, 0f, 0f);
    JSONObject o = new JSONObject(json);
    assertEquals(12.5, o.getDouble("width"), 0.0001);
  }

  // (c) mergeCallId: "__callId" is injected as the first member, the op body spliced after it.
  @Test
  public void mergeCallId_injectsCallIdFirstAndKeepsBody() throws JSONException {
    String merged = CanopyHost.mergeCallId("7", "{\"ok\":true}");
    assertTrue("callId is the first member", merged.startsWith("{\"__callId\":7,"));
    JSONObject o = new JSONObject(merged);
    assertEquals(7, o.getInt("__callId"));
    assertTrue(o.getBoolean("ok"));
  }

  // An empty op body still yields a valid object carrying just the echoed callId.
  @Test
  public void mergeCallId_emptyBodyStillValid() throws JSONException {
    JSONObject o = new JSONObject(CanopyHost.mergeCallId("null", "{}"));
    assertTrue(o.isNull("__callId"));
    assertEquals(1, o.length());
  }

  // A measure result merged with its callId is a single well-formed object the walker can route.
  @Test
  public void mergeCallId_overMeasureResultRoundTrips() throws JSONException {
    String body = CanopyHost.measureResultJson(1f, 2f, 3f, 4f, 5f, 6f);
    JSONObject o = new JSONObject(CanopyHost.mergeCallId("99", body));
    assertEquals(99, o.getInt("__callId"));
    assertEquals(3, o.getInt("width"));
    assertEquals(6, o.getInt("pageY"));
  }
}
