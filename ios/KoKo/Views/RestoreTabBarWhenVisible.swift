import SwiftUI
import UIKit

/// Re-shows the UITabBar after a pushed page used `.toolbar(.hidden, for: .tabBar)`.
///
/// Critical: HostListView stays under `navigationDestination` pushes (Desktop /
/// Terminal). Blindly forcing `tabBar.isHidden = false` from this background
/// representable was undoing every DesktopViewer hide — the “tab bar keeps
/// coming back” regression.
struct RestoreTabBarWhenVisible: UIViewControllerRepresentable {
    /// When false (e.g. desktop destination active), never touch the tab bar.
    var enabled: Bool = true

    func makeUIViewController(context: Context) -> UIViewController {
        Controller()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let c = uiViewController as? Controller
        c?.enabled = enabled
        c?.apply()
    }

    private final class Controller: UIViewController {
        var enabled = true

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        func apply() {
            guard enabled, isInTopNavigationPage else { return }
            tabBarController?.tabBar.isHidden = false
        }

        /// True only when this representable lives under the nav stack’s top VC
        /// (Hosts list visible). False while DesktopViewer / Terminal is pushed.
        private var isInTopNavigationPage: Bool {
            guard let nav = nearestNavigationController,
                  let top = nav.topViewController
            else { return true }
            var vc: UIViewController? = self
            while let cur = vc {
                if cur === top { return true }
                vc = cur.parent
            }
            return false
        }

        private var nearestNavigationController: UINavigationController? {
            var r: UIResponder? = self
            while let cur = r {
                if let nav = cur as? UINavigationController { return nav }
                r = cur.next
            }
            return navigationController
        }
    }
}

/// UIKit-level hide — SwiftUI `.toolbar(.hidden, for: .tabBar)` alone loses to
/// parent `RestoreTabBarWhenVisible` / iOS 18 tabBarOnly churn.
struct HideTabBarWhenVisible: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Controller()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        (uiViewController as? Controller)?.hide()
    }

    private final class Controller: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            hide()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            hide()
        }

        func hide() {
            tabBarController?.tabBar.isHidden = true
        }
    }
}
