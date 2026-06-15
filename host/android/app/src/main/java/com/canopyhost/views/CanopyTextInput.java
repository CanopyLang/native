// CanopyTextInput.java — a real TextInput (RCTSinglelineTextInputView).
//
// A CONTROLLED input: the `value` prop is the source of truth. It emits changeText/submitEditing/
// focus/blur, with an echo-guard so a programmatic value-set never re-fires changeText into update
// (which would fight the user's cursor).
//
// AND-5 — controlled-input parity. The hard problem a real form hits is the CARET. RN's bug here is
// famous: a controlled `setText` that naively `setSelection(end)` slams the cursor to the end of the
// field on every keystroke, so editing in the middle of a string is impossible (you type one char,
// the model round-trips a new `value`, and the cursor jumps past the rest of your text). The fix is
// to DIFF the old and new text and restore the caret RELATIVE to the change — exactly what RN's
// ReactEditText.maybeSetTextWithSelection does. setValueControlled below implements that diff:
//   • common prefix length p, common suffix length s (non-overlapping) between old and new;
//   • the changed span is [p, len-s); a caret at offset c in the OLD string maps to:
//       c <= p           → c                       (before the edit — unchanged)
//       c >= oldLen - s  → c + (newLen - oldLen)    (after the edit — shift by the length delta)
//       otherwise        → clamp into the new changed span (caret was inside the replaced run)
// This keeps mid-string edits stable: typing 'X' into "ab|c" yields "abX|c", not "abXc|".
//
// AND-5 also wires the remaining controlled props the platform exposes as InputFilters / IME flags /
// EditText knobs but that the value/keyboard path did not cover: maxLength, returnKeyType,
// autoCapitalize, and an explicit controlled `selection` ({start,end}). Multiline height growth is
// handled by the host (it dirties the Yoga leaf on a value change so the measure function re-runs).

package com.canopyhost.views;

import android.content.Context;
import android.text.Editable;
import android.text.InputFilter;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.KeyEvent;
import android.view.inputmethod.EditorInfo;
import android.widget.EditText;

import com.canopyhost.CanopyHostJni;

public final class CanopyTextInput extends EditText {

  private int viewHandle = -1;
  private boolean suppressWatcher = false;
  private boolean emitChange = false, emitSubmit = false, emitFocus = false, emitBlur = false;
  private int maxLength = -1;  // -1 = unbounded (no length filter installed)

  public CanopyTextInput(Context context) {
    super(context);
    setBackground(null);        // RN inputs carry no platform underline by default
    setPadding(0, 0, 0, 0);
    setIncludeFontPadding(false);

    addTextChangedListener(new TextWatcher() {
      @Override public void beforeTextChanged(CharSequence s, int a, int b, int c) {}
      @Override public void onTextChanged(CharSequence s, int a, int b, int c) {}
      @Override public void afterTextChanged(Editable e) {
        if (suppressWatcher || !emitChange || viewHandle < 0) return;
        CanopyHostJni.emitEvent(viewHandle, "changeText", "{\"text\":" + jsonStr(e.toString()) + "}");
      }
    });

    setOnEditorActionListener((v, actionId, ev) -> {
      boolean isSubmit = actionId == EditorInfo.IME_ACTION_DONE
          || actionId == EditorInfo.IME_ACTION_GO
          || actionId == EditorInfo.IME_ACTION_SEND
          || actionId == EditorInfo.IME_ACTION_SEARCH
          || actionId == EditorInfo.IME_ACTION_NEXT
          || (ev != null && ev.getKeyCode() == KeyEvent.KEYCODE_ENTER);
      if (isSubmit && emitSubmit && viewHandle >= 0) {
        CanopyHostJni.emitEvent(viewHandle, "submitEditing", "{\"text\":" + jsonStr(getText().toString()) + "}");
      }
      return false; // let the IME also act (close keyboard, etc.)
    });

    setOnFocusChangeListener((v, has) -> {
      if (viewHandle < 0) return;
      if (has && emitFocus) CanopyHostJni.emitEvent(viewHandle, "focus", "{}");
      else if (!has && emitBlur) CanopyHostJni.emitEvent(viewHandle, "blur", "{}");
    });
  }

