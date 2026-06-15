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
import java.util.Map;

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

  // ---- __fabric_* surface ---------------------------------------------------

  public int createView(String fabricName, String propsJson) {
    int h = next++;
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
    surface.addView(rv, new ViewGroup.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    requestRelayout();
  }

  public void setEvents(int h, String namesJson) {
    CView cv = views.get(h);
    if (cv == null || namesJson == null) return;
    if (cv.view instanceof com.canopyhost.views.CanopyScrollView) {
      // A ScrollView owns its own scroll + refresh listeners; only emit when the app subscribes.
      com.canopyhost.views.CanopyScrollView sv = (com.canopyhost.views.CanopyScrollView) cv.view;
      sv.setEmitScroll(namesJson.contains("\"scroll\""));
      sv.setEmitRefresh(namesJson.contains("\"refresh\""));
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
      // TextInput (RCTSinglelineTextInputView): controlled value + placeholder/keyboard/secure.
      if (cv.view instanceof com.canopyhost.views.CanopyTextInput) {
        com.canopyhost.views.CanopyTextInput ti = (com.canopyhost.views.CanopyTextInput) cv.view;
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
      if (props.has("resizeMode") && cv.view instanceof ImageView) {
        ((ImageView) cv.view).setScaleType(scaleType(props.isNull("resizeMode") ? "cover" : props.optString("resizeMode", "cover")));
      }
      // RCTImageView declarative `source` (URL/file/asset/content) → async load via CanopyImageLoader.
      // Guarded by lastSource so an unchanged source on re-render does not re-fetch; the async
      // callback re-checks lastSource so a recycled view never shows a previous source's pixels.
      if (props.has("source") && cv.view instanceof ImageView && !props.has("bitmapHandle")) {
        String src = props.isNull("source") ? null : props.optString("source", null);
        if (src == null || src.isEmpty()) {
          cv.lastSource = null;
          ((ImageView) cv.view).setImageDrawable(null);
          cv.yoga.dirty();
        } else if (!src.equals(cv.lastSource)) {
          cv.lastSource = src;
          final int targetW = Math.round(cv.yoga.getLayoutWidth());
          final int targetH = Math.round(cv.yoga.getLayoutHeight());
          final ImageView iv = (ImageView) cv.view;
          com.canopyhost.views.CanopyImageLoader.load(context, src, targetW, targetH, (bmp, error) -> {
            if (!src.equals(cv.lastSource)) return; // recycled to a different source meanwhile — drop
            if (bmp != null) {
              iv.setImageBitmap(bmp);
              cv.yoga.dirty();
              requestRelayout();
              CanopyHostJni.emitEvent(h, "load", "{}");
            } else {
              CanopyHostJni.emitEvent(h, "error", "{\"error\":" + jsonStr(error) + "}");
            }
            CanopyHostJni.emitEvent(h, "loadEnd", "{}");
          });
        }
      }
      // C2 BeforeAfter compositor: before/after handles + the native wipe fraction.
      if (cv.view instanceof com.canopyhost.views.BeforeAfterView) {
        com.canopyhost.views.BeforeAfterView ba = (com.canopyhost.views.BeforeAfterView) cv.view;
        if (props.has("beforeHandle")) ba.setBeforeHandle(props.isNull("beforeHandle") ? 0 : props.optInt("beforeHandle", 0));
        if (props.has("afterHandle"))  ba.setAfterHandle(props.isNull("afterHandle") ? 0 : props.optInt("afterHandle", 0));
        if (props.has("wipeFraction")) ba.setWipeFraction(props.isNull("wipeFraction") ? 0.5f : (float) props.optDouble("wipeFraction", 0.5));
      }
      // Modal (CanopyModalHost): config the overlay, then toggle visibility LAST so transparency
      // + animation are in place before the Dialog shows.
      if (cv.view instanceof com.canopyhost.views.CanopyModalHost) {
        com.canopyhost.views.CanopyModalHost mh = (com.canopyhost.views.CanopyModalHost) cv.view;
        if (props.has("transparent")) mh.setTransparent("true".equals(props.optString("transparent")));
        if (props.has("animationType")) mh.setAnimationType(props.optString("animationType"));
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
        y.setPadding(edgeFor(key), 0); break;
      case "margin": case "marginTop": case "marginBottom": case "marginLeft":
      case "marginRight": case "marginHorizontal": case "marginVertical":
        y.setMargin(edgeFor(key), 0); break;
      case "top":    y.setPosition(YogaEdge.TOP, YogaConstants.UNDEFINED); break;
      case "bottom": y.setPosition(YogaEdge.BOTTOM, YogaConstants.UNDEFINED); break;
      case "left":   y.setPosition(YogaEdge.LEFT, YogaConstants.UNDEFINED); break;
      case "right":  y.setPosition(YogaEdge.RIGHT, YogaConstants.UNDEFINED); break;
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
