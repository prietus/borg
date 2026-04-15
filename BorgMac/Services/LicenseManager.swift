import Foundation
import SwiftUI

// MARK: - Public configuration
//
// Fill these in from your LemonSqueezy dashboard once the product is set up.
// CheckoutURL is what the "Buy a license" button opens — you can generate it
// in Store → Products → <your product> → "Share checkout link". Keeping the
// configuration in one place makes it trivial to swap providers later.

enum LicenseConfig {
    /// Hard trial duration from first app launch.
    static let trialDays = 14

    /// LemonSqueezy checkout URL for the paid product.
    /// Replace with the real one after creating the product in LS.
    static let checkoutURL = URL(string: "https://prietus.lemonsqueezy.com/buy/REPLACE-ME")!

    /// How often an already-activated license re-validates against LS.
    /// Offline tolerance is `max(validateEvery, offlineGrace)` — see
    /// `LicenseManager.refresh()`.
    static let validateEvery: TimeInterval = 60 * 60 * 24  // 24h
    static let offlineGrace: TimeInterval = 60 * 60 * 24 * 7 // 7d
}

// MARK: - Status

enum LicenseStatus: Equatable {
    case unknown
    case trial(daysLeft: Int)
    case expired
    case licensed(email: String)

    var isPaid: Bool {
        if case .licensed = self { return true }
        return false
    }

    var bannerText: String? {
        switch self {
        case .trial(let days):
            return days <= 3 ? "Trial ends in \(days) day\(days == 1 ? "" : "s")." : nil
        case .expired:
            return "Your trial has expired. Buy a license to keep using BorgMac."
        case .licensed, .unknown:
            return nil
        }
    }
}

// MARK: - Errors

enum LicenseError: LocalizedError {
    case network(String)
    case invalidKey
    case deactivated
    case activationLimit
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .network(let msg): return "Network error: \(msg)"
        case .invalidKey: return "That license key is not valid."
        case .deactivated: return "This license is no longer active."
        case .activationLimit: return "This license has reached its activation limit."
        case .unexpected(let msg): return msg
        }
    }
}

// MARK: - Manager

@MainActor
final class LicenseManager: ObservableObject {
    @Published private(set) var status: LicenseStatus = .unknown
    @Published private(set) var lastError: String?
    @Published private(set) var isBusy = false

    private let api = URL(string: "https://api.lemonsqueezy.com/v1")!

    init() {
        bootstrap()
    }

    // MARK: Public API

