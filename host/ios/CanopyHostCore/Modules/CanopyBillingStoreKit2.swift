// CanopyBillingStoreKit2.swift — the real StoreKit 2 driver behind canopy/billing on iOS (L-I5).
//
// StoreKit 2 (Product / Transaction / VerificationResult) is a Swift-only, async/await API — it has
// NO Objective-C surface. So the StoreKit 2 logic lives HERE, in Swift, and CanopyBillingModule.mm
// calls into it through the small @objc surface below. This is the iOS analog of L-A4's REAL Play
// Billing path (BillingModule.java's BillingClient half): the production store logic, with the SAME
// JSON wire contract, and the SAME automatic fall-back to a fake store when no product resolves
// (unconfigured dev build / Simulator with no .storekit config / no signed-in sandbox account).
//
// SPLIT OF RESPONSIBILITY (mirrors the .mm header):
//   • One-shots — getProducts / purchase / restore — run HERE against StoreKit 2:
//       getProducts  -> Product.products(for:)                  -> {"products":[Product,…]}
//       purchase     -> product.purchase() + Transaction verify -> {productId,transactionId,entitlement}
//       restore      -> Transaction.currentEntitlements         -> {isActive, productId}
//     Each resolves the ObjC CanopyComplete block with the EXACT JSON billing.js / Billing.can /
//     BillingModule.java emit, so the Canopy side cannot tell which platform/store served it.
//   • Streaming (entitlementChanges) stays in the portable canopy::BillingModule (the .mm forwards
//     it). Whenever StoreKit 2 observes an entitlement change — a purchase, a restore, or an
//     out-of-band Transaction.updates event (a refund, an Ask-to-Buy approval, a Family-Sharing
//     grant) — this driver calls back into the .mm so it pushes the new entitlement onto every live
//     sub via canopy::billingEmitEntitlement (the same symbol the Android nativeEmit forwards to).
//
// PERSISTENCE / OFFLINE: Transaction.currentEntitlements IS the StoreKit-cached source of truth, so
// the unlock survives restarts and resolves offline with NO secure cache of our own (the role
// Storage.Secure plays for the Android fake store). The .mm still mirrors the last entitlement into
// NSUserDefaults so a fresh subscriber and the fake-store fallback share one persisted bit.
//
// VERIFICATION: every Transaction / Product purchase result arrives wrapped in VerificationResult.
// We accept a transaction ONLY when it is `.verified` (StoreKit checked the App Store JWS signature
// on-device); a `.unverified` result is treated as NOT entitling (it never grants the unlock), the
// fail-closed posture the App Store expects.
//
// The whole type is gated on iOS 15 (the StoreKit 2 floor, == project.yml deploymentTarget). On an
// older OS the .mm never constructs it and uses the StoreKit-1 / fake-store path. The class is @objc
// + NSObject so CanopyBillingModule.mm resolves it through the generated CanopyHostCore-Swift.h and
// the by-name bridge can't accidentally register it (it is NOT a <CanopyModule>; it is a helper the
// ObjC++ module owns).

import Foundation
import StoreKit

/// The single non-consumable product the store sells — a lifetime unlock. Must match
/// CanopyBillingModule.mm's kProductId, billing.js's BILLING_PRODUCT, and BillingModule.java's
/// PRODUCT_ID, AND the product id in CanopyHostApp/Products.storekit (the Simulator config).
private let kCanopyBillingProductId = "lifetime_unlock"

/// The ObjC-visible StoreKit 2 driver. CanopyBillingModule.mm owns one instance and forwards the
/// three one-shots to it; the driver resolves the ObjC `CanopyComplete` block with the wire JSON.
/// Every callback hops back through the block (which the registry re-marshals onto the JS thread),
/// so this driver freely runs StoreKit's async work on its own Task and never touches the runtime.
@available(iOS 15.0, *)
@objcMembers
public final class CanopyBillingStoreKit2: NSObject {

  /// The ObjC resolve/reject sink, identical to <CanopyModule>'s CanopyComplete:
  ///   err == nil  → success, `result` is the payload JSON.
  ///   err != nil  → rejection, `err` is a {"code","message"} JSON object.
  /// Bridged to a Swift closure here; the .mm passes the block straight through.
  public typealias Complete = (_ err: String?, _ result: String?) -> Void

  /// Pushed by the driver whenever it observes a new entitlement (purchase / restore /
  /// Transaction.updates). The .mm sets this to a closure that forwards the JSON into
  /// canopy::billingEmitEntitlement so every live entitlementChanges sub sees it. The JSON is a
  /// {"isActive":Bool,"productId":String} Entitlement.
  public var onEntitlementChange: ((String) -> Void)?

