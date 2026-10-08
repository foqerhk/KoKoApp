import Combine
import SwiftTerm
import SwiftUI
import UIKit

/// Tracks which terminal should own the half-fold floating accessory (window-level).
@MainActor
final class FloatingAccessoryCoordinator: ObservableObject {
    static let shared = FloatingAccessoryCoordinator()

    weak var terminalView: TerminalView?
    @Published private(set) var isActive = false

    func setActive(_ active: Bool, terminal: TerminalView?) {
        if active, let terminal {
            let changed = !isActive || terminalView !== terminal
            terminalView = terminal
            if !isActive { isActive = true }
            else if changed { objectWillChange.send() }
            if changed { FloatingAccessoryInstaller.shared.refresh() }
        } else if terminal == nil || terminalView === terminal {
            let changed = isActive || terminalView != nil
            isActive = false
            terminalView = nil
            if changed {
                objectWillChange.send()
                FloatingAccessoryInstaller.shared.refresh()
            }
        }
    }
}

/// Installs a window-level `TerminalAccessory` pinned to the live keyboard top.
@MainActor
final class FloatingAccessoryInstaller {
    static let shared = FloatingAccessoryInstaller()

    private weak var host: FloatingAccessoryHostView?
    private var keyboardVisible = false
    private var observers: [NSObjectProtocol] = []
    private var lastKeyboardTopY: CGFloat?
    private var lastAnimationDuration: TimeInterval = 0.25
    private var lastAnimationOptions: UIView.AnimationOptions = .curveEaseInOut
    private var pendingKeyboardNote: Notification?
    private var keyboardDebounceWork: DispatchWorkItem?
    private var isRefreshing = false

