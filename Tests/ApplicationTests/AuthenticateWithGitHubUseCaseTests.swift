import XCTest
import Domain
@testable import Application

/// Contract tests for the device-flow sign-in use case, driven entirely through its ports.
/// The seam (GitHubDeviceAuth / GitHubTokenStore / Sleeper) is exactly what lets us run the
/// poll loop against fakes here — no network, no real waiting — instead of live github.com.
final class AuthenticateWithGitHubUseCaseTests: XCTestCase {

    // MARK: Fakes (in-test implementations of Application's ports)

    /// Returns a fixed grant, then walks a queued list of poll outcomes (defaults to `.pending`).
    private actor ScriptedAuth: GitHubDeviceAuth {
        private var polls: [DeviceTokenPoll]
        private(set) var pollCount = 0
        let grant: DeviceCodeGrant
        init(grant: DeviceCodeGrant, polls: [DeviceTokenPoll]) {
            self.grant = grant
            self.polls = polls
        }
        func requestDeviceCode() -> DeviceCodeGrant { grant }
        func redeemDeviceCode(_ deviceCode: String) -> DeviceTokenPoll {
            pollCount += 1
            return polls.isEmpty ? .pending : polls.removeFirst()
        }
    }

    private actor FakeTokenStore: GitHubTokenStore {
        private(set) var saved: String?
        private(set) var deleted = false
        func load() -> String? { saved }
        func save(_ token: String) { saved = token }
        func delete() { saved = nil; deleted = true }
    }

    /// Records each requested interval but never actually sleeps — keeps the suite instant.
    private actor RecordingSleeper: Sleeper {
        private(set) var intervals: [Int] = []
        func sleep(seconds: Int) { intervals.append(seconds) }
    }

    private func grant(interval: Int = 5, expiresIn: Int = 900) -> DeviceCodeGrant {
        DeviceCodeGrant(
            deviceCode: "DEV", userCode: "WDJB-MJHT",
            verificationURI: "https://github.com/login/device",
            expiresIn: expiresIn, interval: interval)
    }

    // MARK: Tests

    func testHappyPathPendingThenAuthorizedSavesToken() async throws {
        let auth = ScriptedAuth(grant: grant(), polls: [.pending, .authorized(token: "gho_abc")])
        let tokens = FakeTokenStore()
        let useCase = AuthenticateWithGitHubUseCase(auth: auth, tokens: tokens, sleeper: RecordingSleeper())

        var issued: DeviceCodeGrant?
        try await useCase { issued = $0 }

        XCTAssertEqual(issued?.userCode, "WDJB-MJHT", "code must be surfaced before polling")
        let saved = await tokens.saved
        XCTAssertEqual(saved, "gho_abc")
    }

    func testDeniedThrowsAndSavesNothing() async {
        let auth = ScriptedAuth(grant: grant(), polls: [.denied])
        let tokens = FakeTokenStore()
        let useCase = AuthenticateWithGitHubUseCase(auth: auth, tokens: tokens, sleeper: RecordingSleeper())

        do {
            try await useCase { _ in }
            XCTFail("expected AuthError.denied")
        } catch {
            XCTAssertEqual(error as? AuthError, .denied)
        }
        let saved = await tokens.saved
        XCTAssertNil(saved, "no token should be stored when denied")
    }

    func testExpiredThrows() async {
        let auth = ScriptedAuth(grant: grant(), polls: [.expired])
        let useCase = AuthenticateWithGitHubUseCase(auth: auth, tokens: FakeTokenStore(), sleeper: RecordingSleeper())

        do {
            try await useCase { _ in }
            XCTFail("expected AuthError.expired")
        } catch {
            XCTAssertEqual(error as? AuthError, .expired)
        }
    }

    func testSlowDownWidensInterval() async throws {
        let auth = ScriptedAuth(grant: grant(interval: 5), polls: [.slowDown, .authorized(token: "gho_x")])
        let sleeper = RecordingSleeper()
        let useCase = AuthenticateWithGitHubUseCase(auth: auth, tokens: FakeTokenStore(), sleeper: sleeper)

        try await useCase { _ in }

        let intervals = await sleeper.intervals
        XCTAssertEqual(intervals, [5, 10], "second wait must widen by +5 after slow_down")
    }

    func testLocalBudgetExhaustionThrowsExpired() async {
        // Grant expires in 5s and the interval is 5s, so after one wait the local budget is gone.
        let auth = ScriptedAuth(grant: grant(interval: 5, expiresIn: 5), polls: [.pending, .pending])
        let useCase = AuthenticateWithGitHubUseCase(auth: auth, tokens: FakeTokenStore(), sleeper: RecordingSleeper())

        do {
            try await useCase { _ in }
            XCTFail("expected AuthError.expired once the local budget runs out")
        } catch {
            XCTAssertEqual(error as? AuthError, .expired)
        }
    }
}
