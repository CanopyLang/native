// CanopyHost.java — Android implementation of the canopy/native mount surface.
//
// Backs the __fabric_* surface (driven by external/native.js) with real android.view
// views laid out by Facebook Yoga (com.facebook.yoga.*). The "direct views + Yoga" host.
//
// LAYOUT MODEL (the C2 render-fidelity fix): every CONTAINER is a custom ViewGroup
// (YogaViewGroup) that drives layout from Yoga — the root runs calculateLayout() during the
// real Android measure pass (so it gets the true screen size, not a 0x0 surface), and each
// container measures + positions its direct children from their Yoga frames. LEAF views
// (Text/Image/Input) carry a Yoga measure function so text/intrinsic sizing is correct.
// This replaces the old approach (raw view.layout() into stock FrameLayouts), whose frames
// were immediately overwritten by the parent's own layout pass — the cause of the
// "text invisible / button bg fills the screen" bug.
//
// Dimensions in Canopy style are density-independent (dp-ish, like React Native); Yoga here
// computes in physical pixels, so dimensional inputs are scaled by display density.

package com.canopyhost;

import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.ProgressBar;
import android.widget.TextView;

import com.facebook.yoga.YogaAlign;
import com.facebook.yoga.YogaConstants;
import com.facebook.yoga.YogaDirection;
import com.facebook.yoga.YogaDisplay;
import com.facebook.yoga.YogaEdge;
import com.facebook.yoga.YogaFlexDirection;
import com.facebook.yoga.YogaGutter;
import com.facebook.yoga.YogaJustify;
import com.facebook.yoga.YogaMeasureFunction;
import com.facebook.yoga.YogaMeasureMode;
import com.facebook.yoga.YogaMeasureOutput;
import com.facebook.yoga.YogaNode;
import com.facebook.yoga.YogaNodeFactory;
import com.facebook.yoga.YogaPositionType;
import com.facebook.yoga.YogaWrap;

import org.json.JSONObject;

import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Map;
import java.util.Set;

/** Real-view + Yoga implementation of the canopy/native host. */
public final class CanopyHost {

  static final class CView {
    View view;
    YogaNode yoga;
    String fabricName;
    boolean isLeaf;
    int textColor = Color.BLACK;
    Integer bgColor = null;
    float borderRadius = 0f;
    // Border stroke + per-corner radii (paint, via the GradientDrawable background). corners is
    // null unless a per-corner radius is set, in which case it overrides the uniform borderRadius.
    Integer borderColor = null;
    float borderWidth = 0f;
    float[] corners = null; // [topLeft, topRight, bottomRight, bottomLeft] in px
    // Accessibility + test identity (T0): the single selector contract for Appium/Maestro/
    // TalkBack. testID becomes the View content-description (Appium `~testID`); a label, when
    // present, overrides it for what TalkBack speaks. role/hint ride an AccessibilityDelegate.
    String testID = null, a11yLabel = null, a11yRole = null, a11yHint = null;
    boolean a11yDelegateInstalled = false;
    // For RCTScrollView: children mount into a SEPARATE inner Yoga content root (its own
    // calculateLayout) measured with an unbounded scroll axis; the ScrollView clips/scrolls it.
    YogaViewGroup contentView = null;
    YogaNode contentYoga = null;
    // For RCTImageView declarative `source`: the last URI loaded, so a re-render with an
    // unchanged source does not re-fetch, and a recycled view drops a stale async result.
    String lastSource = null;
    // RCTImageView: the placeholder/fallback URI shown while `source` loads (and on error), the
    // per-request HTTP headers (JSON object, e.g. an auth bearer), and the set of native event
    // names the app currently subscribes to ("load"/"error"/"loadEnd") so the async callback only
    // emits what JS listens for. Re-set on every __events diff (recycled-view discipline).
    String defaultSource = null;
    java.util.Map<String, String> imageHeaders = null;
    String lastDefaultSource = null;
    final java.util.Set<String> subscribedEvents = new java.util.HashSet<>();
    // The last STATIC opacity/transform from style — cached even while an animation owns the
    // property, so clearing the animation (whose diff carries no `style` key) can restore them.
    float baseOpacity = 1f;
    String baseTransform = null;
  }

  private final Context context;
  private final ViewGroup surface;
  private final Map<Integer, CView> views = new HashMap<>();
  private final float density;
  private final com.canopyhost.views.CanopyAnimDriver animDriver;
  private int next = 1;
  private int root = -1;

  public CanopyHost(Context context, ViewGroup surface) {
    this.context = context;
    this.surface = surface;
    this.density = context.getResources().getDisplayMetrics().density;
    // The single Choreographer-driven Animation engine: animates compositor props by handle,
    // emits coarse start/end edges. UI-thread-only, like all of applyProps.
    this.animDriver = new com.canopyhost.views.CanopyAnimDriver(
        CanopyHostJni::emitEvent,
        h -> { CView c = views.get(h); return c != null ? c.view : null; },
        density);
  }

  // ---- DEV-4 in-process reload entry ----------------------------------------
  // The Android counterpart of the iOS dev loop: re-evaluate a new bundle on the SAME Hermes
  // runtime and re-boot onto the SAME cached root, preserving BOTH the host view tree (the surface
  // + root view are untouched; only the program's mounted subtree is rebuilt) and the user's TEA
  // model (captured before the eval, restored after the re-boot). Replaces the old reload = force-
  // stop + restart (multi-second, total state loss). The whole orchestration lives natively
  // (CanopyHost.nativeReload → Java_com_canopyhost_CanopyHost_nativeReload in CanopyHostJni.cpp),
  // which drives the DEV-2 reload seam (__canopy_captureState / __canopy_teardown / __canopy_remount
  // published by native.js) over the live runtime.
  //
  // THREADING: the reload MUST run on the thread that OWNS g_runtime — the main/UI thread in the
  // single-thread host, or the dedicated CanopyJS thread under RND-8 (off-UI-thread mode). We marshal
  // through CanopyHostJni.runOnRuntimeThread so a caller from any thread (a dev-loop file watcher, the
  // red-box "Reload" button) is safe in BOTH modes; the teardown/re-boot's view writes then reach the
  // UI thread the same way every frame's mutations do (the RND-8 BatchSink), so a reload needs no
  // special UI-thread plumbing of its own. RELOAD_HANDLER (the main/UI Looper) is retained for the
  // genuinely UI-thread work — the imperative command()s posted above.
  private static final Handler RELOAD_HANDLER = new Handler(Looper.getMainLooper());

  /** Re-evaluate {@code newBundleJs} on the live runtime and re-boot in place (state-preserving). */
  public void reload(final String newBundleJs) {
    if (newBundleJs == null) return;
    CanopyHostJni.runOnRuntimeThread(() -> nativeReload(newBundleJs));
  }

  /** Native half: capture model → teardown → re-eval → re-boot(cachedRoot) → remount. Static so the
   *  JNI signature is (JNIEnv*, jclass, jstring); libcanopyhost.so is already loaded by CanopyHostJni. */
  private static native void nativeReload(String newBundleJs);

  // ---- __fabric_* surface ---------------------------------------------------

  public int createView(String fabricName, String propsJson) {
    return createAt(next++, fabricName, propsJson);
  }

  // RND-7 batch variant: create a view at a JS-CHOSEN handle. The batched __fabric_applyBatch path
  // allocates handles on the JS side (the walker cannot block on a host return when collapsing a
  // whole frame into one call), so the view is registered under `h` instead of a host-minted id.
  // `h` arrives from the high base the host advertised (__fabric_batchHandleBase) so it never
  // collides with the small host-minted boot-time root handle, and we DO NOT touch `next` (the
  // per-mutation path's counter), keeping the two handle spaces disjoint. Returns `h` (echoed so the
  // shared C++ marshalling has a return like createView).
  public int createViewWithHandle(int h, String fabricName, String propsJson) {
    return createAt(h, fabricName, propsJson);
  }

  private int createAt(int h, String fabricName, String propsJson) {
    CView cv = new CView();
    cv.fabricName = fabricName;
    cv.isLeaf = isLeaf(fabricName);
    cv.view = makeView(fabricName);
    if (cv.view instanceof com.canopyhost.views.BeforeAfterView) {
      ((com.canopyhost.views.BeforeAfterView) cv.view).setViewHandle(h);
    }
    if (cv.view instanceof com.canopyhost.views.CanopyTextInput) {
      ((com.canopyhost.views.CanopyTextInput) cv.view).setViewHandle(h);
    }
    if (cv.view instanceof com.canopyhost.views.CanopySwitch) {
      ((com.canopyhost.views.CanopySwitch) cv.view).setViewHandle(h);
    }
    if (cv.view instanceof com.canopyhost.views.CanopyScrollView) {
      // Build the inner Yoga content root: a YogaViewGroup (its own calculateLayout, owner==null)
      // whose natural height is measured with the scroll axis unbounded; the scroll children mount
      // into IT, not the ScrollView. The ScrollView holds it as its single child + scrolls it.
      ((com.canopyhost.views.CanopyScrollView) cv.view).setViewHandle(h);
      YogaViewGroup content = new YogaViewGroup(context);
      CView contentCv = new CView();
      contentCv.view = content;
      contentCv.yoga = YogaNodeFactory.create();
      contentCv.fabricName = "RCTScrollContent";
      content.setTag(contentCv);
      ((com.canopyhost.views.CanopyScrollView) cv.view).setContent(content); // into the inner scroller
      cv.contentView = content;
      cv.contentYoga = contentCv.yoga;
    }
    if (cv.view instanceof com.canopyhost.views.CanopyModalHost) {
      // Like the ScrollView: a SEPARATE Yoga content root (its own calculateLayout, owner==null),
      // but it lives in the modal's Dialog window. The modal's own inline node measures 0×0.
      com.canopyhost.views.CanopyModalHost mh = (com.canopyhost.views.CanopyModalHost) cv.view;
      mh.setViewHandle(h);
      YogaViewGroup content = new YogaViewGroup(context);
      CView contentCv = new CView();
      contentCv.view = content;
      contentCv.yoga = YogaNodeFactory.create();
      contentCv.fabricName = "CanopyModalContent";
      content.setTag(contentCv);
      mh.attachContent(content);
      cv.contentView = content;
      cv.contentYoga = contentCv.yoga;
    }
    cv.yoga = YogaNodeFactory.create();
    cv.yoga.setData(h);
    cv.view.setTag(cv);
    if (cv.isLeaf) {
      cv.yoga.setMeasureFunction(leafMeasure);
    }
    views.put(h, cv);
    applyProps(h, propsJson);
    return h;
  }

