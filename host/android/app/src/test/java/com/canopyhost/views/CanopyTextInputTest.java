// CanopyTextInputTest.java — JVM unit test (Robolectric) for AND-5 controlled-input parity.
//
// The substance of AND-5 is the CARET: a controlled `value` re-render must NOT slam the cursor to
// the end on every keystroke (the famous RN mid-string-edit bug). setValueControlled diffs old/new
// and remaps the selection, which is pure String/selection math — perfectly unit-testable under
// Robolectric (a real android.widget.EditText, no emulator). We pin:
//
//   (a) mapCaret() — the prefix/suffix diff that maps a prior caret offset into the new text, for
//       every edit shape: append, mid-string insert, mid-string delete, prefix insert, full replace.
//   (b) setValueControlled() on a real EditText — the caret lands where mapCaret says after the set,
//       and an unchanged value is a no-op (no spurious selection move).
//   (c) the new controlled props — maxLength filter + truncation, explicit selection, autoCapitalize
//       cap-flag bits, returnKeyType → IME action — exercised against the real widget state.
//
// Runs on the host JVM via `:app:testDebugUnitTest` (the AND-4 command test's discipline). Selection
// math is exact and density-free, so this is the device-free regression gate for the caret contract;
// the on-device IME/keyboard half is covered by CanopyFixtureUiTest.

package com.canopyhost.views;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import android.text.InputType;
import android.view.inputmethod.EditorInfo;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;

@RunWith(RobolectricTestRunner.class)
public final class CanopyTextInputTest {

  private CanopyTextInput make() {
    return new CanopyTextInput(RuntimeEnvironment.getApplication());
  }

  // ---- (a) mapCaret: the pure prefix/suffix diff ----------------------------------------------

  // Append at the end: a caret before the appended char is untouched; at the end it advances.
  @Test
  public void mapCaret_appendKeepsEarlierCaretAndAdvancesEndCaret() {
    // "abc" -> "abcd": caret 1 stays 1; caret 3 (end) -> 4
    assertEquals(1, CanopyTextInput.mapCaret("abc", "abcd", 1));
    assertEquals(4, CanopyTextInput.mapCaret("abc", "abcd", 3));
  }

  // THE core bug: insert in the MIDDLE. "abc" with caret after "ab" (offset 2) typing 'X' -> "abXc".
  // The caret must land at 3 (after the X), NOT at 4 (the end). This is the regression AND-5 fixes.
  @Test
  public void mapCaret_midStringInsertDoesNotJumpToEnd() {
    assertEquals(3, CanopyTextInput.mapCaret("abc", "abXc", 2));
    // a caret in the untouched suffix ("c") shifts by the +1 length delta: old 3 -> new 4
    assertEquals(4, CanopyTextInput.mapCaret("abc", "abXc", 3));
    // a caret in the untouched prefix is unchanged
    assertEquals(1, CanopyTextInput.mapCaret("abc", "abXc", 1));
  }

  // Mid-string DELETE: "abXc" -> "abc" (delete the X at index 2). Caret 3 (after X) -> 2.
  @Test
  public void mapCaret_midStringDeleteMovesCaretToEditPoint() {
    assertEquals(2, CanopyTextInput.mapCaret("abXc", "abc", 3));
    // caret in the suffix ("c") shifts by the -1 delta: old 4 -> new 3
    assertEquals(3, CanopyTextInput.mapCaret("abXc", "abc", 4));
  }

  // Insert at the PREFIX (offset 0): a caret sitting AT the insertion point follows the inserted
  // text (the consistent "cursor at the edit point advances" rule that also drives the append case),
  // and a caret already past the insertion shifts by the +1 delta.
  @Test
  public void mapCaret_prefixInsertAdvancesCaretAtEditPoint() {
    // "bc" -> "abc": caret 0 (at the insert point) -> 1 (after the inserted "a"); caret 1 -> 2
    assertEquals(1, CanopyTextInput.mapCaret("bc", "abc", 0));
    assertEquals(2, CanopyTextInput.mapCaret("bc", "abc", 1));
  }

  // A full replace with no common affixes anchors the caret to the end of the new text.
  @Test
  public void mapCaret_fullReplaceAnchorsToNewEnd() {
    // "abc" -> "xyz": caret 2 was inside the replaced run → end of new replacement (3)
    assertEquals(3, CanopyTextInput.mapCaret("abc", "xyz", 2));
  }

