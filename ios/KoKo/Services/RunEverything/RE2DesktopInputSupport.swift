import Foundation
import UIKit
import SwiftUI
import SwiftTerm

// MARK: - Keychain (desktop access password)

enum RE2DesktopSecrets {
    static let account = KeychainAccount.desktopAccessPassword.rawValue

    static func savePassword(_ password: String, desktopID: UUID) {
        guard let data = password.data(using: .utf8), !password.isEmpty else { return }
        try? KeychainService.shared.save(data: data, account: account, keyId: desktopID)
    }

    static func loadPassword(desktopID: UUID) -> String? {
        guard let data = try? KeychainService.shared.load(account: account, keyId: desktopID),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func deletePassword(desktopID: UUID) {
        try? KeychainService.shared.delete(account: account, keyId: desktopID)
    }
}

// MARK: - Host key codes (CGKeyCode / Darwin — Agent on Windows must map; see handoff)

enum RE2HostKey {
    static let a = 0
    static let s = 1
    static let d = 2
    static let f = 3
    static let h = 4
    static let g = 5
    static let z = 6
    static let x = 7
    static let c = 8
    static let v = 9
    static let returnKey = 36
    static let tab = 48
    static let space = 49
    static let delete = 51
    static let escape = 53
    static let command = 55
    static let shift = 56
    static let option = 58
    static let control = 59
    static let left = 123
    static let right = 124
    static let down = 125
    static let up = 126
    static let forwardDelete = 117
    static let home = 115
    static let end = 119
    static let pageUp = 116
    static let pageDown = 121
    static let f1 = 122
    static let f2 = 120
    static let f3 = 99
    static let f4 = 118
    static let f5 = 96
    static let f6 = 97
    static let f7 = 98
    static let f8 = 100
    static let f9 = 101
    static let f10 = 109
    static let f11 = 103
    static let f12 = 111
    /// macOS ANSI letter keycodes A…Z (for Ctrl+letter from terminal bytes).
    static let letterAZ: [Int] = [
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
    ]

    /// bit0 shift · bit1 ctrl · bit2 alt · bit3 meta(cmd)
    enum Mod {
        static let shift = 1
        static let ctrl = 2
        static let alt = 4
        static let meta = 8
    }
}

enum DesktopSpaceSwipe: Equatable {
    case left, right, up, down

    /// Three-finger translation → Mac Spaces / Mission Control.
    /// Fingers move left (negative x) → space on the right (Control+Right), matching macOS.
    static func interpret(translation: CGPoint, minDistance: CGFloat = 80) -> DesktopSpaceSwipe? {
        let ax = abs(translation.x)
        let ay = abs(translation.y)
        guard ax >= minDistance || ay >= minDistance else { return nil }
        if ax > ay {
            return translation.x < 0 ? .right : .left
        }
        return translation.y < 0 ? .up : .down
    }

    var spaceDelta: Int {
        switch self {
        case .right: return 1
        case .left: return -1
        default: return 0
        }
    }

    var keyCode: Int {
        switch self {
        case .left: return RE2HostKey.left
        case .right: return RE2HostKey.right
        case .up: return RE2HostKey.up
        case .down: return RE2HostKey.down
        }
    }
}

enum DesktopGestureMath {
    /// Shared by the viewer and E2E so pinch bounds are tested against the
    /// production calculation rather than a duplicate approximation.
    static func pinchScale(anchor: CGFloat, gestureScale: CGFloat) -> CGFloat {
        min(max(max(anchor, 1) * gestureScale, 1), 4)
    }
}

// MARK: - Single UIKit hit target: mouse, pinch, two-finger scroll, three-finger Spaces

struct DesktopInputSurface: UIViewRepresentable {
    var onTap: (_ location: CGPoint) -> Void
    var onLongPress: (_ location: CGPoint) -> Void
    /// One-finger drag after leaving the tap slop (never fires for a clean tap/double-tap).
    /// `selectDrag` is true when the finger was held ≥200ms before leaving the slop.
    var onOneFinger: (_ location: CGPoint, _ translation: CGSize, _ state: UIGestureRecognizer.State, _ selectDrag: Bool) -> Void
    var onPinch: (_ scale: CGFloat, _ location: CGPoint, _ state: UIGestureRecognizer.State) -> Void
    var onTwoFingerScroll: (_ dx: CGFloat, _ dy: CGFloat) -> Void
    var onThreeFingerSwipe: (DesktopSpaceSwipe) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> DesktopInputView {
        let v = DesktopInputView()
        v.coordinator = context.coordinator
        context.coordinator.install(on: v)
        return v
    }