  public void updateProps(int h, String propsJson) {
    applyProps(h, propsJson);
    requestRelayout();
  }

  // __fabric_updatePropScalar(h, key, value) — the AND-8 single-scalar fast path. The walker
  // routes the dominant per-frame mutations (a label's text, an input/switch value, a view's
  // opacity) here so they bypass `new JSONObject(propsJson)` + the prop-by-prop scan in
  // applyProps. `value` always arrives as a plain String (a numeric opacity is stringified at the
  // JS boundary), exactly matching how applyProps already coerces everything via optString/
  // parseFloat — so this path is byte-for-byte equivalent to the JSON path it replaces, only
  // without the marshalling. NON-scalar mutations (style/object/event props, removals/null,
  // multi-key deltas) never reach here — the walker keeps them on updateProps/applyProps, whose
  // isNull reset semantics this path deliberately does NOT replicate (it only ever SETS a value).
  public void updatePropScalar(int h, String key, String value) {
    CView cv = views.get(h);
    if (cv == null || key == null) return;
    String v = value == null ? "" : value;
    switch (key) {
      case "text":
        // Mirror applyProps' text branch (TextView, not EditText): set + dirty the leaf measure.
        if (cv.view instanceof TextView && !(cv.view instanceof EditText)) {
          ((TextView) cv.view).setText(v);
          cv.yoga.dirty();
        }
        break;
      case "value":
        // Mirror applyProps' value branches: controlled TextInput value, or a Switch's checked.
        if (cv.view instanceof com.canopyhost.views.CanopyTextInput) {
          ((com.canopyhost.views.CanopyTextInput) cv.view).setValueControlled(v);
          cv.yoga.dirty();
        } else if (cv.view instanceof com.canopyhost.views.CanopySwitch) {
          ((com.canopyhost.views.CanopySwitch) cv.view).setCheckedControlled("true".equals(v));
        }
        break;
      case "opacity": {
        // Mirror applyStyle's opacity branch: cache the static base, and unless an animation owns
        // the property, push it straight to the view's alpha.
        Float f = asFloat(v);
        if (f != null) {
          cv.baseOpacity = f;
          if (!animDriver.isOwned(h, "opacity")) cv.view.setAlpha(f);
        }
        break;
      }
      default:
        // An unexpected key (a host newer than the walker, or a future scalar) — fall back to the
        // JSON path so nothing is silently dropped. value is a String, so wrap it as a JSON string.
        applyProps(h, "{" + jsonStr(key) + ":" + jsonStr(v) + "}");
        break;
    }
    requestRelayout();
  }

  public void insertChild(int parent, int child, int index) {
    CView p = views.get(parent), c = views.get(child);
    if (p == null || c == null) return;
    if (c.view.getParent() instanceof ViewGroup) ((ViewGroup) c.view.getParent()).removeView(c.view);
    if (c.yoga.getOwner() != null) {
      int at = indexOf(c.yoga);
      if (at >= 0) c.yoga.getOwner().removeChildAt(at);
    }
    // A ScrollView routes its children into the inner Yoga content root (cv.contentYoga /
    // cv.contentView), not into the ScrollView itself (which holds exactly that one content view).
    YogaNode pYoga = p.contentYoga != null ? p.contentYoga : p.yoga;
    ViewGroup pView = p.contentView != null ? p.contentView : (ViewGroup) p.view;
    int count = pYoga.getChildCount();
    int i = (index < 0 || index > count) ? count : index;
    pYoga.addChildAt(c.yoga, i);
    pView.addView(c.view, i);
    // A content-host root (ScrollView / Modal-Dialog) is a SEPARATE Yoga root the main
    // requestRelayout() does not reach — re-measure it directly.
    if (p.contentView != null) p.contentView.requestLayout();
    requestRelayout();
  }

  public void removeChild(int parent, int child, int index) {
    CView p = views.get(parent), c = views.get(child);
    if (p == null || c == null) return;
    YogaNode pYoga = p.contentYoga != null ? p.contentYoga : p.yoga;
    ViewGroup pView = p.contentView != null ? p.contentView : (ViewGroup) p.view;
    int at = indexOf(c.yoga);
    if (at >= 0) pYoga.removeChildAt(at);
    pView.removeView(c.view);
    animDriver.cancelAll(child); // tear down any running animation so no frame callback hits a dead view
    if (p.contentView != null) p.contentView.requestLayout();
    requestRelayout();
  }

  public void setRoot(int h) {
    root = h;
    View rv = views.get(h).view;
    // Idempotent (DEV-4 reload): __canopy_boot re-calls setRoot on EVERY boot, including the in-process
    // re-boot of a reload, which re-uses the SAME cached root handle. Re-adding an already-parented
    // view throws ("child already has a parent"), so skip the add when the root view is still attached
    // to the surface — the host root view (and the surface) are deliberately preserved across a reload.
    if (rv.getParent() != surface) {
      if (rv.getParent() instanceof ViewGroup) ((ViewGroup) rv.getParent()).removeView(rv);
      surface.addView(rv, new ViewGroup.LayoutParams(
          ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    }
    requestRelayout();
  }

  public void setEvents(int h, String namesJson) {
    CView cv = views.get(h);
    if (cv == null || namesJson == null) return;
    // RCTImageView: record which load lifecycle events the app subscribes to so the async load
    // callback only emits the ones JS listens for (no wasted JSI round-trips on a 200-row feed).
    // Image isn't pressable/gesturable, so we record-and-return below; recompute the set each call
    // (a recycled row that dropped onError must stop emitting it).
    if (cv.view instanceof ImageView) {
      cv.subscribedEvents.clear();
      cv.subscribedEvents.addAll(parseImageEvents(namesJson));
      // An Image can still be wrapped/pressable in RN, but the host's image leaf has no press
      // affordance of its own — fall through to the press/gesture wiring like a plain view.
    }
    if (cv.view instanceof com.canopyhost.views.CanopyScrollView) {
      // A ScrollView owns its own scroll + refresh + momentum listeners; only emit when subscribed.
      com.canopyhost.views.CanopyScrollView sv = (com.canopyhost.views.CanopyScrollView) cv.view;
      sv.setEmitScroll(namesJson.contains("\"scroll\""));
      sv.setEmitRefresh(namesJson.contains("\"refresh\""));
      // AND-7: the fling lifecycle. Either end of the bracket subscribes the momentum machinery
      // (a begin-only or end-only listener is honoured).
      sv.setEmitMomentum(namesJson.contains("\"momentumScrollBegin\"") || namesJson.contains("\"momentumScrollEnd\""));
    }
    if (cv.view instanceof com.canopyhost.views.CanopyModalHost) {
      // AND-7: the modal present/dismiss lifecycle; gated like the ScrollView's scroll events.
      // A modal is a 0×0 portal, never pressable/gesturable — record-and-return.
      ((com.canopyhost.views.CanopyModalHost) cv.view).setEmit(
          namesJson.contains("\"show\""), namesJson.contains("\"dismiss\""));
      return;
    }
    if (cv.view instanceof com.canopyhost.views.CanopyTextInput) {
      // The input owns its own text/IME/focus listeners; emit only the subscribed ones.
      ((com.canopyhost.views.CanopyTextInput) cv.view).setEmit(
          namesJson.contains("\"changeText\""), namesJson.contains("\"submitEditing\""),
          namesJson.contains("\"focus\""), namesJson.contains("\"blur\""));
      return; // an input is not pressable/gesturable; skip the press/gesture wiring below
    }
    if (cv.view instanceof com.canopyhost.views.CanopySwitch) {
      ((com.canopyhost.views.CanopySwitch) cv.view).setEmit(namesJson.contains("\"valueChange\""));
      return; // a switch toggles itself; skip press/gesture wiring
    }
    // "press" must be an exact token, not a substring of longPress/pressIn/pressOut.
    if (namesJson.contains("\"press\"")) {
      cv.view.setClickable(true);
      cv.view.setOnClickListener(v -> CanopyHostJni.emitEvent(h, "press", "{}"));
    } else {
      // A reused view that lost its press handler (e.g. a button diffed into a plain row on a
      // screen change) must stop being clickable — otherwise stale taps fire the wrong msg.
      cv.view.setOnClickListener(null);
      cv.view.setClickable(false);
    }
    boolean wantPan = namesJson.contains("pan");
    boolean wantTap = namesJson.contains("tap");
    boolean wantDouble = namesJson.contains("doubleTap");
    boolean wantLong = namesJson.contains("longPress");
    boolean wantPinch = namesJson.contains("pinch");
    boolean wantPressGesture = namesJson.contains("\"press\"");
    // Tear down any prior gesture detector first: a reused view that dropped its gestures must
    // not keep a live GestureDetector firing pan/tap to the old handle. (BeforeAfterView uses an
    // onTouchEvent override, not an OnTouchListener, so this does not disturb the wipe.)
    cv.view.setOnTouchListener(null);
    if (wantPan || wantTap || wantDouble || wantLong || wantPinch) {
      com.canopyhost.views.CanopyGestures.install(context, cv.view, h, density, wantPan, wantTap, wantDouble, wantLong, wantPinch, wantPressGesture);
    }
  }

  // The imperative-command seam (AND-3 / IOS-8's __fabric_callMethod reconciled to ONE seam).
  // The walker calls __fabric_command(handle, name, argsJson) for ops that aren't expressible
  // as declarative props — focus/blur a text input, measure a view's frame, scroll to an offset.
  // The op runs HERE (UI thread, like every __fabric_* call) and its result returns ASYNC via
  // emitEvent(handle, "__commandResult", resultJson) — the SAME event path press/gesture use,
  // so the JS side decodes it through _Native_dispatchEvent like any other native event.
  //
  // AND-4 dispatch: a switch on `name` runs the concrete op and emits a result that always echoes
  // the JS-supplied __callId (so the walker routes the async result to the matching one-shot — one
  // handle can have several ops in flight). Ops whose answer is only valid post-layout (focus's IME,
  // measure's window coords) DEFER to View.post()/getViewTreeObserver so the frame is settled when
  // they run; the result then hops back via emitEvent on the UI thread (already where we are).
  //
  //   focus          → requestFocus() + show the soft keyboard          → {ok:true}
  //   blur           → clearFocus()  + hide the soft keyboard            → {ok:true}
  //   measure        → getLocationInWindow + Yoga frame (dp)            → {x,y,width,height,pageX,pageY}
  //   scrollTo       → smoothScrollTo(args.x|0, args.y|0) (dp)          → {ok:true}
  //   scrollToIndex  → resolve child N's Yoga frame, smoothScrollTo it  → {ok:true} | {ok:false}
  public void command(int h, String name, String argsJson) {
    // RND-8: __fabric_command is the ONE __fabric_* call the walker does NOT batch (it is an
    // imperative, single-shot op, not a per-frame mutation), so in off-UI-thread mode it arrives here
    // on the CanopyJS thread. Its whole body touches android.view (requestFocus / View.post /
    // getLocationInWindow / smoothScrollTo), so marshal onto the UI thread first when we are not
    // already on it. In single-thread mode (JS == UI thread) we are already on the main Looper, so
    // this runs inline — unchanged. (The batched mutation stream reaches the UI thread via the
    // CanopyHostJni BatchSink → runUiBatch; this covers the one un-batched seam.)
    if (Looper.myLooper() != Looper.getMainLooper()) {
      RELOAD_HANDLER.post(() -> command(h, name, argsJson));
      return;
    }
    String op = name == null ? "" : name;
    JSONObject args;
    try { args = new JSONObject((argsJson == null || argsJson.isEmpty()) ? "{}" : argsJson); }
    catch (Exception e) { args = new JSONObject(); }
    String callId = parseCallId(args); // a JSON value literal (number/string/null) echoed verbatim

    CView cv = views.get(h);
    if (cv == null) { emitCommandResult(h, callId, "{\"ok\":false,\"error\":\"unknown handle\"}"); return; }

    switch (op) {
      case "focus":         commandFocus(h, cv, callId, true);  break;
      case "blur":          commandFocus(h, cv, callId, false); break;
      case "measure":       commandMeasure(h, cv, callId);      break;
      case "scrollTo":      commandScrollTo(h, cv, callId, args); break;
      case "scrollToIndex": commandScrollToIndex(h, cv, callId, args); break;
      default:
        // An unknown op: acknowledge with the AND-3 echo shape so a forward-compat walker still
        // sees a result (no silent drop), carrying the echoed callId.
        emitCommandResult(h, callId, "{\"name\":" + jsonStr(op) + ",\"args\":" + args.toString() + "}");
        break;
    }
  }

  // focus/blur: requestFocus()/clearFocus() + toggle the soft keyboard. Deferred to View.post() so
  // it runs AFTER the current layout/mount settles — a freshly mounted EditText is not yet attached
  // to a window when the command arrives, and showSoftInput on an unattached/zero-size view is a
  // no-op (the canonical RN focus-timing bug). post() also lets a `value`-set that rode the same
  // frame land first, so the caret/IME target the final text.
  private void commandFocus(int h, CView cv, String callId, boolean focus) {
    final View v = cv.view;
    v.post(() -> {
      if (focus) {
        v.setFocusableInTouchMode(true);
        boolean got = v.requestFocus();
        android.view.inputmethod.InputMethodManager imm =
            (android.view.inputmethod.InputMethodManager) context.getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null && got) imm.showSoftInput(v, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT);
        emitCommandResult(h, callId, "{\"ok\":" + got + "}");
      } else {
        v.clearFocus();
        android.view.inputmethod.InputMethodManager imm =
            (android.view.inputmethod.InputMethodManager) context.getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) imm.hideSoftInputFromWindow(v.getWindowToken(), 0);
        emitCommandResult(h, callId, "{\"ok\":true}");
      }
    });
  }