  // A caret of -1 (no active selection) defaults to the new end (RN's fresh-set behaviour).
  @Test
  public void mapCaret_noSelectionGoesToEnd() {
    assertEquals(5, CanopyTextInput.mapCaret("abc", "hello", -1));
  }

  // ---- (b) setValueControlled on a real EditText ----------------------------------------------

  // The end-to-end caret contract on a live widget: place the cursor mid-string, push a controlled
  // value that inserts a char at the cursor, and assert the cursor advanced by one — not to the end.
  @Test
  public void setValueControlled_preservesMidStringCaret() {
    CanopyTextInput ti = make();
    ti.setEmit(true, false, false, false);
    ti.setValueControlled("abc");
    ti.setSelection(2);                 // cursor between "ab" and "c"
    ti.setValueControlled("abXc");      // the model echoes the inserted char
    assertEquals("abXc", ti.getText().toString());
    assertEquals("caret advances past the insert, not to the end", 3, ti.getSelectionStart());
    assertEquals(3, ti.getSelectionEnd());
  }

  // An unchanged controlled value is a no-op: it must NOT move the caret (the echo-guard early-out).
  @Test
  public void setValueControlled_unchangedIsNoOpForCaret() {
    CanopyTextInput ti = make();
    ti.setValueControlled("hello");
    ti.setSelection(2);
    ti.setValueControlled("hello");     // same value → early return
    assertEquals(2, ti.getSelectionStart());
  }

  // Appending to the end keeps the caret at the end (the common typing-at-end case still works).
  @Test
  public void setValueControlled_appendKeepsEndCaret() {
    CanopyTextInput ti = make();
    ti.setValueControlled("ab");
    ti.setSelection(2);                 // caret at end
    ti.setValueControlled("abc");
    assertEquals(3, ti.getSelectionStart());
  }

  // ---- (c) the new controlled props -----------------------------------------------------------

  // maxLength installs a LengthFilter and truncates over-length existing text on set.
  @Test
  public void maxLength_installsFilterAndTruncates() {
    CanopyTextInput ti = make();
    ti.setValueControlled("abcdef");
    ti.setMaxLengthControlled(3);
    assertEquals("abc", ti.getText().toString());
    // the filter rejects further typing past the cap
    ti.append("xyz");
    assertEquals("abc", ti.getText().toString());
  }

  // A maxLength of -1 removes the cap (and any prior LengthFilter).
  @Test
  public void maxLength_negativeRemovesCap() {
    CanopyTextInput ti = make();
    ti.setMaxLengthControlled(2);
    ti.setMaxLengthControlled(-1);
    ti.setValueControlled("longvalue");
    assertEquals("longvalue", ti.getText().toString());
  }

  // Explicit controlled selection clamps into the current text and orders start<=end.
  @Test
  public void selectionControlled_clampsAndOrders() {
    CanopyTextInput ti = make();
    ti.setValueControlled("hello");
    ti.setSelectionControlled(4, 1);                 // reversed → normalised to (1,4)
    assertEquals(1, ti.getSelectionStart());
    assertEquals(4, ti.getSelectionEnd());
    ti.setSelectionControlled(0, 100);               // end past length → clamped to 5
    assertEquals(5, ti.getSelectionEnd());
  }

  // autoCapitalize=characters sets the CAP_CHARACTERS flag without dropping the base text class.
  @Test
  public void autoCapitalize_setsCapFlagOnBaseType() {
    CanopyTextInput ti = make();
    ti.setInputType(InputType.TYPE_CLASS_TEXT);
    ti.setAutoCapitalizeControlled("characters");
    assertTrue((ti.getInputType() & InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS) != 0);
    assertTrue((ti.getInputType() & InputType.TYPE_CLASS_TEXT) != 0);
    // switching to "none" clears the cap flag again
    ti.setAutoCapitalizeControlled("none");
    assertFalse((ti.getInputType() & InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS) != 0);
  }

  // returnKeyType maps to the matching IME action in imeOptions.
  @Test
  public void returnKeyType_mapsToImeAction() {
    CanopyTextInput ti = make();
    ti.setReturnKeyTypeControlled("search");
    assertEquals(EditorInfo.IME_ACTION_SEARCH, ti.getImeOptions() & EditorInfo.IME_MASK_ACTION);
    ti.setReturnKeyTypeControlled("send");
    assertEquals(EditorInfo.IME_ACTION_SEND, ti.getImeOptions() & EditorInfo.IME_MASK_ACTION);
  }
}