    func updateUIView(_ uiView: DesktopInputView, context: Context) {
        let c = context.coordinator
        c.onTap = onTap
        c.onLongPress = onLongPress
        c.onOneFinger = onOneFinger
        c.onPinch = onPinch
        c.onTwoFingerScroll = onTwoFingerScroll
        c.onThreeFingerSwipe = onThreeFingerSwipe
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: ((CGPoint) -> Void)?
        var onLongPress: ((CGPoint) -> Void)?
        var onOneFinger: ((CGPoint, CGSize, UIGestureRecognizer.State, Bool) -> Void)?
        var onPinch: ((CGFloat, CGPoint, UIGestureRecognizer.State) -> Void)?
        var onTwoFingerScroll: ((CGFloat, CGFloat) -> Void)?
        var onThreeFingerSwipe: ((DesktopSpaceSwipe) -> Void)?

        /// Hard floor: below this, never a drag.
        let tapSlop: CGFloat = 16
        /// Fat-finger / double-tap jitter still counts as a tap if short + under this.
        let tapMaxDist: CGFloat = 40
        /// Max press duration to still classify as tap when slightly over slop.
        let tapMaxDuration: TimeInterval = 0.28
        /// Hold this long before leaving slop → text-select drag (mousedown).
        /// Keep well above a normal tap dwell — 200ms made almost every slow tap
        /// into a paragraph selection on the Mac.
        let selectHold: TimeInterval = 0.55
        /// Min distance after selectHold before we commit mouse-down drag.
        let selectMoveSlop: CGFloat = 28

        private var twoLast: CGPoint = .zero
        private var pinchBegan = false
        private var longSent = false
        private var threeFired = false
        weak var pinch: UIPinchGestureRecognizer?
        weak var twoPan: UIPanGestureRecognizer?
        weak var threePan: UIPanGestureRecognizer?

        // Raw one-finger tracking (avoids UITap/UIPan fighting → broken double-click).
        private var oneTouch: UITouch?
        private var oneStart: CGPoint = .zero
        private var oneStartTime: Date = .distantPast
        private var oneDragArmed = false
        private var oneSelectDrag = false
        private var oneLast: CGPoint = .zero

        func install(on v: DesktopInputView) {
            v.isMultipleTouchEnabled = true
            v.isUserInteractionEnabled = true
            v.backgroundColor = .clear
            // One-finger is handled in DesktopInputView touches* — no UITap/UIPan.

            let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLong(_:)))
            long.numberOfTouchesRequired = 2
            long.minimumPressDuration = 0.45
            long.allowableMovement = 12
            long.cancelsTouchesInView = false
            long.delegate = self
            v.addGestureRecognizer(long)

