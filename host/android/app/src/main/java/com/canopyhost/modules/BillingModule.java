// BillingModule.java — the Android host module behind canopy/billing (module "Billing").
//
// REAL Play Billing v6 (com.android.billingclient) with an automatic FAKE-STORE fallback.
// The production path uses BillingClient (connect → queryProductDetails → launchBillingFlow →
// PurchasesUpdatedListener → acknowledge → queryPurchases). When the real store is unavailable
// (no Play Services, not signed in, or the product is not configured in Play Console — i.e. dev,
// CI, and the emulator), it transparently falls back to the local fake store so the app keeps
// working with the IDENTICAL JSON wire contract. The entitlement persists in private prefs and is
// shared by both paths, so a real purchase and a dev grant look the same to the Canopy side.
//
// Streaming carve-out: billing has a SUBSCRIPTION (entitlementChanges), so its C++ side is a real
// canopy::NativeModule (BillingModule.{h,cpp}); one-shots delegate here over the JNI-module
// mechanism, and the streaming half is fed by nativeEmit (exported by BillingModule.cpp).
//
// Wire contract (must match billing.js / Billing.can):
//   getProducts  null|{}      -> {"products":[Product,...]}
//   purchase     {productId}  -> {productId, transactionId, entitlement:{isActive,productId}}
//   restore      null|{}      -> {isActive, productId}
//   entitlementChanges        -> handled in C++ (stream); Java only pushes via nativeEmit
//   Product = {id,title,description,priceText,priceMicros,currencyCode}
//
// [PLAY-CONSOLE-VALIDATE]: the launchBillingFlow purchase + acknowledge path requires a Play
// merchant account with a configured "lifetime_unlock" in-app product and a signed-in test
// account; it cannot be exercised on a bare emulator. The connection + product query + the
// fake fallback ARE exercised here.

package com.canopyhost.modules;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Handler;
import android.os.Looper;

import com.android.billingclient.api.AcknowledgePurchaseParams;
import com.android.billingclient.api.BillingClient;
import com.android.billingclient.api.BillingClient.BillingResponseCode;
import com.android.billingclient.api.BillingClient.ProductType;
import com.android.billingclient.api.BillingClientStateListener;
import com.android.billingclient.api.BillingFlowParams;
import com.android.billingclient.api.BillingResult;
import com.android.billingclient.api.ProductDetails;
import com.android.billingclient.api.Purchase;
import com.android.billingclient.api.PurchasesUpdatedListener;
import com.android.billingclient.api.QueryProductDetailsParams;
import com.android.billingclient.api.QueryPurchasesParams;

