import SwiftUI
import UIKit

/// Layout bucket for large-screen UI under `ipad/`.
enum DeviceLayoutKind: Equatable {
    /// Standard iPhone portrait / folded cover screen.
    case phoneCompact
    /// Unfolded foldable iPhone (`horizontalSizeClass == .regular` on phone idiom).
    case phoneDuo
    /// iPad and iPadOS windowing.
    case tablet
}

enum DeviceLayout {
    static func current(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> DeviceLayoutKind {
        let idiom = UIDevice.current.userInterfaceIdiom
        if idiom == .pad {
            return .tablet
        }
        if idiom == .phone, horizontalSizeClass == .regular {
            return .phoneDuo
        }
        _ = verticalSizeClass
        return .phoneCompact
    }
}