  // measure: report the view's frame. x/y are the offset within the parent (from the Yoga frame),
  // width/height the laid-out size, and pageX/pageY the absolute position in window coordinates
  // (getLocationInWindow) — the RN UIManager.measure contract. All lengths are in dp (÷ density),
  // matching how every other dimension crosses the seam. Deferred to post() so the frame is settled
  // (a measure issued in the same frame as the mount would read a 0×0 pre-layout frame).
  private void commandMeasure(int h, CView cv, String callId) {
    final View v = cv.view;
    final YogaNode y = cv.yoga;
    v.post(() -> {
      int[] win = new int[2];
      v.getLocationInWindow(win);
      float x = y.getLayoutX() / density;
      float ydp = y.getLayoutY() / density;
      float w = v.getWidth() / density;
      float ht = v.getHeight() / density;
      float pageX = win[0] / density;
      float pageY = win[1] / density;
      emitCommandResult(h, callId, measureResultJson(x, ydp, w, ht, pageX, pageY));
    });
  }

  // scrollTo: drive the ScrollView to an absolute offset (dp → px). The scroller (a NestedScrollView
  // or HorizontalScrollView) lives INSIDE the CanopyScrollView FrameLayout (possibly under a
  // SwipeRefreshLayout); we resolve it by hierarchy so this stays a command-handler concern and does
  // not reach into the view lane. A non-scroll target is a no-op success (RN's permissive scrollTo
  // on a plain view). animated:false jumps without a tween.
  private void commandScrollTo(int h, CView cv, String callId, JSONObject args) {
    final View v = cv.view;
    final int x = Math.round((float) args.optDouble("x", 0) * density);
    final int y = Math.round((float) args.optDouble("y", 0) * density);
    final boolean animated = args.optBoolean("animated", true);
    v.post(() -> {
      smoothScroll(findScroller(v), x, y, animated);
      emitCommandResult(h, callId, "{\"ok\":true}");
    });
  }

  // scrollToIndex: put child N of the ScrollView's content on screen. We resolve child N's settled
  // Yoga frame in the inner content root (the scroll-axis offset) and scroll the inner scroller to
  // it. Out-of-range N (or a non-scroll target) returns ok:false so the app can react. Deferred to
  // post() so the content's Yoga frames are computed.
  private void commandScrollToIndex(int h, CView cv, String callId, JSONObject args) {
    final View v = cv.view;
    final int index = args.optInt("index", 0);
    final boolean animated = args.optBoolean("animated", true);
    final YogaNode contentYoga = cv.contentYoga;
    v.post(() -> {
      View scroller = findScroller(v);
      if (scroller == null || contentYoga == null || index < 0 || index >= contentYoga.getChildCount()) {
        emitCommandResult(h, callId, "{\"ok\":false}");
        return;
      }
      YogaNode child = contentYoga.getChildAt(index);
      // Yoga frames are already in px (dp×density at apply-time), so they target the scroller directly.
      smoothScroll(scroller, Math.round(child.getLayoutX()), Math.round(child.getLayoutY()), animated);
      emitCommandResult(h, callId, "{\"ok\":true}");
    });
  }

  /** Find the framework scroller (NestedScrollView / HorizontalScrollView) inside a CanopyScrollView
   *  composite (it may sit under a SwipeRefreshLayout). Returns null for a non-scroll target. */
  private static View findScroller(View root) {
    if (root instanceof androidx.core.widget.NestedScrollView
        || root instanceof android.widget.HorizontalScrollView
        || root instanceof android.widget.ScrollView) return root;
    if (root instanceof ViewGroup) {
      ViewGroup g = (ViewGroup) root;
      for (int i = 0; i < g.getChildCount(); i++) {
        View found = findScroller(g.getChildAt(i));
        if (found != null) return found;
      }
    }
    return null;
  }

  /** Drive a resolved scroller to (x,y) px on its scroll axis; animated tweens, else jumps. */
  private static void smoothScroll(View scroller, int x, int y, boolean animated) {
    if (scroller == null) return;
    if (animated) scroller.scrollTo(x, y);                 // base view scroll; subclasses smooth below
    if (scroller instanceof androidx.core.widget.NestedScrollView) {
      androidx.core.widget.NestedScrollView ns = (androidx.core.widget.NestedScrollView) scroller;
      if (animated) ns.smoothScrollTo(x, y); else ns.scrollTo(x, y);
    } else if (scroller instanceof android.widget.HorizontalScrollView) {
      android.widget.HorizontalScrollView hs = (android.widget.HorizontalScrollView) scroller;
      if (animated) hs.smoothScrollTo(x, y); else hs.scrollTo(x, y);
    } else if (scroller instanceof android.widget.ScrollView) {
      android.widget.ScrollView sv = (android.widget.ScrollView) scroller;
      if (animated) sv.smoothScrollTo(x, y); else sv.scrollTo(x, y);
    } else {
      scroller.scrollTo(x, y);
    }
  }

  // ---- command-result helpers (pure; unit-tested via Robolectric) -----------

  /** Pull __callId from the command args as a JSON value LITERAL (number/string), echoed verbatim
   *  into the result so the walker routes by it. Absent → "null" (the walker then falls back to its
   *  per-handle one-shot, AND-3 behaviour). */
  static String parseCallId(JSONObject args) {
    if (args == null || !args.has("__callId") || args.isNull("__callId")) return "null";
    Object v = args.opt("__callId");
    if (v instanceof Number) return v.toString();          // numeric callId (the walker's default)
    return jsonStr(String.valueOf(v));                      // string callId → quoted literal
  }

  /** Build the measure result payload (dp lengths) the RN UIManager.measure contract returns. */
  static String measureResultJson(float x, float y, float width, float height, float pageX, float pageY) {
    return "{\"x\":" + fmt(x) + ",\"y\":" + fmt(y)
        + ",\"width\":" + fmt(width) + ",\"height\":" + fmt(height)
        + ",\"pageX\":" + fmt(pageX) + ",\"pageY\":" + fmt(pageY) + "}";
  }

  /** Splice the echoed __callId into a result object and emit it on the __commandResult event path. */
  private void emitCommandResult(int h, String callId, String resultBody) {
    CanopyHostJni.emitEvent(h, "__commandResult", mergeCallId(callId, resultBody));
  }

  /** Inject "__callId":<callId> as the first member of a result object literal ("{...}") so the JS
   *  dispatcher can route the async result to the matching per-callId one-shot. callId is already a
   *  JSON value literal (a number, a quoted string, or "null"); resultBody is spliced verbatim. */
  static String mergeCallId(String callId, String resultBody) {
    String body = (resultBody == null || resultBody.length() < 2) ? "{}" : resultBody;
    String inner = body.substring(1, body.length() - 1).trim(); // drop the outer braces
    return "{\"__callId\":" + callId + (inner.isEmpty() ? "" : "," + inner) + "}";
  }

  /** Compact float→JSON: drop a trailing ".0" so integers read as integers (10, not 10.0). */
  private static String fmt(float v) {
    if (v == Math.rint(v) && !Float.isInfinite(v)) return Integer.toString((int) v);
    return Float.toString(v);
  }

