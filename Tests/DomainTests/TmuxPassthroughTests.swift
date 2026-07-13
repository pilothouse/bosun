import XCTest
@testable import Domain

/// Contract tests for the pure tmux DCS-passthrough wrapper. They describe what `TmuxPassthrough`
/// promises outward — the exact bytes a sequence becomes so tmux forwards it to the outer terminal
/// — not how it works inside. The local zsh shim mirrors `wrap` in zsh; keep them in lockstep.
final class TmuxPassthroughTests: XCTestCase {
    private let esc = "\u{1b}"

    // tmux only forwards an escape sequence to the host terminal when it is wrapped as
    // `ESC P tmux ; <payload> ESC \`, with every ESC in the payload doubled.
    func testWrapBracketsPayloadInTmuxEnvelope() {
        XCTAssertEqual(TmuxPassthrough.wrap("hi"), "\(esc)Ptmux;hi\(esc)\\")
    }

    func testWrapDoublesEveryEscapeInThePayload() {
        // Two ESCs in → four ESCs in the payload, plus the one opening + one closing envelope ESC.
        let input = "\(esc)a\(esc)b"
        XCTAssertEqual(TmuxPassthrough.wrap(input), "\(esc)Ptmux;\(esc)\(esc)a\(esc)\(esc)b\(esc)\\")
    }

    func testWrapBusyProgressSequence() {
        // OSC 9;4 INDETERMINATE (busy): ESC ] 9;4;3 ESC \  →  the exact wrapped form.
        let busy = "\(esc)]9;4;3\(esc)\\"
        XCTAssertEqual(TmuxPassthrough.wrap(busy),
                       "\(esc)Ptmux;\(esc)\(esc)]9;4;3\(esc)\(esc)\\\(esc)\\")
    }

    func testWrapIdleProgressSequence() {
        // OSC 9;4 REMOVE (idle): ESC ] 9;4;0 ESC \.
        let idle = "\(esc)]9;4;0\(esc)\\"
        XCTAssertEqual(TmuxPassthrough.wrap(idle),
                       "\(esc)Ptmux;\(esc)\(esc)]9;4;0\(esc)\(esc)\\\(esc)\\")
    }

    func testWrapWithoutEscapeStillBrackets() {
        XCTAssertEqual(TmuxPassthrough.wrap("plain"), "\(esc)Ptmux;plain\(esc)\\")
    }

    func testWrapEmptyProducesBareEnvelope() {
        XCTAssertEqual(TmuxPassthrough.wrap(""), "\(esc)Ptmux;\(esc)\\")
    }

    func testWrapEscapeCountDoubles() {
        let input = "\(esc)\(esc)\(esc)" // 3 ESCs
        let wrapped = TmuxPassthrough.wrap(input)
        // 3 payload ESCs doubled = 6, plus the opening and closing envelope ESCs = 8.
        XCTAssertEqual(wrapped.filter { $0 == "\u{1b}" }.count, 8)
    }

    func testAllowPassthroughCommandIsTheTmuxOption() {
        XCTAssertEqual(TmuxPassthrough.allowPassthroughCommand, "set -g allow-passthrough on")
    }
}