            let two = UIPanGestureRecognizer(target: self, action: #selector(handleTwo(_:)))
            two.minimumNumberOfTouches = 2
            two.maximumNumberOfTouches = 2
            two.cancelsTouchesInView = false
            two.delegate = self
            v.addGestureRecognizer(two)
            twoPan = two

            let three = UIPanGestureRecognizer(target: self, action: #selector(handleThree(_:)))
            three.minimumNumberOfTouches = 3
            three.maximumNumberOfTouches = 3
            three.cancelsTouchesInView = false
            three.delegate = self
            v.addGestureRecognizer(three)
            threePan = three

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.cancelsTouchesInView = false
            pinch.delegate = self
            v.addGestureRecognizer(pinch)
            self.pinch = pinch
        }

        func oneFingerBegan(_ touch: UITouch, in view: UIView) {
            if oneTouch != nil {
                // UIKit can omit touchesCancelled during system interruptions.
                // Do not let one orphaned UITouch permanently disable every tap.
                guard Date().timeIntervalSince(oneStartTime) > 2 else { return }
                oneFingerCancelAll()
            }
            oneTouch = touch
            oneStart = touch.location(in: view)
            oneLast = oneStart
            oneStartTime = Date()
            oneDragArmed = false
            oneSelectDrag = false
        }

        /// Commit as drag only when clearly not a (double-)tap: far move, or held then moved.
        private func shouldArmDrag(dist: CGFloat, held: TimeInterval) -> Bool {
            if dist < tapSlop { return false }
            // Pressed then moved → text select / drag (needs longer dwell + real move).
            if held >= selectHold, dist >= selectMoveSlop { return true }
            // Large move even if quick → cursor pan (not a tap).
            if dist >= tapMaxDist { return true }
            // Quick jitter under tapMaxDist → keep as potential (double-)tap.
            if held < tapMaxDuration { return false }
            // Long dwell with only tiny drift: still a tap, not a select-drag.
            return false
        }

        func oneFingerMoved(_ touch: UITouch, in view: UIView) {
            guard touch === oneTouch else { return }
            let loc = touch.location(in: view)
            let dist = hypot(loc.x - oneStart.x, loc.y - oneStart.y)
            let held = Date().timeIntervalSince(oneStartTime)
            if !oneDragArmed {
                guard shouldArmDrag(dist: dist, held: held) else {
                    oneLast = loc
                    return
                }
                oneDragArmed = true
                // Select only if they pressed ≥selectHold AND moved enough before arming.
                oneSelectDrag = held >= selectHold && dist >= selectMoveSlop
                oneLast = oneStart
                // began location = touch start (for select origin), not current finger.
                onOneFinger?(oneStart, .zero, .began, oneSelectDrag)
            }
            let trans = CGSize(width: loc.x - oneStart.x, height: loc.y - oneStart.y)
            onOneFinger?(loc, trans, .changed, oneSelectDrag)
            oneLast = loc
        }

        func oneFingerEnded(_ touch: UITouch, in view: UIView, cancelled: Bool) {
            guard touch === oneTouch else { return }
            let loc = touch.location(in: view)
            let select = oneSelectDrag
            defer {
                oneTouch = nil
                oneDragArmed = false
                oneSelectDrag = false
            }
            if cancelled {
                if oneDragArmed {
                    let trans = CGSize(width: loc.x - oneStart.x, height: loc.y - oneStart.y)
                    onOneFinger?(loc, trans, .cancelled, select)
                }
                return
            }
            if oneDragArmed {
                let trans = CGSize(width: loc.x - oneStart.x, height: loc.y - oneStart.y)
                onOneFinger?(loc, trans, .ended, select)
            } else if !longSent {
                // Never armed as drag → click (incl. both taps of a double-click).
                onTap?(oneStart)
            }
        }

        func oneFingerCancelAll() {
            if oneDragArmed {
                onOneFinger?(oneLast, CGSize(width: oneLast.x - oneStart.x, height: oneLast.y - oneStart.y), .cancelled, oneSelectDrag)
            }
            oneTouch = nil
            oneDragArmed = false
            oneSelectDrag = false
        }

        @objc func handleLong(_ g: UILongPressGestureRecognizer) {
            guard let v = g.view else { return }
            if g.state == .began, !longSent {
                longSent = true
                oneFingerCancelAll()
                onLongPress?(g.location(in: v))
            }
            if g.state == .ended || g.state == .cancelled || g.state == .failed {
                longSent = false
            }
        }

        @objc func handleTwo(_ g: UIPanGestureRecognizer) {
            if g.state == .began { oneFingerCancelAll() }
            // If fingers are clearly pinching, don't emit scroll.
            if let pinch, pinch.state == .began || pinch.state == .changed,
               abs(pinch.scale - 1) > 0.04 {
                return
            }
            let p = g.translation(in: g.view)
            switch g.state {
            case .began:
                twoLast = p
            case .changed:
                let dx = p.x - twoLast.x
                let dy = p.y - twoLast.y
                twoLast = p
                if abs(dx) > 0.3 || abs(dy) > 0.3 {
                    onTwoFingerScroll?(dx, dy)
                }
            default:
                twoLast = .zero
            }
        }

        @objc func handleThree(_ g: UIPanGestureRecognizer) {
            if g.state == .began { oneFingerCancelAll() }
            switch g.state {
            case .began:
                threeFired = false
            case .changed, .ended:
                guard !threeFired, let v = g.view else { return }
                let t = g.translation(in: v)
                if let swipe = DesktopSpaceSwipe.interpret(translation: t, minDistance: 50) {
                    threeFired = true
                    onThreeFingerSwipe?(swipe)
                }
            default:
                threeFired = false
            }
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { oneFingerCancelAll() }
            let loc = g.location(in: g.view)
            switch g.state {
            case .began:
                if abs(g.scale - 1) < 0.03 { return }
                pinchBegan = true
                onPinch?(g.scale, loc, g.state)
            case .changed:
                if !pinchBegan {
                    if abs(g.scale - 1) < 0.04 { return }
                    pinchBegan = true
                }
                onPinch?(g.scale, loc, g.state)
            case .ended, .cancelled, .failed:
                if pinchBegan {
                    pinchBegan = false
                    onPinch?(g.scale, loc, g.state)
                }
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            if (gestureRecognizer === twoPan && other === pinch) ||
                (gestureRecognizer === pinch && other === twoPan) {
                return true
            }
            return false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf other: UIGestureRecognizer
        ) -> Bool {
            return false
        }
    }
}

enum DesktopInputExclusionRegions {
    private struct Region {
        weak var window: UIWindow?
        var rect: CGRect
    }