  // ---- view construction ----------------------------------------------------

  private static boolean isLeaf(String name) {
    // Intrinsic-content leaves get a Yoga measure function (text/image/bitmap size themselves).
    // BeforeAfter is a measuring leaf too: like ImageView/CanopyBitmap it derives an intrinsic
    // size from its `before` bitmap (fill available width, height from aspect) when an axis is
    // AT_MOST/UNSPECIFIED, and honors an EXACTLY spec when width/height are pinned.
    // (Excluding it previously collapsed any flex/aspectRatio layout to 0 height — a real bug.)
    return "RCTText".equals(name) || "RCTRawText".equals(name)
        || "RCTImageView".equals(name) || "RCTSinglelineTextInputView".equals(name)
        || "ActivityIndicator".equals(name) || "RCTSwitch".equals(name)
        || "CanopyBitmap".equals(name) || "BeforeAfter".equals(name);
  }

  private View makeView(String name) {
    switch (name) {
      case "RCTText":
      case "RCTRawText":
        return new TextView(context);
      case "RCTImageView":
        return new ImageView(context);
      case "RCTSinglelineTextInputView":
        return new com.canopyhost.views.CanopyTextInput(context);
      case "CanopyBitmap":
        return new ImageView(context);                                  // canopy/image: draws a blob handle
      case "RCTScrollView":
        return new com.canopyhost.views.CanopyScrollView(context);
      case "CanopyModalHost":
        return new com.canopyhost.views.CanopyModalHost(context);
      case "ActivityIndicator": {
        ProgressBar pb = new ProgressBar(context);
        pb.setIndeterminate(true);
        return pb;
      }
      case "RCTSwitch":
        return new com.canopyhost.views.CanopySwitch(context);
      case "CanopyStatusBar":
        return new View(context); // 0×0 placeholder; applies window status-bar style as a side effect
      case "BeforeAfter":
        return new com.canopyhost.views.BeforeAfterView(context);  // C2 wipe compositor
      default: {
        // Escape-hatch M1: an UNKNOWN tag may be a third-party native component registered via
        // CanopyViewRegistry — consult it before falling back to a plain container. Built-in tags
        // never reach here, so the common path keeps its fast in-switch dispatch.
        View custom = CanopyViewRegistry.create(name, context);
        if (custom != null) {
          return custom;
        }
        // RCTView / RCTRootView / unknown → a plain Yoga container.
        return new YogaViewGroup(context);
      }
    }
  }

  // ---- props + style --------------------------------------------------------

