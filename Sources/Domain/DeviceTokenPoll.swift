import Foundation

/// The outcome of a single access-token poll during the device flow. Maps the five states the
/// OAuth device-flow spec (RFC 8628) defines: keep waiting, back off, success, user said no,
/// time's up.
public enum DeviceTokenPoll: Sendable, Equatable {
    case pending                    // authorization_pending — user hasn't finished yet
    case slowDown                   // slow_down — we polled too fast; widen the interval
    case authorized(token: String)
    case denied                     // access_denied — user rejected the request
    case expired                    // expired_token — the grant aged out
}