    private static var regions: [String: Region] = [:]

    static func update(id: String, window: UIWindow, rect: CGRect) {
        regions[id] = Region(window: window, rect: rect)
    }

    static func remove(id: String) {
        regions.removeValue(forKey: id)
    }

    static func contains(_ point: CGPoint, in window: UIWindow) -> Bool {
        regions = regions.filter { $0.value.window != nil }
        return regions.values.contains { region in
            region.window === window && region.rect.contains(point)
        }
    }
}

final class DesktopInputView: UIView {
    weak var coordinator: DesktopInputSurface.Coordinator?

    override var canBecomeFirstResponder: Bool { false }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard super.point(inside: point, with: event) else { return false }
        guard let window else { return true }
        let windowPoint = convert(point, to: window)
        return !DesktopInputExclusionRegions.contains(windowPoint, in: window)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let coordinator else { return }
        let all = event?.allTouches?.filter { $0.phase == .began || $0.phase == .moved || $0.phase == .stationary } ?? []
        if all.count > 1 {
            coordinator.oneFingerCancelAll()
            return
        }
        if let t = touches.first {
            coordinator.oneFingerBegan(t, in: self)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let coordinator else { return }
        let all = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? []
        if all.count > 1 {
            coordinator.oneFingerCancelAll()
            return
        }
        if let t = touches.first {
            coordinator.oneFingerMoved(t, in: self)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        guard let coordinator else { return }
        for t in touches {
            coordinator.oneFingerEnded(t, in: self, cancelled: false)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        guard let coordinator else { return }
        for t in touches {
            coordinator.oneFingerEnded(t, in: self, cancelled: true)
        }
    }
}

// MARK: - Soft keyboard (same TerminalAccessory as SSH)

/// Invisible `TerminalView` first-responder + stock KoKo `TerminalAccessory`.
/// IME composition stays inside SwiftTerm (pinyin not leaked); accessory keys
/// are translated from terminal bytes → Mac keycodes / unicode.
struct DesktopSoftKeyboard: UIViewRepresentable {
    @Binding var isFocused: Bool
    var onText: (String) -> Void
    var onKeyCode: (_ code: Int, _ modifiers: Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let host = UIView(frame: .zero)
        host.isUserInteractionEnabled = false
        host.backgroundColor = .clear

        let terminal = TerminalView(
            frame: .zero,
            font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        terminal.terminalDelegate = context.coordinator
        terminal.isOpaque = false
        terminal.backgroundColor = .clear
        terminal.alpha = 0.01
        terminal.isScrollEnabled = false
        terminal.isUserInteractionEnabled = false
        terminal.allowMouseReporting = false
        terminal.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: host.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])

        let short = UIDevice.current.userInterfaceIdiom == .phone
        let height: CGFloat = short ? 36 : 48
        let width = max(UIScreen.main.bounds.width, 320)
        let accessory = TerminalAccessory(
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            inputViewStyle: .keyboard,
            container: terminal
        )
        accessory.sizeToFit()
        terminal.inputAccessoryView = accessory
        terminal.inputAssistantItem.leadingBarButtonGroups = []
        terminal.inputAssistantItem.trailingBarButtonGroups = []
        // Desktop has no PTY line to wipe / font to resize.
        terminal.accessoryClearInputHandler = {}
        terminal.accessoryFontSizeStepHandler = { _ in }

        context.coordinator.terminal = terminal
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.desiredFocus = isFocused
        context.coordinator.syncFocus()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var parent: DesktopSoftKeyboard
        weak var terminal: TerminalView?
        var desiredFocus = false

        init(parent: DesktopSoftKeyboard) {
            self.parent = parent
        }

        func syncFocus() {
            guard let terminal else { return }
            if desiredFocus {
                if !terminal.isFirstResponder {
                    DispatchQueue.main.async { [weak terminal] in
                        terminal?.reloadInputViews()
                        _ = terminal?.becomeFirstResponder()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak terminal] in
                        terminal?.reloadInputViews()
                        _ = terminal?.becomeFirstResponder()
                    }
                }
            } else if terminal.isFirstResponder {
                DispatchQueue.main.async { [weak terminal] in
                    _ = terminal?.resignFirstResponder()
                }
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            DesktopTerminalKeyBridge.dispatch(
                Array(data),
                onText: parent.onText,
                onKeyCode: parent.onKeyCode
            )
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Maps SwiftTerm / TerminalAccessory byte sequences onto Mac HID keys.
enum DesktopTerminalKeyBridge {
    private static let specials: [([UInt8], Int, Int)] = {
        var rows: [([UInt8], Int, Int)] = [
            (EscapeSequences.cmdEsc, RE2HostKey.escape, 0),
            (EscapeSequences.cmdTab, RE2HostKey.tab, 0),
            (EscapeSequences.cmdRet, RE2HostKey.returnKey, 0),
            (EscapeSequences.cmdNewLine, RE2HostKey.returnKey, 0),
            (EscapeSequences.cmdDel, RE2HostKey.delete, 0),
            ([0x08], RE2HostKey.delete, 0),
            (EscapeSequences.cmdDelKey, RE2HostKey.forwardDelete, 0),
            (EscapeSequences.moveUpNormal, RE2HostKey.up, 0),
            (EscapeSequences.moveUpApp, RE2HostKey.up, 0),
            (EscapeSequences.moveDownNormal, RE2HostKey.down, 0),
            (EscapeSequences.moveDownApp, RE2HostKey.down, 0),
            (EscapeSequences.moveLeftNormal, RE2HostKey.left, 0),
            (EscapeSequences.moveLeftApp, RE2HostKey.left, 0),
            (EscapeSequences.moveRightNormal, RE2HostKey.right, 0),
            (EscapeSequences.moveRightApp, RE2HostKey.right, 0),
            (EscapeSequences.moveHomeNormal, RE2HostKey.home, 0),
            (EscapeSequences.moveHomeApp, RE2HostKey.home, 0),
            (EscapeSequences.moveEndNormal, RE2HostKey.end, 0),
            (EscapeSequences.moveEndApp, RE2HostKey.end, 0),
            (EscapeSequences.cmdPageUp, RE2HostKey.pageUp, 0),
            (EscapeSequences.cmdPageDown, RE2HostKey.pageDown, 0),
        ]
        let fKeys = [
            RE2HostKey.f1, RE2HostKey.f2, RE2HostKey.f3, RE2HostKey.f4,
            RE2HostKey.f5, RE2HostKey.f6, RE2HostKey.f7, RE2HostKey.f8,
            RE2HostKey.f9, RE2HostKey.f10, RE2HostKey.f11, RE2HostKey.f12,
        ]
        for (i, seq) in EscapeSequences.cmdF.enumerated() where i < fKeys.count {
            rows.append((seq, fKeys[i], 0))
        }
        return rows
    }()

    static func dispatch(
        _ bytes: [UInt8],
        onText: (String) -> Void,
        onKeyCode: (Int, Int) -> Void
    ) {
        guard !bytes.isEmpty else { return }
        for (seq, code, mods) in specials where seq == bytes {
            onKeyCode(code, mods)
            return
        }
        // Ctrl+A … Ctrl+Z
        if bytes.count == 1, bytes[0] >= 0x01, bytes[0] <= 0x1a {
            let idx = Int(bytes[0]) - 1
            if idx < RE2HostKey.letterAZ.count {
                onKeyCode(RE2HostKey.letterAZ[idx], RE2HostKey.Mod.ctrl)
                return
            }
        }
        // ESC + letter → Option/Alt + letter (TerminalAccessory meta)
        if bytes.count == 2, bytes[0] == 0x1b, bytes[1] >= 0x61, bytes[1] <= 0x7a {
            let idx = Int(bytes[1]) - 0x61
            if idx >= 0, idx < RE2HostKey.letterAZ.count {
                onKeyCode(RE2HostKey.letterAZ[idx], RE2HostKey.Mod.alt)
                return
            }
        }
        if bytes.count == 2, bytes[0] == 0x1b, bytes[1] >= 0x41, bytes[1] <= 0x5a {
            let idx = Int(bytes[1]) - 0x41
            if idx >= 0, idx < RE2HostKey.letterAZ.count {
                onKeyCode(RE2HostKey.letterAZ[idx], RE2HostKey.Mod.alt)
                return
            }
        }
        if bytes == EscapeSequences.cmdInsert {
            return // Mac has no Insert
        }
        if let text = String(bytes: bytes, encoding: .utf8), !text.isEmpty {
            // Ignore lone ESC already handled; strip C0 controls if any slipped through.
            if text.unicodeScalars.allSatisfy({ $0.value >= 32 || $0.value == 9 || $0.value == 10 || $0.value == 13 }) {
                onText(text)
            }
        }
    }
}