  private void applyProps(int h, String propsJson) {
    try {
      JSONObject props = new JSONObject(propsJson == null ? "{}" : propsJson);
      CView cv = views.get(h);
      if (cv == null) return;
      // A removed plain prop arrives as JSON null (see native.js) — treat it as a reset, not a
      // stale keep. optInt/optString/optDouble coerce null to 0/""/NaN, so the isNull guards are
      // load-bearing (esp. wipeFraction, where optDouble can't recover the 0.5 default from null).
      if (props.has("text") && cv.view instanceof TextView && !(cv.view instanceof EditText)) {
        ((TextView) cv.view).setText(props.isNull("text") ? "" : props.optString("text"));
        cv.yoga.dirty(); // leaf content changed → re-measure
      }
      // TextInput (RCTSinglelineTextInputView): controlled value + placeholder/keyboard/secure +
      // AND-5 controlled-input parity (maxLength/returnKeyType/autoCapitalize/selection + caret).
      if (cv.view instanceof com.canopyhost.views.CanopyTextInput) {
        com.canopyhost.views.CanopyTextInput ti = (com.canopyhost.views.CanopyTextInput) cv.view;
        // maxLength BEFORE value so a controlled value is filtered to the cap on the same frame.
        if (props.has("maxLength")) ti.setMaxLengthControlled(props.isNull("maxLength") ? -1 : props.optInt("maxLength", -1));
        if (props.has("value")) { ti.setValueControlled(props.isNull("value") ? "" : props.optString("value", "")); cv.yoga.dirty(); }
        if (props.has("placeholder")) ti.setHint(props.isNull("placeholder") ? null : props.optString("placeholder"));
        if (props.has("placeholderTextColor") && !props.isNull("placeholderTextColor")) ti.setHintTextColor(parseColor(props.optString("placeholderTextColor")));
        if (props.has("editable")) ti.setEnabled(!"false".equals(props.optString("editable")));
        int base = android.text.InputType.TYPE_CLASS_TEXT;
        boolean multiline = props.has("multiline") && "true".equals(props.optString("multiline"));
        boolean secure = props.has("secureTextEntry") && "true".equals(props.optString("secureTextEntry"));
        String kb = props.optString("keyboardType", "default");
        if ("numeric".equals(kb) || "number-pad".equals(kb)) base = android.text.InputType.TYPE_CLASS_NUMBER;
        else if ("decimal-pad".equals(kb)) base = android.text.InputType.TYPE_CLASS_NUMBER | android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL;
        else if ("phone-pad".equals(kb)) base = android.text.InputType.TYPE_CLASS_PHONE;
        else if ("email-address".equals(kb)) base = android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS;
        if (secure) base = android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD;
        if (multiline) base |= android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE;
        if (props.has("keyboardType") || props.has("secureTextEntry") || props.has("multiline")) {
          ti.setInputType(base);
          ti.setSingleLine(!multiline);
          cv.yoga.dirty();
        }
        // autoCapitalize OR's its cap flags onto whatever base input type we just set, so it must
        // run AFTER setInputType above (else setInputType would clobber the cap flag).
        if (props.has("autoCapitalize")) ti.setAutoCapitalizeControlled(props.isNull("autoCapitalize") ? "sentences" : props.optString("autoCapitalize", "sentences"));
        if (props.has("returnKeyType")) ti.setReturnKeyTypeControlled(props.isNull("returnKeyType") ? "done" : props.optString("returnKeyType", "done"));
        // Explicit controlled selection runs LAST so it wins over the value-diff caret restore.
        if (props.has("selection") && !props.isNull("selection")) {
          JSONObject sel = props.optJSONObject("selection");
          if (sel != null) ti.setSelectionControlled(sel.optInt("start", 0), sel.optInt("end", sel.optInt("start", 0)));
        }
      }
      // ActivityIndicator: tint + animating visibility.
      if (cv.view instanceof ProgressBar) {
        ProgressBar pb = (ProgressBar) cv.view;
        if (props.has("color") && !props.isNull("color") && pb.getIndeterminateDrawable() != null) {
          pb.getIndeterminateDrawable().setColorFilter(parseColor(props.optString("color")), android.graphics.PorterDuff.Mode.SRC_IN);
        }
        if (props.has("animating")) {
          pb.setVisibility("false".equals(props.optString("animating")) ? View.INVISIBLE : View.VISIBLE);
        }
      }
      // Switch (RCTSwitch): controlled checked value (echo-guarded) + disabled.
      if (cv.view instanceof com.canopyhost.views.CanopySwitch) {
        com.canopyhost.views.CanopySwitch sw = (com.canopyhost.views.CanopySwitch) cv.view;
        if (props.has("value")) sw.setCheckedControlled("true".equals(props.optString("value")));
        if (props.has("disabled")) sw.setEnabled(!"true".equals(props.optString("disabled")));
      }
      // ScrollView: orientation, scroll-lock, pull-to-refresh.
      if (cv.view instanceof com.canopyhost.views.CanopyScrollView) {
        com.canopyhost.views.CanopyScrollView sv = (com.canopyhost.views.CanopyScrollView) cv.view;
        if (props.has("horizontal")) {
          boolean horiz = "true".equals(props.optString("horizontal"));
          sv.setHorizontal(horiz);
          // The content lays out along the scroll axis: a row for horizontal scrolling.
          if (cv.contentYoga != null) cv.contentYoga.setFlexDirection(horiz ? YogaFlexDirection.ROW : YogaFlexDirection.COLUMN);
        }
        if (props.has("scrollEnabled")) sv.setScrollEnabled(!"false".equals(props.optString("scrollEnabled")));
        if (props.has("refreshControl")) sv.setRefreshControl("true".equals(props.optString("refreshControl")));
        if (props.has("refreshing")) sv.setRefreshing("true".equals(props.optString("refreshing")));
        // AND-7: scrollEventThrottle (ms floor between "scroll" samples; 0 ⇒ per-frame cap).
        if (props.has("scrollEventThrottle")) sv.setScrollEventThrottle(props.optInt("scrollEventThrottle", 0));
        // AND-7: keyboardDismissMode ("none" | "on-drag"). Null on a recycled view restores "none".
        if (props.has("keyboardDismissMode")) sv.setKeyboardDismissMode(props.isNull("keyboardDismissMode") ? "none" : props.optString("keyboardDismissMode", "none"));
        // AND-7: controlled contentOffset {x,y,animated?} (dp). Drives the scroller; echo-guarded so
        // the resulting programmatic scroll sample does not loop back. Applied LAST so orientation is set.
        if (props.has("contentOffset") && !props.isNull("contentOffset")) {
          JSONObject off = props.optJSONObject("contentOffset");
          if (off != null) sv.setContentOffset((float) off.optDouble("x", 0), (float) off.optDouble("y", 0), off.optBoolean("animated", false));
        }
      }
      // StatusBar (declarative): set the window status-bar appearance as a side effect.
      if ("CanopyStatusBar".equals(cv.fabricName) && MainActivity.current() != null) {
        android.view.Window win = MainActivity.current().getWindow();
        androidx.core.view.WindowInsetsControllerCompat ic =
            androidx.core.view.WindowCompat.getInsetsController(win, win.getDecorView());
        if (props.has("barStyle")) {
          // "light" = light content (white icons), for a dark bar → appearance-light-bars OFF.
          ic.setAppearanceLightStatusBars(!"light".equals(props.optString("barStyle")));
        }
        if (props.has("barColor") && !props.isNull("barColor")) {
          // Opt out of translucent/edge-to-edge for THIS window so the system paints the bar with
          // the requested colour (otherwise setStatusBarColor is ignored on a transparent bar).
          androidx.core.view.WindowCompat.setDecorFitsSystemWindows(win, true);
          win.clearFlags(android.view.WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS);
          win.addFlags(android.view.WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
          win.setStatusBarColor(parseColor(props.optString("barColor")));
        }
        if (props.has("barHidden")) {
          if ("true".equals(props.optString("barHidden"))) ic.hide(androidx.core.view.WindowInsetsCompat.Type.statusBars());
          else ic.show(androidx.core.view.WindowInsetsCompat.Type.statusBars());
        }
      }
      // canopy/image: draw a BlobRegistry bitmap handle (zero-copy from the shared registry).
      if (props.has("bitmapHandle") && cv.view instanceof ImageView) {
        int bh = props.isNull("bitmapHandle") ? 0 : props.optInt("bitmapHandle", 0);
        android.graphics.Bitmap bmp = (bh != 0) ? com.canopyhost.CanopyBlobs.nativeBlobGetBitmap(bh) : null;
        ((ImageView) cv.view).setImageBitmap(bmp);
        cv.lastSource = null; // a blob handle supersedes any prior declarative source
        cv.yoga.dirty();
      }
      // RCTImageView declarative `resizeMode` → ScaleType (RN cover/contain/stretch/center).
      // A recycled view that DROPPED resizeMode (arrives JSON-null) restores the cover default.
      if (props.has("resizeMode") && cv.view instanceof ImageView) {
        ((ImageView) cv.view).setScaleType(scaleType(props.isNull("resizeMode") ? "cover" : props.optString("resizeMode", "cover")));
      }
      // RCTImageView `headers`: per-request HTTP headers (a JSON object, e.g. {"Authorization":…})
      // threaded to the loader for private-CDN fetches. Null on a recycled row drops prior headers
      // so a reused view never carries the previous screen's auth.
      if (props.has("headers") && cv.view instanceof ImageView) {
        cv.imageHeaders = props.isNull("headers") ? null : parseHeaders(props.optString("headers", null));
      }
      // RCTImageView `defaultSource`: a placeholder/fallback URI shown WHILE `source` loads and on
      // error (RN parity). Decoded async like source; cleared on a recycled row's null.
      if (props.has("defaultSource") && cv.view instanceof ImageView) {
        cv.defaultSource = props.isNull("defaultSource") ? null : props.optString("defaultSource", null);
        if (cv.defaultSource == null) cv.lastDefaultSource = null;
      }
      // RCTImageView declarative `source` (URL/file/asset/content) → async load via CanopyImageLoader.
      // Guarded by lastSource so an unchanged source on re-render does not re-fetch; the async
      // callback re-checks lastSource so a recycled view never shows a previous source's pixels.
      // The decode is downsampled to the SETTLED Yoga frame (deferred to first layout when the
      // frame is still 0 at create-time) so a feed of rows decodes thumbnail-sized, not full-res.
      if (props.has("source") && cv.view instanceof ImageView && !props.has("bitmapHandle")) {
        String src = props.isNull("source") ? null : props.optString("source", null);
        if (src == null || src.isEmpty()) {
          cv.lastSource = null;
          ((ImageView) cv.view).setImageDrawable(null);
          cv.yoga.dirty();
        } else if (!src.equals(cv.lastSource)) {
          cv.lastSource = src;
          // Clear any prior bitmap so the placeholder (if any) shows during the load, then kick off
          // the placeholder decode (async) and the real source load against the settled frame.
          if (cv.defaultSource != null && !cv.defaultSource.isEmpty()) {
            ((ImageView) cv.view).setImageDrawable(null);
            applyDefaultSource(cv);
          }
          loadImageWhenSized(cv, h, src);
        }
      }
      // C2 BeforeAfter compositor: before/after handles + the native wipe fraction.
      if (cv.view instanceof com.canopyhost.views.BeforeAfterView) {
        com.canopyhost.views.BeforeAfterView ba = (com.canopyhost.views.BeforeAfterView) cv.view;
        if (props.has("beforeHandle")) ba.setBeforeHandle(props.isNull("beforeHandle") ? 0 : props.optInt("beforeHandle", 0));
        if (props.has("afterHandle"))  ba.setAfterHandle(props.isNull("afterHandle") ? 0 : props.optInt("afterHandle", 0));
        if (props.has("wipeFraction")) ba.setWipeFraction(props.isNull("wipeFraction") ? 0.5f : (float) props.optDouble("wipeFraction", 0.5));
      }
      // Modal (CanopyModalHost): config the overlay + its status bar, then toggle visibility LAST so
      // transparency + animation + status-bar theming are in place before the Dialog shows.
      if (cv.view instanceof com.canopyhost.views.CanopyModalHost) {
        com.canopyhost.views.CanopyModalHost mh = (com.canopyhost.views.CanopyModalHost) cv.view;
        if (props.has("transparent")) mh.setTransparent("true".equals(props.optString("transparent")));
        if (props.has("animationType")) mh.setAnimationType(props.optString("animationType"));
        // AND-7: status-bar propagation. statusBarTranslucent draws the modal window edge-to-edge;
        // statusBarColor / statusBarStyle theme the modal's OWN bar while it is up.
        if (props.has("statusBarTranslucent")) mh.setStatusBarTranslucent("true".equals(props.optString("statusBarTranslucent")));
        if (props.has("statusBarColor")) mh.setStatusBarColor(props.isNull("statusBarColor") ? null : Integer.valueOf(parseColor(props.optString("statusBarColor"))));
        if (props.has("statusBarStyle")) mh.setStatusBarStyle(props.isNull("statusBarStyle") ? null : props.optString("statusBarStyle"));
        if (props.has("visible")) mh.setVisible("true".equals(props.optString("visible")));
      }
      if (props.has("style")) applyStyle(h, cv, props.getJSONObject("style"));
      // Declarative animations: a single plain prop carrying the spec list, driven host-side by
      // the Choreographer. Applied AFTER style so a NaN `from` reads the resting value.
      if (props.has("animations")) applyAnimations(h, cv, props);
      // --- accessibility + test identity (T0): the cross-driver selector contract ---------
      // testID → View content-description (Appium `~testID` / UIAutomator content-desc / Maestro
      // id) and the spoken handle when no label is set. accessibilityLabel overrides it for
      // TalkBack. role/hint ride an AccessibilityDelegate. A removed prop arrives as JSON null
      // (same diff discipline as text/style) → cleared, so a recycled view drops stale identity.
      if (props.has("testID") || props.has("accessibilityLabel")) {
        if (props.has("testID")) cv.testID = props.isNull("testID") ? null : props.optString("testID", null);
        if (props.has("accessibilityLabel")) cv.a11yLabel = props.isNull("accessibilityLabel") ? null : props.optString("accessibilityLabel", null);
        cv.view.setContentDescription(cv.a11yLabel != null ? cv.a11yLabel : cv.testID);
      }
      if (props.has("accessibilityRole")) {
        cv.a11yRole = props.isNull("accessibilityRole") ? null : props.optString("accessibilityRole", null);
        installAccessibilityDelegate(cv);
      }
      if (props.has("accessibilityHint")) {
        cv.a11yHint = props.isNull("accessibilityHint") ? null : props.optString("accessibilityHint", null);
        installAccessibilityDelegate(cv);
      }
      if (props.has("accessible")) {
        boolean acc = !props.isNull("accessible") && "true".equals(props.optString("accessible"));
        cv.view.setImportantForAccessibility(acc ? View.IMPORTANT_FOR_ACCESSIBILITY_YES : View.IMPORTANT_FOR_ACCESSIBILITY_AUTO);
      }
      // Event set changed on a diff (added/removed on a reused view): the walker sends the
      // new name list as __events. Re-run setEvents so press/gesture wiring tracks the tree
      // (initial render calls __fabric_setEvents directly; updates ride this prop).
      if (props.has("__events")) setEvents(h, props.opt("__events").toString());
    } catch (Exception ignored) {}
  }

  // ---- Image (AND-6): event gating, settled-frame downsample, defaultSource ------------------

  /**
   * Parse the image load lifecycle events the app subscribes to from a setEvents names JSON
   * (e.g. ["press","load"] → {"load"}). Quoted-token match so "load" isn't found inside another
   * name. Test-visible: the unit test pins the gating contract through this.
   */
  public static Set<String> parseImageEvents(String namesJson) {
    Set<String> s = new HashSet<>();
    if (namesJson == null) return s;
    if (namesJson.contains("\"load\"")) s.add("load");
    if (namesJson.contains("\"error\"")) s.add("error");
    if (namesJson.contains("\"loadEnd\"")) s.add("loadEnd");
    return s;
  }

  /** Parse a `headers` JSON object ({"K":"V",…}) into a String→String map (null on absence/error). */
  private static Map<String, String> parseHeaders(String json) {
    if (json == null || json.isEmpty()) return null;
    try {
      JSONObject o = new JSONObject(json);
      Map<String, String> m = new HashMap<>();
      for (Iterator<String> it = o.keys(); it.hasNext(); ) {
        String k = it.next();
        if (!o.isNull(k)) m.put(k, o.optString(k));
      }
      return m.isEmpty() ? null : m;
    } catch (Exception e) {
      return null;
    }
  }

  /** Decode + show the cached/loaded defaultSource placeholder into the view (best-effort, async). */
  private void applyDefaultSource(CView cv) {
    final String ph = cv.defaultSource;
    if (ph == null || ph.isEmpty() || !(cv.view instanceof ImageView)) return;
    final ImageView iv = (ImageView) cv.view;
    cv.lastDefaultSource = ph;
    com.canopyhost.views.CanopyImageLoader.load(context, ph, 0, 0, (bmp, error) -> {
      // Only paint the placeholder if the real source still hasn't landed (the view shows the
      // placeholder, not yet a final bitmap) and the row hasn't been recycled to a new placeholder.
      if (bmp != null && ph.equals(cv.lastDefaultSource) && iv.getDrawable() == null) {
        iv.setImageBitmap(bmp);
        cv.yoga.dirty();
        requestRelayout();
      }
    });
  }

  /**
   * Issue the source decode against the view's SETTLED Yoga frame. At createView→applyProps the
   * frame is still 0 (layout not computed yet), which would defeat downsampling — so when the frame
   * is unknown we defer the load to the next layout pass via a one-shot OnLayoutChangeListener,
   * reading the real width/height there. Recycled-view discipline: every callback re-checks
   * cv.lastSource so a row reused for a different image drops a stale async result.
   */
  private void loadImageWhenSized(CView cv, int h, String src) {
    final ImageView iv = (ImageView) cv.view;
    int w = Math.round(cv.yoga.getLayoutWidth());
    int hgt = Math.round(cv.yoga.getLayoutHeight());
    if (w > 0 || hgt > 0) {
      issueImageLoad(cv, h, src, iv, w, hgt);
      return;
    }
    // Frame not settled yet: load once it is. The listener removes itself so a long-lived row
    // doesn't re-issue on every later layout (scroll, rotation) — lastSource already de-dupes.
    iv.addOnLayoutChangeListener(new View.OnLayoutChangeListener() {
      @Override public void onLayoutChange(View v, int l, int t, int r, int b,
                                           int ol, int ot, int or, int ob) {
        iv.removeOnLayoutChangeListener(this);
        if (!src.equals(cv.lastSource)) return; // recycled before first layout — drop
        issueImageLoad(cv, h, src, iv, r - l, b - t);
      }
    });
  }

  private void issueImageLoad(CView cv, int h, String src, ImageView iv, int targetW, int targetH) {
    com.canopyhost.views.CanopyImageLoader.load(context, src, targetW, targetH, cv.imageHeaders, (bmp, error) -> {
      if (!src.equals(cv.lastSource)) return; // recycled to a different source meanwhile — drop
      if (bmp != null) {
        iv.setImageBitmap(bmp);
        cv.yoga.dirty();
        requestRelayout();
        emitImageEvent(cv, h, "load", "{}");
      } else {
        // Keep the placeholder visible on error if one was shown; surface the error to JS.
        emitImageEvent(cv, h, "error", "{\"error\":" + jsonStr(error) + "}");
      }
      emitImageEvent(cv, h, "loadEnd", "{}");
    });
  }

  /** Emit a load lifecycle event only if the app subscribed to it (gated by setEvents). */
  private void emitImageEvent(CView cv, int h, String name, String payload) {
    if (cv.subscribedEvents.contains(name)) CanopyHostJni.emitEvent(h, name, payload);
  }

  // One AccessibilityDelegate per view publishes role/hint into the a11y node so TalkBack and
  // black-box drivers (Appium/Espresso) see the RN-equivalent role. Installed once per view.
  private void installAccessibilityDelegate(CView cv) {
    if (cv.a11yDelegateInstalled) return;
    cv.a11yDelegateInstalled = true;
    cv.view.setAccessibilityDelegate(new View.AccessibilityDelegate() {
      @Override public void onInitializeAccessibilityNodeInfo(View v, AccessibilityNodeInfo info) {
        super.onInitializeAccessibilityNodeInfo(v, info);
        if (cv.a11yRole != null) info.setClassName(roleToClassName(cv.a11yRole));
        if (cv.a11yHint != null) info.setTooltipText(cv.a11yHint);
      }
    });
  }

  private static CharSequence roleToClassName(String role) {
    switch (role) {
      case "button":   return "android.widget.Button";
      case "image":    return "android.widget.ImageView";
      case "header":   return "android.widget.TextView";
      case "link":     return "android.widget.Button";
      case "checkbox": return "android.widget.CheckBox";
      case "switch":   return "android.widget.Switch";
      default:         return "android.view.View";
    }
  }

  private void applyStyle(int h, CView cv, JSONObject style) {
    for (java.util.Iterator<String> it = style.keys(); it.hasNext();) {
      String key = it.next();
      YogaNode y = cv.yoga;
      // null = "this key was removed on a diff" → reset to default so a reused view does not
      // carry a prior screen's flex/size/background (see native.js _Native_diffSub).
      if (style.isNull(key)) { resetStyleKey(h, cv, y, key); continue; }
      String s = style.optString(key);
      Float f = asFloat(s);
      switch (key) {
        case "width":  setDim(s, f, y::setWidth, y::setWidthPercent, y::setWidthAuto); break;
        case "height": setDim(s, f, y::setHeight, y::setHeightPercent, y::setHeightAuto); break;
        case "minWidth":  if (f != null) y.setMinWidth(dp(f)); break;
        case "minHeight": if (f != null) y.setMinHeight(dp(f)); break;
        case "maxWidth":  if (f != null) y.setMaxWidth(dp(f)); break;
        case "maxHeight": if (f != null) y.setMaxHeight(dp(f)); break;
        case "flex":       if (f != null) y.setFlex(f); break;
        case "flexGrow":   if (f != null) y.setFlexGrow(f); break;
        case "flexShrink": if (f != null) y.setFlexShrink(f); break;
        case "flexBasis":  if (f != null) y.setFlexBasis(dp(f)); break;
        case "flexWrap":   y.setWrap("wrap".equals(s) ? YogaWrap.WRAP : YogaWrap.NO_WRAP); break;
        case "gap":        if (f != null) y.setGap(YogaGutter.ALL, dp(f)); break;
        case "padding":       if (f != null) y.setPadding(YogaEdge.ALL, dp(f)); break;
        case "paddingTop":    if (f != null) y.setPadding(YogaEdge.TOP, dp(f)); break;
        case "paddingBottom": if (f != null) y.setPadding(YogaEdge.BOTTOM, dp(f)); break;
        case "paddingLeft":   if (f != null) y.setPadding(YogaEdge.LEFT, dp(f)); break;
        case "paddingRight":  if (f != null) y.setPadding(YogaEdge.RIGHT, dp(f)); break;
        case "paddingHorizontal": if (f != null) y.setPadding(YogaEdge.HORIZONTAL, dp(f)); break;
        case "paddingVertical":   if (f != null) y.setPadding(YogaEdge.VERTICAL, dp(f)); break;
        case "margin":        if (f != null) y.setMargin(YogaEdge.ALL, dp(f)); break;
        case "marginTop":     if (f != null) y.setMargin(YogaEdge.TOP, dp(f)); break;
        case "marginBottom":  if (f != null) y.setMargin(YogaEdge.BOTTOM, dp(f)); break;
        case "marginLeft":    if (f != null) y.setMargin(YogaEdge.LEFT, dp(f)); break;
        case "marginRight":   if (f != null) y.setMargin(YogaEdge.RIGHT, dp(f)); break;
        case "marginHorizontal": if (f != null) y.setMargin(YogaEdge.HORIZONTAL, dp(f)); break;
        case "marginVertical":   if (f != null) y.setMargin(YogaEdge.VERTICAL, dp(f)); break;
        case "top":    if (f != null) y.setPosition(YogaEdge.TOP, dp(f)); break;
        case "bottom": if (f != null) y.setPosition(YogaEdge.BOTTOM, dp(f)); break;
        case "left":   if (f != null) y.setPosition(YogaEdge.LEFT, dp(f)); break;
        case "right":  if (f != null) y.setPosition(YogaEdge.RIGHT, dp(f)); break;
        // Logical (writing-direction-aware) edges — REACH-1 / RTL. Yoga's START/END resolve to
        // LEFT/RIGHT under direction=ltr and swap under direction=rtl, so one view mirrors itself.
        case "paddingStart": if (f != null) y.setPadding(YogaEdge.START, dp(f)); break;
        case "paddingEnd":   if (f != null) y.setPadding(YogaEdge.END, dp(f)); break;
        case "marginStart":  if (f != null) y.setMargin(YogaEdge.START, dp(f)); break;
        case "marginEnd":    if (f != null) y.setMargin(YogaEdge.END, dp(f)); break;
        case "start":  if (f != null) y.setPosition(YogaEdge.START, dp(f)); break;
        case "end":    if (f != null) y.setPosition(YogaEdge.END, dp(f)); break;
        case "direction":
          y.setDirection("rtl".equals(s) ? YogaDirection.RTL
              : "ltr".equals(s) ? YogaDirection.LTR
              : YogaDirection.INHERIT);
          break;
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
        case "backgroundColor": cv.bgColor = parseColor(s); applyBackground(cv); break;
        case "borderRadius":    applyBorderRadius(cv, s, f); break;
        case "borderTopLeftRadius":     setCorner(cv, 0, f); break;
        case "borderTopRightRadius":    setCorner(cv, 1, f); break;
        case "borderBottomRightRadius": setCorner(cv, 2, f); break;
        case "borderBottomLeftRadius":  setCorner(cv, 3, f); break;
        // Border: a uniform width + color (Yoga insets the content; the stroke is painted by the
        // background drawable). The `border` shorthand ("1 solid #333") and the long-form
        // borderWidth/borderColor both land here.
        case "borderWidth":   if (f != null) { cv.borderWidth = dp(f); y.setBorder(YogaEdge.ALL, dp(f)); applyBackground(cv); } break;
        case "borderColor":   cv.borderColor = parseColor(s); applyBackground(cv); break;
        case "border":        applyBorderShorthand(cv, y, s); break;
        case "opacity":         if (f != null) { cv.baseOpacity = f; if (!animDriver.isOwned(h, "opacity")) cv.view.setAlpha(f); } break;
        case "aspectRatio":   if (f != null) y.setAspectRatio(f); break;
        case "display":       y.setDisplay("none".equals(s) ? YogaDisplay.NONE : YogaDisplay.FLEX); break;
        case "overflow":      applyOverflow(cv, s); break;
        case "elevation":     if (f != null) cv.view.setElevation(dp(f)); break;
        case "boxShadow": case "shadowRadius":
          cv.view.setElevation(shadowElevation(s)); break;
        case "transform":     cv.baseTransform = s; if (!animDriver.isOwned(h, "transform")) applyTransform(cv.view, s); break;
        case "color":
          if (cv.view instanceof TextView) { cv.textColor = parseColor(s); ((TextView) cv.view).setTextColor(cv.textColor); }
          break;
        case "fontSize":
          // Font metrics change the leaf's intrinsic size; Yoga caches leaf measures, so dirty it.
          if (f != null && cv.view instanceof TextView) { ((TextView) cv.view).setTextSize(TypedValue.COMPLEX_UNIT_SP, f); if (cv.isLeaf) cv.yoga.dirty(); }
          break;
        case "fontWeight":
          if (cv.view instanceof TextView) {
            Float w = asFloat(s);
            boolean bold = "bold".equals(s) || (w != null && w >= 600);
            ((TextView) cv.view).setTypeface(null, bold ? android.graphics.Typeface.BOLD : android.graphics.Typeface.NORMAL);
            if (cv.isLeaf) cv.yoga.dirty();
          }
          break;
        case "textAlign":
          if (cv.view instanceof TextView)
            ((TextView) cv.view).setGravity(
                "center".equals(s) ? Gravity.CENTER
                : "right".equals(s) ? Gravity.END
                : "left".equals(s) ? Gravity.START : Gravity.START);
          break;
        default: break;
      }
    }
  }

  private interface FloatSetter { void set(float v); }
  private interface VoidSetter { void set(); }

  private void setDim(String s, Float f, FloatSetter px, FloatSetter pct, VoidSetter auto) {
    if (s != null && s.endsWith("%")) {
      Float p = asFloat(s.substring(0, s.length() - 1));
      if (p != null) pct.set(p);
    } else if ("auto".equals(s)) {
      auto.set();
    } else if (f != null) {
      px.set(dp(f));
    }
  }

  // Reset one style property to its Yoga/view default — used when a diff removes a key
  // (value arrives as JSON null) so a recycled view drops the prior screen's styling.
  private void resetStyleKey(int h, CView cv, YogaNode y, String key) {
    switch (key) {
      case "width":  y.setWidthAuto(); break;
      case "height": y.setHeightAuto(); break;
      case "minWidth":  y.setMinWidth(YogaConstants.UNDEFINED); break;
      case "minHeight": y.setMinHeight(YogaConstants.UNDEFINED); break;
      case "maxWidth":  y.setMaxWidth(YogaConstants.UNDEFINED); break;
      case "maxHeight": y.setMaxHeight(YogaConstants.UNDEFINED); break;
      // setFlex(1) is a Yoga SHORTHAND: while a flex value is set, resolved flexGrow/shrink
      // come from it and override setFlexGrow(0). Clearing the shorthand (UNDEFINED) is
      // required for a reused flex:1 column to drop back to its height (else it stays
      // flexBasis:0 / no-grow → 0px). Then pin the individual defaults.
      case "flex":       y.setFlex(YogaConstants.UNDEFINED); y.setFlexGrow(0); y.setFlexShrink(0); y.setFlexBasisAuto(); break;
      case "flexGrow":   y.setFlexGrow(0); break;
      case "flexShrink": y.setFlexShrink(0); break;
      case "flexBasis":  y.setFlexBasisAuto(); break;
      case "gap":        y.setGap(YogaGutter.ALL, 0); break;
      case "padding": case "paddingTop": case "paddingBottom": case "paddingLeft":
      case "paddingRight": case "paddingHorizontal": case "paddingVertical":
      case "paddingStart": case "paddingEnd":
        y.setPadding(edgeFor(key), 0); break;
      case "margin": case "marginTop": case "marginBottom": case "marginLeft":
      case "marginRight": case "marginHorizontal": case "marginVertical":
      case "marginStart": case "marginEnd":
        y.setMargin(edgeFor(key), 0); break;
      case "top":    y.setPosition(YogaEdge.TOP, YogaConstants.UNDEFINED); break;
      case "bottom": y.setPosition(YogaEdge.BOTTOM, YogaConstants.UNDEFINED); break;
      case "left":   y.setPosition(YogaEdge.LEFT, YogaConstants.UNDEFINED); break;
      case "right":  y.setPosition(YogaEdge.RIGHT, YogaConstants.UNDEFINED); break;
      case "start":  y.setPosition(YogaEdge.START, YogaConstants.UNDEFINED); break;
      case "end":    y.setPosition(YogaEdge.END, YogaConstants.UNDEFINED); break;
      case "direction":      y.setDirection(YogaDirection.INHERIT); break;
      case "position":       y.setPositionType(YogaPositionType.RELATIVE); break;
      case "flexDirection":  y.setFlexDirection(YogaFlexDirection.COLUMN); break;
      case "justifyContent": y.setJustifyContent(YogaJustify.FLEX_START); break;
      case "alignItems":     y.setAlignItems(YogaAlign.STRETCH); break;
      case "alignSelf":      y.setAlignSelf(YogaAlign.AUTO); break;
      case "backgroundColor": cv.bgColor = null; applyBackground(cv); break;
      case "borderRadius":    cv.borderRadius = 0f; cv.corners = null; applyBackground(cv); break;
      case "borderTopLeftRadius": case "borderTopRightRadius":
      case "borderBottomRightRadius": case "borderBottomLeftRadius":
        cv.corners = null; applyBackground(cv); break;
      case "borderWidth":     cv.borderWidth = 0f; y.setBorder(YogaEdge.ALL, YogaConstants.UNDEFINED); applyBackground(cv); break;
      case "borderColor":     cv.borderColor = null; applyBackground(cv); break;
      case "border":          cv.borderWidth = 0f; cv.borderColor = null; y.setBorder(YogaEdge.ALL, YogaConstants.UNDEFINED); applyBackground(cv); break;
      case "opacity":         cv.baseOpacity = 1f; if (!animDriver.isOwned(h, "opacity")) cv.view.setAlpha(1f); break;
      case "aspectRatio":     y.setAspectRatio(YogaConstants.UNDEFINED); break;
      case "display":         y.setDisplay(YogaDisplay.FLEX); break;
      case "overflow":        applyOverflow(cv, "visible"); break;
      case "elevation": case "boxShadow": case "shadowRadius": cv.view.setElevation(0f); break;
      case "transform":       cv.baseTransform = null; if (!animDriver.isOwned(h, "transform")) applyTransform(cv.view, null); break;
      // Text-style keys applyStyle SETS must also reset, else a reused TextView keeps the
      // prior screen's color/size/weight/alignment. Defaults match a bare TextView + the
      // CView field default (Color.BLACK / 14sp / NORMAL).
      case "color":
        if (cv.view instanceof TextView) { cv.textColor = Color.BLACK; ((TextView) cv.view).setTextColor(Color.BLACK); cv.yoga.dirty(); }
        break;
      case "fontSize":
        if (cv.view instanceof TextView) { ((TextView) cv.view).setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f); cv.yoga.dirty(); }
        break;
      case "fontWeight":
        if (cv.view instanceof TextView) { ((TextView) cv.view).setTypeface(null, android.graphics.Typeface.NORMAL); cv.yoga.dirty(); }
        break;
      case "textAlign":
        if (cv.view instanceof TextView) ((TextView) cv.view).setGravity(Gravity.START);
        break;
      case "flexWrap":
        y.setWrap(YogaWrap.NO_WRAP);
        break;
      default: break;
    }
  }

