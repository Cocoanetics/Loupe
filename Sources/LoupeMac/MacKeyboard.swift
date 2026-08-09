import Carbon.HIToolbox
import CoreGraphics
import Foundation
import LoupeCore

/// Per-process keyboard synthesis.
///
/// `CGEvent.postToPid` is the only input synthesis that works on a background
/// app. Mouse events posted the same way are useless — they arrive with no
/// window attached and AppKit drops them before `mouseDown:` — but key events
/// are delivered normally, including full Unicode. The app still needs a first
/// responder, which ``MacDriver`` arranges through the accessibility API before
/// calling in here.
enum MacKeyboard {
    /// Keys whose virtual code is fixed by position, not by what is printed on
    /// them, so no layout lookup is needed.
    static let namedKeys: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forwarddelete": 117,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    /// Character keys at their ANSI/QWERTY positions.
    ///
    /// Fallback only. Virtual key codes are *positions*, and the character a
    /// position produces comes from the active keyboard layout — measured on a
    /// German QWERTZ Mac, key code 6 ("z" on ANSI) types **y**. Sending the wrong
    /// letter is exactly the kind of quiet wrongness this package exists to
    /// prevent, so ``layoutKeys`` is consulted first and this table is used only
    /// when the layout cannot be read.
    private static let ansiKeys: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50
    ]

    /// character → key code, derived from the keyboard layout that is actually
    /// active, by asking every key code what it types.
    private static let layoutKeys: [String: CGKeyCode] = {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())

        var table: [String: CGKeyCode] = [:]
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return }
            for code in 0..<128 as Range<UInt16> {
                var characters = [UniChar](repeating: 0, count: 8)
                var length = 0
                var deadKeyState: UInt32 = 0
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDisplay), 0, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count,
                    &length, &characters)
                guard status == noErr, length > 0 else { continue }
                let produced = String(utf16CodeUnits: characters, count: length)
                // Lowest key code wins: the main keyboard is numbered before the
                // numeric keypad, and "1" should mean the one above the letters.
                if table[produced] == nil { table[produced] = CGKeyCode(code) }
            }
        }
        return table
    }()

    /// Resolve a key name — `return`, `tab`, or a single character — to a virtual
    /// key code on this Mac's active layout.
    static func keyCode(for name: String) -> CGKeyCode? {
        if let named = namedKeys[name] { return named }
        guard name.count == 1 else { return nil }
        return layoutKeys[name] ?? ansiKeys[name]
    }

    /// The character a key code produces here, for matching against a menu
    /// item's `AXMenuItemCmdChar`.
    static func character(for key: CGKeyCode) -> String? {
        if let match = layoutKeys.first(where: { $0.value == key && $0.key.count == 1 })?.key {
            return match
        }
        return ansiKeys.first { $0.value == key }?.key
    }

    /// Parse `cmd+shift+s` style combinations.
    static func parse(_ combination: String) throws -> (key: CGKeyCode, flags: CGEventFlags) {
        let parts = combination.lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else {
            throw LoupeError.failed("empty key combination")
        }

        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
                case "cmd", "command", "⌘": flags.insert(.maskCommand)
                case "shift", "⇧": flags.insert(.maskShift)
                case "alt", "opt", "option", "⌥": flags.insert(.maskAlternate)
                case "ctrl", "control", "⌃": flags.insert(.maskControl)
                case "fn", "function": flags.insert(.maskSecondaryFn)
                default:
                    throw LoupeError.unsupported(
                        "unknown modifier '\(modifier)' — use cmd, shift, alt/option, ctrl or fn")
            }
        }

        guard let key = keyCode(for: last) else {
            throw LoupeError.unsupported(
                "'\(last)' is not on this Mac's active keyboard layout and is not one of the named "
                    + "keys (\(namedKeys.keys.sorted().joined(separator: ", "))). For arbitrary text "
                    + "use the type action, which sends Unicode directly and needs no key code.")
        }
        return (key, flags)
    }

    /// Post one key down/up pair to a specific process.
    static func post(key: CGKeyCode, flags: CGEventFlags, to pid: pid_t) throws {
        // A private event source keeps the user's real modifier state out of the
        // synthesized event — otherwise a Shift held down on the physical keyboard
        // would leak into every keystroke we send.
        let source = CGEventSource(stateID: .privateState)
        guard let press = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let release = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else {
            throw LoupeError.failed("could not create a keyboard event (key code \(key))")
        }
        press.flags = flags
        release.flags = flags
        press.postToPid(pid)
        release.postToPid(pid)
    }

    /// Type text one grapheme at a time, as Unicode rather than key codes.
    ///
    /// Sending the whole string in one event hits `keyboardSetUnicodeString`'s
    /// internal length limit and drops the tail; per-character events also let
    /// emoji (surrogate pairs) through unharmed. Because the characters travel as
    /// Unicode, this path is immune to the keyboard-layout problem that key codes
    /// have.
    static func type(_ text: String, to pid: pid_t) async throws {
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            // Return and Tab must go through their key codes: apps treat them as
            // commands (insert a newline, move focus), not as text input.
            switch character {
                case "\n", "\r":
                    try post(key: namedKeys["return"]!, flags: [], to: pid)
                case "\t":
                    try post(key: namedKeys["tab"]!, flags: [], to: pid)
                default:
                    let utf16 = Array(String(character).utf16)
                    guard let press = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                        let release = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
                    else {
                        throw LoupeError.failed("could not create a keyboard event for '\(character)'")
                    }
                    press.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                    release.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                    press.postToPid(pid)
                    release.postToPid(pid)
            }
            // Apps that re-layout on every keystroke drop events posted back to
            // back; 3 ms is below human typing speed and still gives the run loop
            // a turn.
            try await Task.sleep(nanoseconds: 3_000_000)
        }
    }
}
