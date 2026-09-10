import Foundation
import Security

/// Whether this build can actually perform iCloud key-value sync (#83).
///
/// This is deliberately NOT `FileManager.default.ubiquityIdentityToken != nil`, which both call sites
/// used to ask. That token answers "is the user signed into iCloud", which is a different question: it
/// comes back non-nil on any Mac with an iCloud account, entitlement or not. Gating on it made the app
/// construct `UbiquitousConnectionStore` and light up the Settings checkbox in builds where sync could
/// never work — the user ticks the box, `reconcile()` pushes into a dead store, and nothing ever syncs
/// or reports why.
///
/// Measured 2026-09-08 on a Developer ID + hardened-runtime build carrying no entitlement:
/// `ubiquityIdentityToken` non-nil, `NSUbiquitousKeyValueStore.synchronize()` false, readback nil.
///
/// Reading our own code signature is the honest test and needs no maintenance. It is also why a dev
/// build answers honestly: `swift run` and CI both produce ad-hoc signatures that carry no
/// entitlement, so sync stays visibly unavailable there rather than half-working.
///
/// The entitlement is granted by `Bosun.entitlements` in the release tooling and paid for by the
/// Developer ID profile sealed in at `Contents/embedded.provisionprofile` — a restricted entitlement
/// without that profile gets the process SIGKILLed by AMFI at exec, so the two travel together and
/// both packaging scripts refuse to build one without the other.
enum ICloudCapability {
    /// The entitlement AMFI checks and that gates the KVS container.
    private static let kvStoreEntitlement = "com.apple.developer.ubiquity-kvstore-identifier"

    /// Does this process's signature actually carry the KVS entitlement? Evaluated once: a running
    /// process cannot change its own signature.
    private static let isEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, kvStoreEntitlement as CFString, nil) != nil
    }()

    /// Both halves must hold: the build is entitled to touch the KVS *and* an iCloud account is signed
    /// in. Recomputed per call rather than cached, since the user can sign in or out while we run.
    static var isAvailable: Bool {
        isEntitled && FileManager.default.ubiquityIdentityToken != nil
    }

    /// One line for the launch log and **Help → Copy Diagnostics**, reporting the two halves
    /// separately. Without it a report can say sync is off but never why, since `isEntitled` is
    /// private and `isAvailable` collapses "this build can't" and "you're signed out" into one `false`
    /// — and those need completely different answers from whoever reads the report.
    static var diagnosticSummary: String {
        let signedIn = FileManager.default.ubiquityIdentityToken != nil
        return "icloud sync: entitled=\(isEntitled) signedIn=\(signedIn) available=\(isAvailable)"
    }

    /// Why the sync checkbox is greyed out, for the hint beneath it. The two causes need different
    /// wording: telling a signed-in user to "sign in to iCloud" (the old fixed string, correct back
    /// when sign-in was the only thing checked) sends them off to fix something that isn't broken.
    /// Empty when sync is available, since the hint is hidden then anyway.
    static var unavailableHint: String {
        if !isEntitled { return "iCloud sync isn't available in this build." }
        if FileManager.default.ubiquityIdentityToken == nil {
            return "Sign in to iCloud to sync connections."
        }
        return ""
    }
}