  private YogaEdge edgeFor(String key) {
    if (key.endsWith("Top")) return YogaEdge.TOP;
    if (key.endsWith("Bottom")) return YogaEdge.BOTTOM;
    if (key.endsWith("Left")) return YogaEdge.LEFT;
    if (key.endsWith("Right")) return YogaEdge.RIGHT;
    if (key.endsWith("Start")) return YogaEdge.START;
    if (key.endsWith("End")) return YogaEdge.END;
    if (key.endsWith("Horizontal")) return YogaEdge.HORIZONTAL;
    if (key.endsWith("Vertical")) return YogaEdge.VERTICAL;
    return YogaEdge.ALL;
  }

  private void applyBackground(CView cv) {
    boolean hasRound = cv.borderRadius > 0f || cv.corners != null;
    boolean hasBorder = cv.borderWidth > 0f && cv.borderColor != null;
    if (cv.bgColor == null && !hasRound && !hasBorder) { cv.view.setBackground(null); return; }
    // Any of fill / rounded corners / stroke needs the shape drawable (a flat color cannot carry
    // a corner radius or a stroke). Only the plain solid-fill case uses setBackgroundColor.
    if (hasRound || hasBorder) {
      GradientDrawable d = new GradientDrawable();
      d.setShape(GradientDrawable.RECTANGLE);
      if (cv.corners != null) {
        // GradientDrawable wants 8 values: per corner [x,y] for TL,TR,BR,BL.
        float[] c = cv.corners;
        d.setCornerRadii(new float[]{ c[0], c[0], c[1], c[1], c[2], c[2], c[3], c[3] });
      } else if (cv.borderRadius > 0f) {
        d.setCornerRadius(cv.borderRadius);
      }
      if (cv.bgColor != null) d.setColor(cv.bgColor);
      if (hasBorder) d.setStroke(Math.round(cv.borderWidth), cv.borderColor);
      cv.view.setBackground(d);
      // A rounded background also clips its own content (e.g. an ImageView's bitmap) to the
      // corners when overflow:hidden asked for clipToOutline — the outline derives from this.
    } else {
      cv.view.setBackgroundColor(cv.bgColor);
    }
  }

