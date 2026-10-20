// Standalone Swift test for InputMapper. Compiled + run by
// Tests/run-swift-tests.sh; no XCTest target.

import Foundation

@main
struct InputMapperTest {
    static var failed = 0

    static func check(_ ok: Bool, _ msg: String,
                      file: StaticString = #file, line: UInt = #line) {
        if !ok {
            print("FAIL [\(file):\(line)] \(msg)")
            failed += 1
        }
    }

    static func main() {
        // Space (kVK_Space) sends Select. Shift can't: macOS delivers
        // modifier keys via flagsChanged, never keyDown/keyUp.
        check(InputMapper.button(forKeyCode: 49) == .select, "Space -> Select")
        check(InputMapper.button(forKeyCode: 56) == nil, "Left Shift unmapped")
        check(InputMapper.button(forKeyCode: 60) == nil, "Right Shift unmapped")
        check(InputMapper.button(forKeyCode: 36) == .start, "Return -> Start")

        if failed > 0 {
            print("\(failed) failure(s)")
            exit(1)
        }
        print("InputMapper: OK")
    }
}