  /// The long-lived Transaction.updates listener task (refunds, Ask-to-Buy, Family Sharing,
  /// renewals). Started at init, cancelled at deinit. Keeps the cached entitlement honest even when
  /// the change happens entirely outside an in-app purchase flow.
  private var updatesListener: Task<Void, Never>?

  public override init() {
    super.init()
    startTransactionListener()
  }

  deinit {
    updatesListener?.cancel()
  }

  // MARK: - getProducts

  /// Resolve {"products":[Product,…]} from StoreKit 2's Product.products(for:). Returns `false`
  /// (no products) via the empty-array signal so the .mm knows to fall back to the fake catalog; a
  /// REAL configured product resolves the real metadata. A StoreKit error is reported as "no
  /// products" too (the .mm's getProducts then serves the dev catalog), never a hard reject — the
  /// paywall must always be able to render a price.
  public func getProducts(_ complete: @escaping Complete) {
    Task {
      do {
        let products = try await Product.products(for: [kCanopyBillingProductId])
        if let product = products.first {
          let payload: [String: Any] = ["products": [Self.productJSON(product)]]
          complete(nil, Self.jsonString(payload))
        } else {
          // No product configured for this build → empty list; the .mm serves the dev catalog.
          complete(nil, "{\"products\":[]}")
        }
        // Prime the stream cache with the current OS truth on every product fetch (matches the
        // Android realGetProducts nativeEmit(entitlementJson())).
        await self.emitCurrentEntitlement()
      } catch {
        complete(nil, "{\"products\":[]}")
      }
    }
  }

  // MARK: - purchase