  /** borderRadius: uniform ("16") OR the 4-corner shorthand ("16 0 0 0" = TL TR BR BL). */
  private void applyBorderRadius(CView cv, String s, Float f) {
    if (s != null && s.trim().contains(" ")) {
      String[] p = s.trim().split("\\s+");
      if (p.length == 4) {
        cv.corners = new float[]{ dp(orZero(p[0])), dp(orZero(p[1])), dp(orZero(p[2])), dp(orZero(p[3])) };
        applyBackground(cv);
        return;
      }
    }
    if (f != null) { cv.borderRadius = dp(f); cv.corners = null; applyBackground(cv); }
  }

  private static float orZero(String t) { Float v = asFloat(t); return v == null ? 0f : v; }

  private void setCorner(CView cv, int idx, Float f) {
    if (f == null) return;
    if (cv.corners == null) {
      // Seed from any uniform radius already set so mixing uniform + per-corner is coherent.
      float u = cv.borderRadius;
      cv.corners = new float[]{ u, u, u, u };
    }
    cv.corners[idx] = dp(f);
    applyBackground(cv);
  }

  /** `border: <width> [style] <color>` → width (number) + color (last color-ish token). */
  private void applyBorderShorthand(CView cv, YogaNode y, String s) {
    if (s == null) return;
    for (String tok : s.trim().split("\\s+")) {
      Float w = asFloat(tok);
      if (w != null) { cv.borderWidth = dp(w); y.setBorder(YogaEdge.ALL, dp(w)); }
      else if (tok.startsWith("#") || tok.startsWith("rgb") || tok.startsWith("hsl")) cv.borderColor = parseColor(tok);
      else if (!"solid".equals(tok) && !"none".equals(tok) && !tok.isEmpty()) cv.borderColor = parseColor(tok); // named color
    }
    applyBackground(cv);
  }

  /** overflow:hidden → clip children + clip the bitmap/content to the (possibly rounded) outline. */
  private void applyOverflow(CView cv, String s) {
    boolean hidden = "hidden".equals(s) || "scroll".equals(s);
    cv.view.setClipToOutline(hidden);
    if (cv.view instanceof ViewGroup) ((ViewGroup) cv.view).setClipChildren(hidden);
  }

  /** A CSS box-shadow / shadowRadius → an Android elevation (dp of the largest length token). */
  private float shadowElevation(String s) {
    if (s == null) return 0f;
    float max = 0f;
    for (String tok : s.split("[\\s,()]+")) {
      Float v = asFloat(tok.endsWith("px") ? tok.substring(0, tok.length() - 2) : tok);
      if (v != null && v > max) max = v;
    }
    return dp(max);
  }

