import AppKit

/// Keyboard → SNES gamepad button index mapping. Matches libkintsuki's
/// kintsuki_press argument order (Up=0 … Start=11).
enum SnesButton: Int32 {
    case up = 0, down = 1, left = 2, right = 3
    case b = 4, a = 5, y = 6, x = 7
    case l = 8, r = 9, select = 10, start = 11
}

enum InputMapper {
    /// macOS virtual keycodes (NSEvent.keyCode) → SNES button.
    /// Layout matches Mesen's default: ZXAS for face buttons, arrows for
    /// d-pad, Return = Start, Right Shift = Select, Q/W = L/R.
    static func button(forKeyCode code: UInt16) -> SnesButton? {
        switch code {
        case 126: return .up         // Arrow Up
        case 125: return .down       // Arrow Down
        case 123: return .left       // Arrow Left
        case 124: return .right      // Arrow Right
        case 6:   return .b          // Z
        case 7:   return .a          // X
        case 0:   return .y          // A
        case 1:   return .x          // S
        case 12:  return .l          // Q
        case 13:  return .r          // W
        case 36:  return .start      // Return
        case 60, 56: return .select  // Right Shift / Left Shift
        default: return nil
        }
    }
}
