import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case hosts
    case sessions
    case keys
    case settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .hosts: "Hosts"
        case .sessions: "Sessions"
        case .keys: "Keys"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .hosts: "server.rack"
        case .sessions: "terminal"
        case .keys: "key"
        case .settings: "gearshape"
        }
    }
}
