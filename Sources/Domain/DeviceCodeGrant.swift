import Foundation

/// GitHub's response to a device-code request: the code the app polls with, the code the
/// human types, where they type it, and the timing budget. Pure value type — the HTTP that
/// produces it lives behind `GitHubDeviceAuth` in Application and its URLSession adapter in
/// Infrastructure. Seconds are plain `Int` so Domain stays free of Dispatch/Duration.
public struct DeviceCodeGrant: Sendable, Equatable, Codable {
    public let deviceCode: String     // polled with; never shown to the user
    public let userCode: String       // shown to the user, e.g. "WDJB-MJHT"
    public let verificationURI: String
    public let expiresIn: Int         // seconds until the whole grant expires (~900)
    public let interval: Int          // server-mandated minimum seconds between polls (~5)

    public init(deviceCode: String, userCode: String, verificationURI: String,
                expiresIn: Int, interval: Int) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresIn = expiresIn
        self.interval = interval
    }
}