    /// Exchange a key for an activation (instance_id) against LemonSqueezy.
    /// On success, persists the key + instance_id in Keychain and flips
    /// `status` to `.licensed`.
    func activate(key rawKey: String) async {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            lastError = "Enter a license key."
            return
        }
        await perform {
            var req = URLRequest(url: self.api.appendingPathComponent("licenses/activate"))
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let hostname = ProcessInfo.processInfo.hostName
            let body = "license_key=\(LicenseManager.urlEncode(key))&instance_name=\(LicenseManager.urlEncode(hostname))"
            req.httpBody = body.data(using: String.Encoding.utf8)

            let response: LSLicenseResponse = try await self.send(req)
            guard response.activated == true || response.valid == true else {
                throw LicenseManager.parseError(response)
            }
            guard let instanceId = response.instance?.id else {
                throw LicenseError.unexpected("No instance id returned by LemonSqueezy.")
            }
            let email = response.meta?.customerEmail ?? "unknown"

            try Keychain.setLicense(key: key, instanceId: instanceId, email: email)
            Keychain.setLicenseLastCheck(Date())
            self.status = .licensed(email: email)
        }
    }

    /// Revoke the current license from this device. The user can still re-enter
    /// the same key later on another Mac (subject to the LS activation limit).
    func deactivate() async {
        guard let stored = Keychain.license() else { return }
        await perform {
            var req = URLRequest(url: self.api.appendingPathComponent("licenses/deactivate"))
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let body = "license_key=\(LicenseManager.urlEncode(stored.key))&instance_id=\(LicenseManager.urlEncode(stored.instanceId))"
            req.httpBody = body.data(using: String.Encoding.utf8)
            // We do not care about the response body here — best-effort revoke.
            _ = try? await URLSession.shared.data(for: req)
            Keychain.deleteLicense()
            self.recomputeLocalStatus()
        }
    }

    /// Silently re-validate a stored license against LS. Called on app launch
    /// and once a day after that. Offline failures are tolerated up to
    /// `offlineGrace` so backup workflows never break because of a dead Wi-Fi.
    func refresh() async {
        guard let stored = Keychain.license() else {
            recomputeLocalStatus()
            return
        }
        if let last = Keychain.licenseLastCheck(),
           Date().timeIntervalSince(last) < LicenseConfig.validateEvery {
            status = .licensed(email: stored.email)
            return
        }
        do {
            var req = URLRequest(url: self.api.appendingPathComponent("licenses/validate"))
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let body = "license_key=\(LicenseManager.urlEncode(stored.key))&instance_id=\(LicenseManager.urlEncode(stored.instanceId))"
            req.httpBody = body.data(using: String.Encoding.utf8)
            let response: LSLicenseResponse = try await self.send(req)
            if response.valid == true {
                Keychain.setLicenseLastCheck(Date())
                status = .licensed(email: stored.email)
            } else if response.license_key?.status == "inactive" || response.license_key?.status == "disabled" {
                // Honest server says this license is dead. Drop it.
                Keychain.deleteLicense()
                recomputeLocalStatus()
            } else {
                // Unknown shape — treat as transient and fall back to grace.
                applyOfflineGrace(stored: stored)
            }
        } catch {
            applyOfflineGrace(stored: stored)
        }
    }

    /// Opens LemonSqueezy checkout in the user's default browser.
    func openCheckout() {
        #if DEBUG
        assert(
            !LicenseConfig.checkoutURL.absoluteString.contains("REPLACE-ME"),
            "LicenseConfig.checkoutURL still has the REPLACE-ME placeholder — set it before shipping."
        )
        #endif
        NSWorkspace.shared.open(LicenseConfig.checkoutURL)
    }

    // MARK: Private

    private func bootstrap() {
        // First-run: remember when the trial started. We store this in the
        // Keychain (not UserDefaults) so reinstalling the app doesn't reset
        // the clock.
        if Keychain.trialStart() == nil {
            Keychain.setTrialStart(Date())
        }
        recomputeLocalStatus()
        Task { await refresh() }
    }

    private func recomputeLocalStatus() {
        if let stored = Keychain.license() {
            status = .licensed(email: stored.email)
            return
        }
        // If the Keychain read fails for some reason, fall back to `.distantPast`
        // so the app treats the trial as expired rather than silently regranting
        // a fresh 14-day window on every launch.
        let start = Keychain.trialStart() ?? .distantPast
        let elapsed = Date().timeIntervalSince(start)
        let remaining = Double(LicenseConfig.trialDays * 86400) - elapsed
        if remaining > 0 {
            let daysLeft = Int(ceil(remaining / 86400))
            status = .trial(daysLeft: daysLeft)
        } else {
            status = .expired
        }
    }

    private func applyOfflineGrace(stored: StoredLicense) {
        let last = Keychain.licenseLastCheck() ?? Date.distantPast
        if Date().timeIntervalSince(last) < LicenseConfig.offlineGrace {
            status = .licensed(email: stored.email)
        } else {
            status = .expired
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch let err as LicenseError {
            lastError = err.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw LicenseError.network("Non-HTTP response")
            }
            if http.statusCode >= 500 {
                throw LicenseError.network("LemonSqueezy returned \(http.statusCode)")
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch let decodeErr as DecodingError {
                // LS returns JSON with an `error` field even on 4xx, so the
                // normal path covers those. But if the shape ever drifts and
                // decoding fails on a 4xx, surface a clearer network error
                // instead of a raw decoding error.
                if http.statusCode >= 400 {
                    throw LicenseError.network("LemonSqueezy returned \(http.statusCode)")
                }
                throw decodeErr
            }
        } catch let err as URLError {
            throw LicenseError.network(err.localizedDescription)
        } catch let err as DecodingError {
            throw LicenseError.unexpected("Could not decode response: \(err.localizedDescription)")
        }
    }

    private static func parseError(_ response: LSLicenseResponse) -> LicenseError {
        if let msg = response.error?.lowercased() {
            if msg.contains("license key not found") || msg.contains("invalid") {
                return .invalidKey
            }
            if msg.contains("activation limit") {
                return .activationLimit
            }
            if msg.contains("inactive") || msg.contains("disabled") {
                return .deactivated
            }
        }
        return .unexpected(response.error ?? "Unknown LemonSqueezy response.")
    }

    private static func urlEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}

// MARK: - LemonSqueezy response shapes

struct LSLicenseResponse: Decodable {
    let activated: Bool?
    let deactivated: Bool?
    let valid: Bool?
    let error: String?
    let license_key: LSLicenseKey?
    let instance: LSInstance?
    let meta: LSMeta?
}

struct LSLicenseKey: Decodable {
    let id: Int?
    let status: String?
    let key: String?
    let activation_limit: Int?
    let activation_usage: Int?
    let expires_at: String?
}

struct LSInstance: Decodable {
    let id: String
    let name: String?
}

struct LSMeta: Decodable {
    let store_id: Int?
    let order_id: Int?
    let product_name: String?
    let customer_name: String?
    let customer_email: String?

    var customerEmail: String { customer_email ?? "" }
}