    private init() {
        let center = NotificationCenter.default
        let coalesce: (Notification) -> Void = { [weak self] note in
            Task { @MainActor in
                self?.enqueueKeyboardNote(note)
            }
        }
        observers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main, using: coalesce),
            center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main, using: coalesce),
            center.addObserver(forName: UIResponder.keyboardDidChangeFrameNotification, object: nil, queue: .main, using: coalesce),
            center.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main, using: coalesce),
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main, using: coalesce),
            center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main, using: coalesce),
            center.addObserver(forName: UITextInputMode.currentInputModeDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.host?.requestLayout(reason: "inputMode")
                }
            },
            center.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.host?.installIfNeeded(in: self?.keyWindow())
                    self?.host?.requestLayout(reason: "orientation")
                }
            },
        ]
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let hinge = DuoHingeMonitor.shared
        let coordinator = FloatingAccessoryCoordinator.shared
        let shouldShow = hinge.prefersFloatingAccessory
            && keyboardVisible
            && coordinator.isActive
            && coordinator.terminalView != nil

        if shouldShow {
            ensureHost()
            host?.update(
                terminal: coordinator.terminalView,
                visible: true,
                reportedKeyboardTop: lastKeyboardTopY,
                animationDuration: lastAnimationDuration,
                animationOptions: lastAnimationOptions
            )
        } else {
            host?.update(
                terminal: coordinator.terminalView,
                visible: false,
                reportedKeyboardTop: nil,
                animationDuration: lastAnimationDuration,
                animationOptions: lastAnimationOptions
            )
            if !hinge.prefersFloatingAccessory || !coordinator.isActive {
                removeHost()
            }
        }
    }

    private func enqueueKeyboardNote(_ note: Notification) {
        pendingKeyboardNote = note
        keyboardDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingKeyboardNote else { return }
            self.pendingKeyboardNote = nil
            self.handleKeyboardNote(pending)
        }
        keyboardDebounceWork = work
        // Coalesce will/did spam during fold + rotate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func handleKeyboardNote(_ note: Notification) {
        if note.name == UIResponder.keyboardWillHideNotification
            || note.name == UIResponder.keyboardDidHideNotification {
            let wasVisible = keyboardVisible
            keyboardVisible = false
            lastKeyboardTopY = nil
            captureAnimation(from: note)
            DuoHingeMonitor.shared.applyKeyboardOverlap(0, screenHeight: currentScreenHeight())
            if wasVisible { refresh() }
            return
        }

        guard
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let window = keyWindow()
        else { return }

        captureAnimation(from: note)

        let converted = window.convert(frame, from: nil)
        // Ignore transitional garbage frames during rotation.
        guard converted.height > 80, converted.width > 80 else { return }

        let overlap = max(0, window.bounds.maxY - converted.minY)
        let visible = overlap > 1
        let newTop = visible ? converted.minY : nil

        let topChanged = abs((newTop ?? -1) - (lastKeyboardTopY ?? -1)) > 0.5
        let visibilityChanged = visible != keyboardVisible

        keyboardVisible = visible
        lastKeyboardTopY = newTop

        DuoHingeMonitor.shared.applyKeyboardOverlap(overlap, screenHeight: window.bounds.height)

        if visibilityChanged {
            refresh()
        } else if visible, topChanged {
            host?.update(
                terminal: FloatingAccessoryCoordinator.shared.terminalView,
                visible: true,
                reportedKeyboardTop: lastKeyboardTopY,
                animationDuration: lastAnimationDuration,
                animationOptions: lastAnimationOptions
            )
        }
    }

    private func captureAnimation(from note: Notification) {
        if let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double {
            lastAnimationDuration = duration
        }
        if let curveValue = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt {
            lastAnimationOptions = UIView.AnimationOptions(rawValue: curveValue << 16)
        }
    }

    private func ensureHost() {
        guard let window = keyWindow() else { return }
        if let host {
            host.installIfNeeded(in: window)
            return
        }
        let view = FloatingAccessoryHostView(frame: window.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = true
        view.backgroundColor = .clear
        window.addSubview(view)
        host = view
    }

    private func removeHost() {
        host?.removeFromSuperview()
        host = nil
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private func currentScreenHeight() -> CGFloat {
        keyWindow()?.bounds.height ?? UIScreen.main.bounds.height
    }
}

/// Full-window host: positions one long-lived `TerminalAccessory` above the keyboard.
final class FloatingAccessoryHostView: UIView {
    private weak var accessory: TerminalAccessory?
    private weak var boundTerminal: TerminalView?
    private var barVisible = false
    private var reportedKeyboardTop: CGFloat?
    private var animationDuration: TimeInterval = 0.25
    private var animationOptions: UIView.AnimationOptions = .curveEaseInOut
    private var lastAppliedFrame: CGRect = .null
    private var lastHostSize: CGSize = .zero
    private var layoutWorkItem: DispatchWorkItem?
    private var isApplyingLayout = false

    private var regularAccessoryHeight: CGFloat {
        UIDevice.current.userInterfaceIdiom == .phone ? 40 : 48
    }

    private var compactAccessoryHeight: CGFloat {
        UIDevice.current.userInterfaceIdiom == .phone ? 28 : 34
    }

    private func resolvedAccessoryHeight(keyboardTop: CGFloat, lowerFloor: CGFloat?) -> CGFloat {
        let halfFold = DuoHingeMonitor.shared.prefersFloatingAccessory
        let nonEnglish = !Self.isEnglishInputMode(boundTerminal)
        var preferred = (halfFold && nonEnglish) ? compactAccessoryHeight : regularAccessoryHeight
        if let lowerFloor {
            let remaining = keyboardTop - lowerFloor
            if remaining < preferred {
                preferred = max(24, remaining)
            }
        }
        return preferred
    }

    private static func isEnglishInputMode(_ terminal: TerminalView?) -> Bool {
        let lang = (terminal?.textInputMode?.primaryLanguage ?? "").lowercased()
        if lang.isEmpty { return true }
        return lang == "en" || lang == "ascii" || lang.hasPrefix("en-") || lang.hasPrefix("en_")
    }

    func installIfNeeded(in window: UIWindow?) {
        guard let window else { return }
        if superview !== window {
            frame = window.bounds
            autoresizingMask = [.flexibleWidth, .flexibleHeight]
            window.addSubview(self)
            lastHostSize = .zero
        } else if bounds.size != window.bounds.size {
            frame = window.bounds
        }
    }

    /// Update visibility / keyboard top without recreating the bar unless the terminal changes.
    func update(
        terminal: TerminalView?,
        visible: Bool,
        reportedKeyboardTop: CGFloat?,
        animationDuration: TimeInterval,
        animationOptions: UIView.AnimationOptions
    ) {
        let wantVisible = visible && terminal != nil
        let terminalChanged = terminal != nil && boundTerminal !== terminal
        let topChanged = abs((reportedKeyboardTop ?? -1) - (self.reportedKeyboardTop ?? -1)) > 0.5
        let visibilityChanged = wantVisible != barVisible

        self.reportedKeyboardTop = reportedKeyboardTop
        self.animationDuration = animationDuration
        self.animationOptions = animationOptions

        if let terminal {
            if accessory == nil || terminalChanged {
                recreateAccessory(for: terminal)
            } else {
                accessory?.terminalView = terminal
                boundTerminal = terminal
            }
        }

        if visibilityChanged {
            barVisible = wantVisible
            isHidden = !wantVisible
            isUserInteractionEnabled = wantVisible
            if !wantVisible {
                accessory?.isHidden = true
                lastAppliedFrame = .null
                return
            }
        } else {
            barVisible = wantVisible
        }

        guard barVisible else { return }
        if visibilityChanged || terminalChanged || topChanged || lastAppliedFrame.isNull {
            applyLayout(animated: visibilityChanged || topChanged)
        }
    }

    func requestLayout(reason: String) {
        layoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyLayout(animated: false)
        }
        layoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        _ = reason
    }

    private func recreateAccessory(for terminal: TerminalView) {
        accessory?.removeFromSuperview()
        lastAppliedFrame = .null
        let height = resolvedAccessoryHeight(
            keyboardTop: reportedKeyboardTop ?? bounds.maxY,
            lowerFloor: isVerticalFlexSplit() ? verticalLowerFloorY() : nil
        )
        let bar = TerminalAccessory(
            frame: CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: height),
            inputViewStyle: .keyboard,
            container: terminal
        )
        bar.backgroundColor = .secondarySystemBackground
        // Always manual frames — toggling Auto Layout vs frame was a layout feedback loop.
        bar.translatesAutoresizingMaskIntoConstraints = true
        addSubview(bar)
        accessory = bar
        boundTerminal = terminal
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        // Only react to real host size changes (rotation), not our own accessory moves.
        if abs(size.width - lastHostSize.width) > 0.5 || abs(size.height - lastHostSize.height) > 0.5 {
            lastHostSize = size
            if barVisible {
                applyLayout(animated: false)
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        requestLayout(reason: "trait")
    }

    private func applyLayout(animated: Bool) {
        guard barVisible, let accessory, !isApplyingLayout else { return }
        isApplyingLayout = true
        defer { isApplyingLayout = false }

        let verticalSplit = isVerticalFlexSplit()
        let lowerFloor = verticalSplit ? verticalLowerFloorY() : nil

        var measuredTop = resolveKeyboardTopY(lowerFloor: lowerFloor)
        if let lowerFloor {
            measuredTop = max(measuredTop, lowerFloor)
        }

        let height = resolvedAccessoryHeight(keyboardTop: measuredTop, lowerFloor: lowerFloor)
        // Non-English candidate chrome often sits a few pt above the reported keyboard frame.
        let imeNudge: CGFloat = Self.isEnglishInputMode(boundTerminal) ? 0 : 8
        var barTop = measuredTop - height - imeNudge
        if let lowerFloor {
            barTop = max(barTop, lowerFloor)
        }
        let target = CGRect(x: 0, y: barTop, width: bounds.width, height: height)

        // Skip no-op updates — TerminalAccessory.setupUI runs on every bounds change and flashes.
        if !lastAppliedFrame.isNull,
           abs(lastAppliedFrame.minX - target.minX) < 0.5,
           abs(lastAppliedFrame.minY - target.minY) < 0.5,
           abs(lastAppliedFrame.width - target.width) < 0.5,
           abs(lastAppliedFrame.height - target.height) < 0.5 {
            accessory.isHidden = false
            return
        }

        let animations = {
            accessory.frame = target
            accessory.isHidden = false
        }

        if animated, animationDuration > 0.01 {
            UIView.animate(
                withDuration: min(animationDuration, 0.35),
                delay: 0,
                options: animationOptions.union([.beginFromCurrentState, .allowUserInteraction]),
                animations: animations
            )
        } else {
            animations()
        }
        lastAppliedFrame = target
    }

    private func isVerticalFlexSplit() -> Bool {
        if #available(iOS 27.1, *) {
            let divisions = reservedRegions(kind: .division).filter(\.isActive)
            if let region = divisions.max(by: { $0.frame.height < $1.frame.height }) {
                if region.frame.width >= bounds.width * 0.7, region.frame.height < bounds.height * 0.3 {
                    return true
                }
                if region.frame.height >= bounds.height * 0.7, region.frame.width < bounds.width * 0.3 {
                    return false
                }
            }
        }
        let hinge = DuoHingeMonitor.shared
        if hinge.lowerContentMinY > 1, hinge.upperContentMaxY > 1 {
            let band = hinge.lowerContentMinY - hinge.upperContentMaxY
            if band < bounds.height * 0.25, abs(hinge.upperContentMaxY - bounds.midY) < bounds.height * 0.2 {
                return true
            }
        }
        return bounds.height >= bounds.width
    }

    private func verticalLowerFloorY() -> CGFloat {
        let hinge = DuoHingeMonitor.shared
        if hinge.lowerContentMinY > 1 {
            return hinge.lowerContentMinY
        }
        if #available(iOS 27.1, *) {
            let divisions = reservedRegions(kind: .division).filter(\.isActive)
            if let bottom = divisions.map(\.frame.maxY).max(), bottom > 1 {
                return bottom
            }
        }
        return bounds.midY + 8
    }

    private func resolveKeyboardTopY(lowerFloor: CGFloat?) -> CGFloat {
        var candidates: [CGFloat] = []

        let guideTop = keyboardLayoutGuide.layoutFrame.minY
        if isPlausibleKeyboardTop(guideTop) { candidates.append(guideTop) }
        if let reportedKeyboardTop, isPlausibleKeyboardTop(reportedKeyboardTop) {
            candidates.append(reportedKeyboardTop)
        }
        if let remote = Self.dockedKeyboardTopY(convertingTo: self) {
            candidates.append(remote)
        }

        let pool: [CGFloat]
        if let lowerFloor {
            let onLower = candidates.filter { $0 >= lowerFloor - 1 }
            pool = onLower.isEmpty ? candidates : onLower
        } else {
            pool = candidates
        }

        if let top = pool.min() { return top }
        if let lowerFloor { return lowerFloor }
        return bounds.maxY - 280
    }

    private func isPlausibleKeyboardTop(_ top: CGFloat) -> Bool {
        guard top > 1, top < bounds.maxY - 80 else { return false }
        return (bounds.maxY - top) >= 160
    }

    private static func dockedKeyboardTopY(convertingTo view: UIView) -> CGFloat? {
        var best: CGFloat?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window !== view.window {
                let name = NSStringFromClass(type(of: window))
                let isKeyboardChrome =
                    name.contains("Keyboard")
                    || name.contains("UITextEffects")
                    || name.contains("UIRemoteInput")
                    || name.contains("UIInputSet")
                guard isKeyboardChrome, !window.isHidden else { continue }
                let frame = view.convert(window.bounds, from: window)
                guard frame.height > 120, frame.width > 80 else { continue }
                guard frame.maxY >= view.bounds.maxY - 8 else { continue }
                best = best.map { min($0, frame.minY) } ?? frame.minY
            }
        }
        return best
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard barVisible, let accessory else { return nil }
        let frame = accessory.frame
        guard frame.contains(point) else { return nil }
        return accessory.hitTest(convert(point, to: accessory), with: event)
    }
}

struct FloatingAccessoryWindowOverlay: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                FloatingAccessoryInstaller.shared.refresh()
            }
            // Debounce hinge publisher storms during fold/rotate.
            .onReceive(
                DuoHingeMonitor.shared.$prefersFloatingAccessory
                    .removeDuplicates()
                    .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            ) { _ in
                FloatingAccessoryInstaller.shared.refresh()
            }
            .onReceive(
                FloatingAccessoryCoordinator.shared.$isActive
                    .removeDuplicates()
                    .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            ) { _ in
                FloatingAccessoryInstaller.shared.refresh()
            }
    }
}