  /// Buy the lifetime unlock through StoreKit 2. On a verified .success transaction we finish it,
  /// resolve the Purchase JSON, and emit the entitlement; on .userCancelled we reject with
  /// "user_cancelled" (the code Billing.can maps to the quiet UserCancelled case); on .pending
  /// (Ask-to-Buy / SCA) we reject with "rejected" + "pending" so the one-shot settles (the
  /// Transaction.updates listener emits the entitlement later if/when it is approved). An empty
  /// product set means "not configured" → the .mm's onNoProduct fake-store fallback runs.
  public func purchase(_ productId: String,
                       onNoProduct: @escaping () -> Void,
                       complete: @escaping Complete) {
    guard productId == kCanopyBillingProductId else {
      complete(Self.errorJSON("item_unavailable", productId), nil); return
    }
    Task {
      do {
        let products = try await Product.products(for: [kCanopyBillingProductId])
        guard let product = products.first else {
          onNoProduct()  // unconfigured build → fake store grant (so the paywall is testable)
          return
        }
        // A non-consumable already owned must NOT be re-bought — the caller restores instead.
        if await self.isActive() {
          complete(Self.errorJSON("already_owned", productId), nil); return
        }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
          guard case .verified(let transaction) = verification else {
            // Signature did not verify → do NOT grant. Fail closed.
            complete(Self.errorJSON("rejected", "unverified transaction"), nil); return
          }
          await transaction.finish()
          let entitlement: [String: Any] = ["isActive": true, "productId": productId]
          let purchase: [String: Any] = [
            "productId": productId,
            "transactionId": String(transaction.id),
            "entitlement": entitlement,
          ]
          complete(nil, Self.jsonString(purchase))
          self.emitEntitlement(active: true, productId: productId)
        case .userCancelled:
          complete(Self.errorJSON("user_cancelled", "user canceled"), nil)
        case .pending:
          // Deferred (Ask-to-Buy / Strong Customer Authentication). The one-shot settles now; the
          // updates listener emits the entitlement if it is later approved.
          complete(Self.errorJSON("rejected", "pending"), nil)
        @unknown default:
          complete(Self.errorJSON("rejected", "unknown purchase result"), nil)
        }
      } catch {
        complete(Self.errorJSON("rejected", error.localizedDescription), nil)
      }
    }
  }

  // MARK: - restore

  /// Restore from Transaction.currentEntitlements (the App Store-synced set of the user's active
  /// non-consumables). Resolves {"isActive",productId} and emits the entitlement so a re-install on
  /// a new device re-locks/-unlocks correctly. StoreKit 2 needs no explicit "restore purchases"
  /// network call for currentEntitlements, but we also kick AppStore.sync() so a brand-new launch
  /// pulls the latest before reading (it is a no-op when already in sync).
  public func restore(_ complete: @escaping Complete) {
    Task {
      // Best-effort refresh, but NEVER block restore on it: AppStore.sync() requires an App Store
      // account and HANGS on a signed-out device / CI simulator (try? catches a THROW, not a hang).
      // Cap it, then resolve from the offline Transaction.currentEntitlements — the StoreKit-cached
      // source of truth (a skipped sync only skips an explicit cross-device receipt refresh).
      await Self.bestEffortSync(timeout: 3)
      let (active, productId) = await self.currentEntitlement()
      let payload: [String: Any] = ["isActive": active, "productId": productId]
      complete(nil, Self.jsonString(payload))
      self.emitEntitlement(active: active, productId: productId)
    }
  }

  /// AppStore.sync() bounded by `timeout` seconds — returns when sync finishes OR the timeout elapses
  /// (the hung-sync case on a signed-out device / CI simulator), whichever is first. Restore must
  /// never block on it; Transaction.currentEntitlements is read regardless.
  private static func bestEffortSync(timeout seconds: Double) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { _ = try? await AppStore.sync() }
      group.addTask { _ = try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
      _ = await group.next()
      group.cancelAll()
    }
  }

  // MARK: - entitlement state (Transaction.currentEntitlements = source of truth)

  /// True iff a VERIFIED current entitlement for our product exists.
  public func isActive() async -> Bool {
    let (active, _) = await currentEntitlement()
    return active
  }

  /// Scan Transaction.currentEntitlements for a verified entitlement to our product. Returns
  /// (active, productId). Only `.verified` transactions count (fail closed on `.unverified`).
  private func currentEntitlement() async -> (Bool, String) {
    for await result in Transaction.currentEntitlements {
      guard case .verified(let transaction) = result else { continue }
      if transaction.productID == kCanopyBillingProductId && transaction.revocationDate == nil {
        return (true, transaction.productID)
      }
    }
    return (false, "")
  }

  // MARK: - Transaction.updates listener (out-of-band changes)

  /// Listen for verified transaction updates for the life of the process. Each verified, non-revoked
  /// transaction for our product finishes + emits the entitlement; a revocation (refund) emits the
  /// locked state. This is what catches a refund, an Ask-to-Buy approval, or a Family-Sharing change
  /// that happens with no in-app purchase call — the iOS twin of an out-of-band Play refund.
  private func startTransactionListener() {
    updatesListener = Task.detached { [weak self] in
      for await update in Transaction.updates {
        guard let self = self else { return }
        guard case .verified(let transaction) = update else { continue }
        if transaction.productID == kCanopyBillingProductId {
          let active = transaction.revocationDate == nil
          await transaction.finish()
          self.emitEntitlement(active: active, productId: active ? transaction.productID : "")
        }
      }
    }
  }

  /// Emit the current OS entitlement onto the stream (used to prime a fresh subscriber / a product
  /// fetch). Reads currentEntitlements, then forwards.
  private func emitCurrentEntitlement() async {
    let (active, productId) = await currentEntitlement()
    emitEntitlement(active: active, productId: productId)
  }

  /// Forward one entitlement event to the .mm (→ canopy::billingEmitEntitlement → every live sub).
  private func emitEntitlement(active: Bool, productId: String) {
    let json = Self.jsonString(["isActive": active, "productId": productId])
    onEntitlementChange?(json)
  }

  // MARK: - JSON helpers (build the exact wire shapes)

  /// Build a Product JSON dict from a StoreKit 2 Product. Matches productJSONFromSK in the .mm and
  /// productToJson in BillingModule.java field-for-field. priceMicros is the integer micro-units of
  /// the decimal price (price * 1_000_000), matching Play's getPriceAmountMicros.
  private static func productJSON(_ product: Product) -> [String: Any] {
    let micros = NSDecimalNumber(decimal: product.price * 1_000_000).int64Value
    // StoreKit 2 exposes the ISO currency via priceFormatStyle.currencyCode on iOS 16+; on iOS 15
    // it is read from the price format style's locale. Fall back to USD if neither resolves.
    let currency: String
    if #available(iOS 16.0, *) {
      currency = product.priceFormatStyle.currencyCode
    } else {
      currency = product.priceFormatStyle.locale.currencyCode ?? "USD"
    }
    return [
      "id": product.id,
      "title": product.displayName,
      "description": product.description,
      "priceText": product.displayPrice,
      "priceMicros": micros,
      "currencyCode": currency,
    ]
  }

  /// Build a {"code","message"} error JSON (the CanopyReject shape).
  private static func errorJSON(_ code: String, _ message: String) -> String {
    return jsonString(["code": code, "message": message])
  }

  /// Serialize a dict to a compact JSON string. Sorted keys for stable, diffable output.
  private static func jsonString(_ obj: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let s = String(data: data, encoding: .utf8) else {
      return "{}"
    }
    return s
  }
}