  /** Apply a CSS transform list — translate(x,y)/translateX/Y, scale(x,y)/scaleX/Y, rotate(deg).
   * canopy/css renders multi-arg forms ("translate(10px, 20px)", "scale(1.2, 1.2)"). null → reset. */
  private void applyTransform(View v, String s) {
    if (s == null || s.isEmpty()) {
      v.setTranslationX(0); v.setTranslationY(0);
      v.setScaleX(1); v.setScaleY(1); v.setRotation(0);
      return;
    }
    float tx = 0, ty = 0, sx = 1, sy = 1, rot = 0;
    java.util.regex.Matcher m = java.util.regex.Pattern.compile("([a-zA-Z0-9]+)\\(([^)]*)\\)").matcher(s);
    while (m.find()) {
      String fn = m.group(1);
      String[] args = m.group(2).split(",");
      Float a0 = unit(args.length > 0 ? args[0] : null);
      Float a1 = unit(args.length > 1 ? args[1] : null);
      switch (fn) {
        case "translate":  if (a0 != null) tx = dp(a0); if (a1 != null) ty = dp(a1); break;
        case "translateX": if (a0 != null) tx = dp(a0); break;
        case "translateY": if (a0 != null) ty = dp(a0); break;
        case "scale":  if (a0 != null) { sx = a0; sy = (a1 != null ? a1 : a0); } break;
        case "scaleX": if (a0 != null) sx = a0; break;
        case "scaleY": if (a0 != null) sy = a0; break;
        case "rotate": case "rotateZ": if (a0 != null) rot = a0; break;
        default: break;
      }
    }
    v.setTranslationX(tx); v.setTranslationY(ty);
    v.setScaleX(sx); v.setScaleY(sy); v.setRotation(rot);
  }

  /** Parse a transform component, dropping a px/deg unit suffix. */
  private static Float unit(String t) {
    if (t == null) return null;
    t = t.trim();
    if (t.endsWith("px")) t = t.substring(0, t.length() - 2);
    else if (t.endsWith("deg")) t = t.substring(0, t.length() - 3);
    return asFloat(t);
  }

  /** Parse the declarative `animations` prop and drive each spec via the Choreographer animator.
   * Empty/null clears all + restores the cached static opacity/transform (the clearing diff carries
   * no `style` key, so the driver must reclaim the resting value itself). start() is idempotent
   * against an identical spec, so the per-render re-send of `animations` does not restart anything. */
  private void applyAnimations(int h, CView cv, JSONObject props) {
    String specJson = props.isNull("animations") ? null : props.optString("animations", null);
    org.json.JSONArray arr = null;
    if (specJson != null && !specJson.isEmpty()) {
      try { arr = new org.json.JSONArray(specJson); } catch (Exception e) { arr = null; }
    }
    if (arr == null || arr.length() == 0) {
      animDriver.cancelAll(h);
      cv.view.setAlpha(cv.baseOpacity);
      applyTransform(cv.view, cv.baseTransform);
      return;
    }
    boolean[] present = new boolean[com.canopyhost.views.CanopyAnimDriver.PROP_COUNT];
    for (int i = 0; i < arr.length(); i++) {
      JSONObject spec = arr.optJSONObject(i);
      if (spec == null) continue;
      int ord = com.canopyhost.views.CanopyAnimDriver.propOrdinal(spec.optString("prop", ""));
      if (ord < 0) continue;
      present[ord] = true;
      float to = (float) spec.optDouble("to", 0);
      float from = (spec.has("from") && !spec.isNull("from")) ? (float) spec.optDouble("from") : Float.NaN;
      long duration = spec.optLong("duration", 300);
      long delay = spec.optLong("delay", 0);
      JSONObject ez = spec.optJSONObject("easing");
      String kind = (ez != null) ? ez.optString("kind", "easeInOut") : "easeInOut";
      boolean isSpring = "spring".equals(kind);
      float stiffness = (ez != null) ? (float) ez.optDouble("stiffness", 180) : 180;
      float damping = (ez != null) ? (float) ez.optDouble("damping", 12) : 12;
      float mass = (ez != null) ? (float) ez.optDouble("mass", 1) : 1;
      int easing = com.canopyhost.views.CanopyAnimDriver.easingOrdinal(kind);
      animDriver.start(h, cv.view, ord, from, to, duration, delay, easing, isSpring, stiffness, damping, mass);
    }
    animDriver.cancelMissing(h, present); // a prop dropped from the spec stops owning its value
  }

  // ---- the Yoga-driven container -------------------------------------------

  private final YogaMeasureFunction leafMeasure = new YogaMeasureFunction() {
    @Override
    public long measure(YogaNode node, float width, YogaMeasureMode wMode, float height, YogaMeasureMode hMode) {
      CView cv = views.get((Integer) node.getData());
      if (cv == null) return YogaMeasureOutput.make(0, 0);
      cv.view.measure(spec(width, wMode), spec(height, hMode));
      return YogaMeasureOutput.make(cv.view.getMeasuredWidth(), cv.view.getMeasuredHeight());
    }
  };

  private final class YogaViewGroup extends ViewGroup {
    YogaViewGroup(Context c) { super(c); }

    private YogaNode node(View v) {
      Object t = v.getTag();
      return t instanceof CView ? ((CView) t).yoga : null;
    }

    @Override
    protected void onMeasure(int wSpec, int hSpec) {
      YogaNode self = node(this);
      if (self != null && self.getOwner() == null) {
        float w = MeasureSpec.getMode(wSpec) == MeasureSpec.UNSPECIFIED ? YogaConstants.UNDEFINED : MeasureSpec.getSize(wSpec);
        float h = MeasureSpec.getMode(hSpec) == MeasureSpec.UNSPECIFIED ? YogaConstants.UNDEFINED : MeasureSpec.getSize(hSpec);
        self.calculateLayout(w, h); // computes the WHOLE tree (leaf measure fns run here)
      }
      for (int i = 0; i < getChildCount(); i++) {
        View ch = getChildAt(i);
        YogaNode cn = node(ch);
        if (cn != null) {
          ch.measure(MeasureSpec.makeMeasureSpec(Math.round(cn.getLayoutWidth()), MeasureSpec.EXACTLY),
                     MeasureSpec.makeMeasureSpec(Math.round(cn.getLayoutHeight()), MeasureSpec.EXACTLY));
        }
      }
      if (self != null) {
        setMeasuredDimension(Math.round(self.getLayoutWidth()), Math.round(self.getLayoutHeight()));
      } else {
        setMeasuredDimension(MeasureSpec.getSize(wSpec), MeasureSpec.getSize(hSpec));
      }
    }

    @Override
    protected void onLayout(boolean changed, int l, int t, int r, int b) {
      for (int i = 0; i < getChildCount(); i++) {
        View ch = getChildAt(i);
        YogaNode cn = node(ch);
        if (cn != null) {
          int x = Math.round(cn.getLayoutX());
          int y = Math.round(cn.getLayoutY());
          ch.layout(x, y, x + Math.round(cn.getLayoutWidth()), y + Math.round(cn.getLayoutHeight()));
        }
      }
    }
  }

  // ---- helpers --------------------------------------------------------------

  private void requestRelayout() {
    if (root < 0) return;
    View rv = views.get(root).view;
    rv.requestLayout();
    rv.invalidate();
  }

  private float dp(float v) { return v * density; }

  private int spec(float size, YogaMeasureMode mode) {
    if (mode == YogaMeasureMode.EXACTLY) return View.MeasureSpec.makeMeasureSpec((int) size, View.MeasureSpec.EXACTLY);
    if (mode == YogaMeasureMode.AT_MOST) return View.MeasureSpec.makeMeasureSpec((int) size, View.MeasureSpec.AT_MOST);
    return View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED);
  }

  private static YogaJustify justify(String s) {
    switch (s == null ? "" : s) {
      case "center": return YogaJustify.CENTER;
      case "flex-end": return YogaJustify.FLEX_END;
      case "space-between": return YogaJustify.SPACE_BETWEEN;
      case "space-around": return YogaJustify.SPACE_AROUND;
      case "space-evenly": return YogaJustify.SPACE_EVENLY;
      default: return YogaJustify.FLEX_START;
    }
  }

  private static YogaAlign align(String s) {
    switch (s == null ? "" : s) {
      case "center": return YogaAlign.CENTER;
      case "flex-end": return YogaAlign.FLEX_END;
      case "stretch": return YogaAlign.STRETCH;
      default: return YogaAlign.FLEX_START;
    }
  }

  private int indexOf(YogaNode child) {
    YogaNode parent = child.getOwner();
    if (parent == null) return -1;
    for (int i = 0; i < parent.getChildCount(); i++)
      if (parent.getChildAt(i) == child) return i;
    return -1;
  }

  private static Float asFloat(String s) {
    try { return Float.parseFloat(s); } catch (Exception e) { return null; }
  }

  private static int parseColor(String s) {
    // Full CSS color surface: #hex(3/4/6/8 in CSS #RRGGBBAA order), rgb()/rgba(), hsl()/hsla(),
    // named, transparent. (android.graphics.Color.parseColor threw on rgb()/hsl() → invisible UI.)
    return com.canopyhost.views.CanopyColor.parse(s);
  }

  /** RN resizeMode → ImageView.ScaleType (cover/contain/stretch/center; default cover). */
  private static ImageView.ScaleType scaleType(String mode) {
    switch (mode) {
      case "contain": return ImageView.ScaleType.FIT_CENTER;
      case "stretch": return ImageView.ScaleType.FIT_XY;
      case "center":  return ImageView.ScaleType.CENTER;
      case "repeat":  return ImageView.ScaleType.FIT_XY; // no true tile mode on a bare ImageView
      case "cover":
      default:        return ImageView.ScaleType.CENTER_CROP;
    }
  }

  /** Minimal JSON string literal (quotes + escapes) for an event payload. */
  private static String jsonStr(String s) {
    if (s == null) return "null";
    StringBuilder b = new StringBuilder("\"");
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      switch (c) {
        case '"':  b.append("\\\""); break;
        case '\\': b.append("\\\\"); break;
        case '\n': b.append("\\n"); break;
        case '\r': b.append("\\r"); break;
        case '\t': b.append("\\t"); break;
        default:
          if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
          else b.append(c);
      }
    }
    return b.append('"').toString();
  }
}
