import SwiftUI
import UIKit

extension View {
    /// 用于 Tab 的四个根页面，确保从次级页面返回后恢复 TabBar。
    func showsRootTabBar() -> some View {
        modifier(ShowRootTabBarModifier())
    }

    /// 用于从 Tab 根页面 push 出的次级页面；返回根页面时自动恢复 TabBar。
    func hidesRootTabBar() -> some View {
        modifier(HideRootTabBarModifier())
    }
}

private struct ShowRootTabBarModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbar(.visible, for: .tabBar)
                .onAppear {
                    TabBarVisibilityController.shared.restoreForRootPage()
                }
        } else {
            content.onAppear {
                TabBarVisibilityController.shared.restoreForRootPage()
            }
        }
    }
}

private struct HideRootTabBarModifier: ViewModifier {
    @State private var visibilityToken = UUID()

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbar(.hidden, for: .tabBar)
                .onAppear { hideTabBar() }
                .onDisappear { restoreTabBar() }
        } else {
            content
                .onAppear { hideTabBar() }
                .onDisappear { restoreTabBar() }
        }
    }

    private func hideTabBar() {
        TabBarVisibilityController.shared.hide(for: visibilityToken)
    }

    private func restoreTabBar() {
        TabBarVisibilityController.shared.restore(for: visibilityToken)
    }
}

/// 使用 token 计数可避免二级页继续 push 三级页时被前一页的 onDisappear 提前恢复。
/// UIKit 状态同时作为 SwiftUI toolbar 可见性状态的恢复兜底。
private final class TabBarVisibilityController {
    static let shared = TabBarVisibilityController()

    private var hiddenTokens = Set<UUID>()
    private weak var tabBarController: UITabBarController?

    private init() {}

    func hide(for token: UUID) {
        guard let controller = activeTabBarController() else { return }

        if tabBarController !== controller {
            tabBarController?.tabBar.isHidden = false
            hiddenTokens.removeAll()
            tabBarController = controller
        }

        hiddenTokens.insert(token)
        setTabBarHidden(true)
    }

    func restore(for token: UUID) {
        hiddenTokens.remove(token)

        // 延迟到本轮导航生命周期结束，让下一个次级页有机会先登记自己的 token。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hiddenTokens.isEmpty else { return }
            self.setTabBarHidden(false)
        }
    }

    func restoreForRootPage() {
        hiddenTokens.removeAll()
        if tabBarController == nil {
            tabBarController = activeTabBarController()
        }
        setTabBarHidden(false)
    }

    private func setTabBarHidden(_ hidden: Bool) {
        guard let controller = tabBarController else { return }
        controller.tabBar.isHidden = hidden
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    private func activeTabBarController() -> UITabBarController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) }
            .first
        return findTabBarController(in: keyWindow?.rootViewController)
    }

    private func findTabBarController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let tabBarController = controller as? UITabBarController {
            return tabBarController
        }
        if let presented = findTabBarController(in: controller.presentedViewController) {
            return presented
        }
        for child in controller.children {
            if let tabBarController = findTabBarController(in: child) {
                return tabBarController
            }
        }
        return nil
    }
}
