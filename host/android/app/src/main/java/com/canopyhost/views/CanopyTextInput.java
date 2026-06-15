// CanopyTextInput.java — a real TextInput (RCTSinglelineTextInputView).
//
// Today the host creates a bare EditText and wires NOTHING (no text/focus/submit listeners,
// no placeholder/keyboard/secure handling). This wires the RN contract: a CONTROLLED input
// (the `value` prop is the source of truth) that emits changeText/submitEditing/focus/blur,
// with an echo-guard so a programmatic value-set never re-fires changeText into update (which
// would fight the user's cursor).

package com.canopyhost.views;

import android.content.Context;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.KeyEvent;
import android.view.inputmethod.EditorInfo;
import android.widget.EditText;

import com.canopyhost.CanopyHostJni;

public final class CanopyTextInput extends EditText {

  private int viewHandle = -1;
  private boolean suppressWatcher = false;
  private boolean emitChange = false, emitSubmit = false, emitFocus = false, emitBlur = false;

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

  /** Controlled value: set only when different, keep the cursor at the end, suppress the echo. */
  public void setValueControlled(String value) {
    String v = value == null ? "" : value;
    if (v.equals(getText().toString())) return;
    suppressWatcher = true;
    setText(v);
    setSelection(v.length());
    suppressWatcher = false;
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
