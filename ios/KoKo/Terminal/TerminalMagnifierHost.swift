import SwiftTerm
import UIKit

/// Wraps ``TerminalView`` and forwards pinch-to-resize for terminal font scaling.
final class TerminalHostView: UIView {
    let terminalView: TerminalView
    var onPinchFontScale: ((CGFloat) -> Void)?

    private var pinchBaselineSize: CGFloat = 0

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        backgroundColor = terminalView.backgroundColor

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchBaselineSize = terminalView.font.pointSize
        case .changed:
            let proposed = pinchBaselineSize * gesture.scale
            onPinchFontScale?(proposed)
        default:
            break
        }
    }
}