  public void setViewHandle(int h) { this.viewHandle = h; }

  public void setEmit(boolean change, boolean submit, boolean focus, boolean blur) {
    emitChange = change; emitSubmit = submit; emitFocus = focus; emitBlur = blur;
  }

  /**
   * Controlled value with CARET PRESERVATION. Sets the text only when it differs, then restores the
   * selection by mapping the prior caret through the prefix/suffix diff (so a mid-string edit does
   * NOT jump the cursor to the end). The echo is suppressed so this programmatic set never re-fires
   * changeText back into the model. Pure String/selection math — no platform IME dependency — which
   * is exactly why it is unit-testable under Robolectric without an emulator.
   */
  public void setValueControlled(String value) {
    String next = value == null ? "" : value;
    String prev = getText().toString();
    if (next.equals(prev)) return;

    int selStart = getSelectionStart();
    int selEnd = getSelectionEnd();

    suppressWatcher = true;
    setText(next);
    // Map both ends of the prior selection through the diff and clamp into the new text.
    int newLen = next.length();
    int mappedStart = clamp(mapCaret(prev, next, selStart), 0, newLen);
    int mappedEnd = clamp(mapCaret(prev, next, selEnd), 0, newLen);
    if (mappedStart > mappedEnd) { int t = mappedStart; mappedStart = mappedEnd; mappedEnd = t; }
    setSelection(mappedStart, mappedEnd);
    suppressWatcher = false;
  }

  /**
   * Map a caret offset in `prev` to the equivalent offset in `next`, given they differ by a single
   * contiguous replaced span (the common case for a controlled re-render: one keystroke, paste, or
   * deletion). Computes the common prefix length p and common suffix length s (non-overlapping),
   * then, with the replaced OLD span = [p, prevLen - s):
   *   caret < p                  → caret                      (strictly before the change)
   *   caret > prevLen - s        → caret + (nextLen - prevLen) (strictly after the change)
   *   caret inside [p, prevLen-s] → anchor to the end of the NEW replacement span (nextLen - s),
   *                                 so a cursor sitting AT the edit point follows the inserted text.
   * The boundary cases (caret == p or caret == prevLen - s) deliberately fall into the third branch:
   * for a pure insertion the old span is empty ([p, p)) and a caret at p maps to nextLen - s = p +
   * (inserted length) — the cursor advances past what was just typed (the append / mid-insert case),
   * which is exactly the RN behaviour. A caret of -1 (no selection) maps to the new end.
   */
  static int mapCaret(String prev, String next, int caret) {
    if (caret < 0) return next.length();
    int prevLen = prev.length();
    int nextLen = next.length();

    int p = 0;
    int maxPrefix = Math.min(prevLen, nextLen);
    while (p < maxPrefix && prev.charAt(p) == next.charAt(p)) p++;

    int s = 0;
    // suffix may not overlap the prefix on either string
    int maxSuffix = Math.min(prevLen - p, nextLen - p);
    while (s < maxSuffix && prev.charAt(prevLen - 1 - s) == next.charAt(nextLen - 1 - s)) s++;

    int delta = nextLen - prevLen;
    int oldSpanEnd = prevLen - s;                       // end (exclusive) of the replaced OLD span
    if (caret < p) return caret;                        // strictly before the change → unchanged
    if (caret > oldSpanEnd) return caret + delta;       // strictly after the change → shift by delta
    // at-or-inside the replaced run → anchor to the end of the NEW replacement span
    return nextLen - s;
  }

  private static int clamp(int v, int lo, int hi) {
    return v < lo ? lo : (v > hi ? hi : v);
  }

