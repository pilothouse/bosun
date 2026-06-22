import Application
import Domain
import Foundation

/// URLSession adapter for the `GitHubDeviceAuth` port: the only place that knows GitHub's
/// device-flow HTTP. POSTs to github.com with `Accept: application/json` and an x-www-form-
/// urlencoded body, decodes the two payloads, and maps OAuth error codes to `DeviceTokenPoll`.
/// `clientId`/`scope` are injected — the adapter never reads config itself. An actor gives us
/// free `Sendable` correctness, mirroring the other stores.
public actor GitHubDeviceAuthClient: GitHubDeviceAuth {
    private let clientId: String
    private let scope: String
    private let session: URLSession
    private let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    /// `scope` is for OAuth Apps; leave it empty for GitHub Apps, whose permissions come from
    /// the App configuration (the parameter is then omitted from the request).
    public init(clientId: String, scope: String = "", session: URLSession = .shared) {
        self.clientId = clientId
        self.scope = scope
        self.session = session
    }

    public func requestDeviceCode() async throws -> DeviceCodeGrant {
        var form = ["client_id": clientId]
        if !scope.isEmpty { form["scope"] = scope }
        let dto: DeviceCodeDTO = try await post(deviceCodeURL, form: form)
        return DeviceCodeGrant(
            deviceCode: dto.device_code,
            userCode: dto.user_code,
            verificationURI: dto.verification_uri,
            expiresIn: dto.expires_in,
            interval: dto.interval ?? DeviceFlowPolicy.defaultInterval)
    }

    public func redeemDeviceCode(_ deviceCode: String) async throws -> DeviceTokenPoll {
        let form = [
            "client_id": clientId,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ]
        let dto: TokenDTO = try await post(tokenURL, form: form)
        if let token = dto.access_token { return .authorized(token: token) }
        switch dto.error {
        case "authorization_pending": return .pending
        case "slow_down":             return .slowDown
        case "access_denied":         return .denied
        case "expired_token":         return .expired
        default: throw AuthError.transport("unexpected response: \(dto.error ?? "none")")
        }
    }

    /// Shared POST: form-encoded request body, JSON response. Network/decoding failures surface
    /// as `AuthError.transport`; the token is never logged or echoed back in an error.
    private func post<T: Decodable>(_ url: URL, form: [String: String]) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = encode(form)
        do {
            let (data, _) = try await session.data(for: request)
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.transport(String(describing: error))
        }
    }

    private func encode(_ form: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics
        return form
            .map { key, value in
                let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(key)=\(encoded)"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    // swiftlint:disable identifier_name — these names mirror GitHub's snake_case JSON fields.
    private struct DeviceCodeDTO: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int?
    }

    private struct TokenDTO: Decodable {
        let access_token: String?
        let error: String?
    }
    // swiftlint:enable identifier_name
}