import com.canopyhost.CanopyHostJni;
import com.canopyhost.MainActivity;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class BillingModule {

  private static final String PRODUCT_ID = "lifetime_unlock";
  private static final String PREFS = "canopy_billing";
  private static final String KEY_ACTIVE = "entitlement_active";
  private static final String KEY_PRODUCT = "entitlement_product";

  private static final ExecutorService EXEC = Executors.newSingleThreadExecutor();
  private static final Handler MAIN = new Handler(Looper.getMainLooper());

  /** Pushes one entitlement JSON to every live entitlementChanges Sub (exported by BillingModule.cpp). */
  private static native void nativeEmit(String entitlementJson);

  // ---- real Play Billing state (all touched on the main thread) --------------
  private static BillingClient client;
  private static int connState = 0; // 0 disconnected, 1 connecting, 2 connected, 3 unavailable
  private static ProductDetails cachedProduct;
  private static volatile String pendingPurchaseCallId; // parked across launchBillingFlow -> listener

  private static final PurchasesUpdatedListener PURCHASES_UPDATED = (result, purchases) -> {
    int code = result.getResponseCode();
    if (code == BillingResponseCode.OK && purchases != null) {
      for (Purchase p : purchases) handlePurchase(p);
    } else if (code == BillingResponseCode.USER_CANCELED) {
      // Wire contract: Billing.can:182 maps the code "user_cancelled" -> UserCancelled.
      // Emitting "cancelled" here never matched, so a user-dismissed sheet surfaced as a
      // generic error instead of the quiet UserCancelled case.
      finishPending(null, "user_cancelled", "user canceled");
    } else if (code == BillingResponseCode.ITEM_ALREADY_OWNED) {
      EXEC.execute(() -> { persist(true, PRODUCT_ID); finishPending(entitlementPurchaseJson(), null, null); nativeEmit(entitlementJson()); });
    } else {
      finishPending(null, "rejected", "billing " + code);
    }
  };

  /** Dispatcher entry. invoke() returns immediately; real BillingClient callbacks hop via MAIN/EXEC. */
  public static void invoke(String method, String argsJson, String callId) {
    EXEC.execute(() -> {
      try {
        boolean noArgs = argsJson == null || argsJson.isEmpty() || argsJson.equals("null");
        JSONObject args = new JSONObject(noArgs ? "{}" : argsJson);
        switch (method) {
          case "getProducts":
            ensureConnected(() -> realGetProducts(callId), () -> safe(callId, () -> fakeGetProducts(callId)));
            break;
          case "purchase":
            ensureConnected(() -> realPurchase(args, callId), () -> safe(callId, () -> fakePurchase(args, callId)));
            break;
          case "restore":
            ensureConnected(() -> realRestore(callId), () -> safe(callId, () -> fakeRestore(callId)));
            break;
          default:
            reject(callId, "rejected", "Billing." + method);
        }
      } catch (Throwable t) {
        reject(callId, "rejected", String.valueOf(t.getMessage()));
      }
    });
  }

  // ---- connection (main thread) ---------------------------------------------

  private static void ensureConnected(Runnable onReady, Runnable onUnavailable) {
    MAIN.post(() -> {
      if (connState == 2 && client != null && client.isReady()) { EXEC.execute(onReady); return; }
      if (connState == 3) { EXEC.execute(onUnavailable); return; }
      if (client == null) {
        client = BillingClient.newBuilder(MainActivity.appContext())
            .setListener(PURCHASES_UPDATED)
            .enablePendingPurchases()
            .build();
      }
      connState = 1;
      client.startConnection(new BillingClientStateListener() {
        @Override public void onBillingSetupFinished(BillingResult r) {
          if (r.getResponseCode() == BillingResponseCode.OK) { connState = 2; EXEC.execute(onReady); }
          else { connState = 3; EXEC.execute(onUnavailable); } // BILLING_UNAVAILABLE / FEATURE_NOT_SUPPORTED → fake
        }
        @Override public void onBillingServiceDisconnected() { connState = 0; }
      });
    });
  }

  // ---- real getProducts ------------------------------------------------------

  private static void realGetProducts(String callId) {
    QueryProductDetailsParams params = QueryProductDetailsParams.newBuilder()
        .setProductList(Collections.singletonList(
            QueryProductDetailsParams.Product.newBuilder()
                .setProductId(PRODUCT_ID).setProductType(ProductType.INAPP).build()))
        .build();
    client.queryProductDetailsAsync(params, (result, list) -> EXEC.execute(() -> {
      try {
        if (result.getResponseCode() == BillingResponseCode.OK && list != null && !list.isEmpty()) {
          cachedProduct = list.get(0);
          JSONArray products = new JSONArray();
          products.put(productToJson(cachedProduct));
          JSONObject out = new JSONObject();
          out.put("products", products);
          resolve(callId, out.toString());
          nativeEmit(entitlementJson());
        } else {
          fakeGetProducts(callId); // no product configured for this app → dev catalog
        }
      } catch (Exception e) { reject(callId, "rejected", String.valueOf(e.getMessage())); }
    }));
  }

  private static JSONObject productToJson(ProductDetails pd) throws Exception {
    ProductDetails.OneTimePurchaseOfferDetails offer = pd.getOneTimePurchaseOfferDetails();
    JSONObject p = new JSONObject();
    p.put("id", pd.getProductId());
    p.put("title", pd.getTitle());
    p.put("description", pd.getDescription());
    p.put("priceText", offer != null ? offer.getFormattedPrice() : "");
    p.put("priceMicros", offer != null ? offer.getPriceAmountMicros() : 0);
    p.put("currencyCode", offer != null ? offer.getPriceCurrencyCode() : "");
    return p;
  }

  // ---- real purchase ---------------------------------------------------------

  private static void realPurchase(JSONObject args, String callId) {
    if (!PRODUCT_ID.equals(args.optString("productId", ""))) { reject(callId, "item_unavailable", args.optString("productId")); return; }
    if (cachedProduct == null) { safe(callId, () -> fakePurchase(args, callId)); return; }
    if (isActive()) { reject(callId, "already_owned", PRODUCT_ID); return; }
    pendingPurchaseCallId = callId;
    MAIN.post(() -> {
      Activity act = MainActivity.current();
      if (act == null) { finishPending(null, "rejected", "no activity"); return; }
      BillingFlowParams flow = BillingFlowParams.newBuilder()
          .setProductDetailsParamsList(Collections.singletonList(
              BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(cachedProduct).build()))
          .build();
      BillingResult r = client.launchBillingFlow(act, flow);
      if (r.getResponseCode() != BillingResponseCode.OK) finishPending(null, "rejected", "launch " + r.getResponseCode());
      // success → result arrives via PURCHASES_UPDATED → handlePurchase
    });
  }

  private static void handlePurchase(Purchase purchase) {
    EXEC.execute(() -> {
      try {
        if (purchase.getPurchaseState() != Purchase.PurchaseState.PURCHASED) return;
        persist(true, PRODUCT_ID);
        if (!purchase.isAcknowledged()) {
          MAIN.post(() -> client.acknowledgePurchase(
              AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchase.getPurchaseToken()).build(), ar -> {}));
        }
        JSONObject entitlement = new JSONObject();
        entitlement.put("isActive", true);
        entitlement.put("productId", PRODUCT_ID);
        JSONObject p = new JSONObject();
        p.put("productId", PRODUCT_ID);
        p.put("transactionId", purchase.getOrderId() != null ? purchase.getOrderId() : purchase.getPurchaseToken());
        p.put("entitlement", entitlement);
        finishPending(p.toString(), null, null);
        nativeEmit(entitlement.toString());
      } catch (Exception e) { finishPending(null, "rejected", String.valueOf(e.getMessage())); }
    });
  }

  private static void finishPending(String resultJson, String code, String msg) {
    String cid = pendingPurchaseCallId;
    pendingPurchaseCallId = null;
    if (cid == null) return;
    if (resultJson != null) resolve(cid, resultJson);
    else reject(cid, code, msg);
  }

  private static String entitlementPurchaseJson() {
    try {
      JSONObject entitlement = new JSONObject();
      entitlement.put("isActive", true);
      entitlement.put("productId", PRODUCT_ID);
      JSONObject p = new JSONObject();
      p.put("productId", PRODUCT_ID);
      p.put("transactionId", "owned");
      p.put("entitlement", entitlement);
      return p.toString();
    } catch (Exception e) { return "{}"; }
  }

  // ---- real restore ----------------------------------------------------------

  private static void realRestore(String callId) {
    client.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(ProductType.INAPP).build(),
        (result, purchases) -> EXEC.execute(() -> {
          try {
            if (purchases != null) {
              for (Purchase p : purchases) {
                if (p.getProducts().contains(PRODUCT_ID) && p.getPurchaseState() == Purchase.PurchaseState.PURCHASED) {
                  persist(true, PRODUCT_ID);
                  if (!p.isAcknowledged()) {
                    MAIN.post(() -> client.acknowledgePurchase(
                        AcknowledgePurchaseParams.newBuilder().setPurchaseToken(p.getPurchaseToken()).build(), ar -> {}));
                  }
                }
              }
            }
            String json = entitlementJson(); // merged with any persisted dev grant
            resolve(callId, json);
            nativeEmit(json);
          } catch (Exception e) { reject(callId, "rejected", String.valueOf(e.getMessage())); }
        }));
  }

  // ---- fake store fallback (dev / CI / emulator / no-products) ----------------

  private static void fakeGetProducts(String callId) throws Exception {
    JSONObject product = new JSONObject();
    product.put("id", PRODUCT_ID);
    product.put("title", "Lifetime Unlock");
    product.put("description", "Unlock every feature forever — one payment, no subscription.");
    product.put("priceText", "$4.99");
    product.put("priceMicros", 4990000);
    product.put("currencyCode", "USD");
    JSONArray products = new JSONArray();
    products.put(product);
    JSONObject out = new JSONObject();
    out.put("products", products);
    resolve(callId, out.toString());
    nativeEmit(entitlementJson());
  }

  private static void fakePurchase(JSONObject args, String callId) throws Exception {
    String productId = args.optString("productId", "");
    if (!PRODUCT_ID.equals(productId)) { reject(callId, "item_unavailable", productId); return; }
    if (isActive()) { reject(callId, "already_owned", productId); return; }
    persist(true, productId);
    JSONObject entitlement = new JSONObject();
    entitlement.put("isActive", true);
    entitlement.put("productId", productId);
    JSONObject purchase = new JSONObject();
    purchase.put("productId", productId);
    purchase.put("transactionId", "dev-txn-" + System.currentTimeMillis());
    purchase.put("entitlement", entitlement);
    resolve(callId, purchase.toString());
    nativeEmit(entitlement.toString());
  }

  private static void fakeRestore(String callId) throws Exception {
    String json = entitlementJson();
    resolve(callId, json);
    nativeEmit(json);
  }

  // ---- persistence + helpers -------------------------------------------------

  private static SharedPreferences prefs() {
    Context c = MainActivity.appContext();
    if (c == null) { throw new IllegalStateException("Billing: no app context"); }
    return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
  }

  private static boolean isActive() { return prefs().getBoolean(KEY_ACTIVE, false); }

  private static void persist(boolean active, String productId) {
    prefs().edit().putBoolean(KEY_ACTIVE, active).putString(KEY_PRODUCT, active ? productId : "").apply();
  }

  private static String entitlementJson() {
    SharedPreferences p = prefs();
    try {
      JSONObject ent = new JSONObject();
      ent.put("isActive", p.getBoolean(KEY_ACTIVE, false));
      String productId = p.getString(KEY_PRODUCT, "");
      ent.put("productId", productId == null ? "" : productId);
      return ent.toString();
    } catch (Exception e) { return "{\"isActive\":false,\"productId\":\"\"}"; }
  }

  /** Run a throwing fallback, turning any error into a reject (keeps invoke() noexcept). */
  private interface ThrowingRun { void run() throws Exception; }
  private static void safe(String callId, ThrowingRun r) {
    try { r.run(); } catch (Throwable t) { reject(callId, "rejected", String.valueOf(t.getMessage())); }
  }

  private static void resolve(String callId, String resultJson) {
    CanopyHostJni.resolveModule(callId, "", resultJson);
  }

  private static void reject(String callId, String code, String message) {
    try {
      JSONObject err = new JSONObject();
      err.put("code", code);
      err.put("message", message == null ? "" : message);
      CanopyHostJni.resolveModule(callId, err.toString(), "");
    } catch (Exception e) {
      CanopyHostJni.resolveModule(callId, "{\"code\":\"rejected\"}", "");
    }
  }

  private BillingModule() {}
}