  /** Explicit controlled selection (RN's `selection={{start,end}}`). Clamped to the current text. */
  public void setSelectionControlled(int start, int end) {
    int len = getText().length();
    int a = clamp(start, 0, len);
    int b = clamp(end < 0 ? start : end, 0, len);
    if (a > b) { int t = a; a = b; b = t; }
    setSelection(a, b);
  }

  /**
   * maxLength: install (or remove) a LengthFilter, preserving any other filters already set (e.g. an
   * all-caps filter from autoCapitalize=characters). A negative/zero-or-absent max removes the cap.
   */
  public void setMaxLengthControlled(int max) {
    if (max == this.maxLength) return;
    this.maxLength = max;
    InputFilter[] cur = getFilters();
    java.util.ArrayList<InputFilter> kept = new java.util.ArrayList<>();
    for (InputFilter f : cur) { if (!(f instanceof InputFilter.LengthFilter)) kept.add(f); }
    if (max > 0) kept.add(new InputFilter.LengthFilter(max));
    setFilters(kept.toArray(new InputFilter[0]));
    // Truncate existing over-length text to honour the new cap immediately (RN does this on set).
    if (max > 0 && getText().length() > max) {
      suppressWatcher = true;
      setText(getText().subSequence(0, max));
      setSelection(getText().length());
      suppressWatcher = false;
    }
  }

  /**
   * returnKeyType → IME action button. Maps RN's returnKeyType strings to EditorInfo.IME_ACTION_*,
   * preserving the no-extract-UI flag RN uses so the action button shows in landscape.
   */
  public void setReturnKeyTypeControlled(String type) {
    int action;
    switch (type == null ? "" : type) {
      case "go":     action = EditorInfo.IME_ACTION_GO; break;
      case "search": action = EditorInfo.IME_ACTION_SEARCH; break;
      case "send":   action = EditorInfo.IME_ACTION_SEND; break;
      case "next":   action = EditorInfo.IME_ACTION_NEXT; break;
      case "done":   action = EditorInfo.IME_ACTION_DONE; break;
      case "previous": action = EditorInfo.IME_ACTION_PREVIOUS; break;
      default:       action = EditorInfo.IME_ACTION_DONE; break;
    }
    setImeOptions(action | EditorInfo.IME_FLAG_NO_EXTRACT_UI);
  }

  /**
   * autoCapitalize → the TYPE_TEXT_FLAG_CAP_* input-type bits. Must be OR'd onto the existing base
   * input type (set by keyboardType/secure/multiline), so the host calls this AFTER it computes the
   * base; we read the current input type, clear the three cap flags, and set the requested one.
   */
  public void setAutoCapitalizeControlled(String mode) {
    int type = getInputType();
    type &= ~(InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS
            | InputType.TYPE_TEXT_FLAG_CAP_WORDS
            | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
    switch (mode == null ? "" : mode) {
      case "characters": type |= InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS; break;
      case "words":      type |= InputType.TYPE_TEXT_FLAG_CAP_WORDS; break;
      case "sentences":  type |= InputType.TYPE_TEXT_FLAG_CAP_SENTENCES; break;
      case "none": default: break; // no cap flag
    }
    int sel = getSelectionStart();
    setInputType(type);
    if (sel >= 0 && sel <= getText().length()) setSelection(sel); // setInputType resets the caret
  }

  private static String jsonStr(String s) {
    StringBuilder b = new StringBuilder("\"");
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      switch (c) {
        case '"':  b.append("\\\""); break;
        case '\\': b.append("\\\\"); break;
        case '\n': b.append("\\n"); break;
        case '\r': b.append("\\r"); break;
        case '\t': b.append("\\t"); break;
        default:   if (c < 0x20) b.append(String.format("\\u%04x", (int) c)); else b.append(c);
      }
    }
    return b.append('"').toString();
  }
}
