import SwiftUI
import UIKit

private final class HomeSettingsContainerController: UIViewController {
    private let content: UIViewController
    private var showsContent = false

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = true
        content.view.autoresizingMask = []
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let target = contentFrame(in: view.bounds)
        let current = content.view.frame
        let sizeChanged = abs(current.width - target.width) > 1 || abs(current.height - target.height) > 1
        let originChanged = abs(current.minY - target.minY) > 1
        guard sizeChanged || originChanged else { return }
        content.view.frame = target
    }

    func setShown(_ shown: Bool, animated: Bool, completion: @escaping () -> Void) {
        showsContent = shown
        let updates = {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
        guard animated else {
            updates()
            completion()
            return
        }
        UIView.animate(
            withDuration: HomeSettingsMotion.duration,
            delay: 0,
            options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
            animations: updates
        ) { _ in
            completion()
        }
    }

    private func contentFrame(in bounds: CGRect) -> CGRect {
        CGRect(x: 0, y: showsContent ? 0 : bounds.height + 2, width: bounds.width, height: bounds.height)
    }
}

private final class HomeSettingsWindow: UIWindow {
    var passesTouchesThrough = true

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !passesTouchesThrough else { return nil }
        return super.hitTest(point, with: event)
    }
}

enum HomeSettingsMotion {
    /// 短于系统 sheet。页面事先排好，点击只做这一段位移动画。
    static let duration: TimeInterval = 0.12
}

/// 设置页挂在独立窗口里。滑入只用位移，结束后不再给滚动视图的父层留 transform。
@MainActor
final class HomeSettingsPresenter {
    var onDismiss: (() -> Void)?
    private(set) var isShown = false
    private var window: UIWindow?
    private var container: HomeSettingsContainerController?
    private var host: UIHostingController<AnyView>?
    private var hasRealContent = false
    private var prepareQueued = false
    private weak var setup: SetupCoordinator?
    private weak var box: MapHomeSheetBox?

    func prepare(setup: SetupCoordinator, box: MapHomeSheetBox) {
        self.setup = setup
        self.box = box
        guard !hasRealContent, !prepareQueued else { return }
        prepareQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.prepareQueued = false
            self.installRealContent()
        }
    }

    func show() -> Bool {
        if !hasRealContent {
            installChromeIfNeeded()
        }
        guard window != nil, host != nil else { return false }
        slide(onScreen: true)
        if !hasRealContent {
            DispatchQueue.main.asyncAfter(deadline: .now() + HomeSettingsMotion.duration) { [weak self] in
                self?.installRealContent()
            }
        }
        return true
    }

    func hide() {
        guard isShown, window != nil else { return }
        slide(onScreen: false)
    }

    private func installChromeIfNeeded() {
        guard host == nil else { return }
        mount(AnyView(HomeSettingsChrome(onClose: { [weak self] in self?.requestClose() })), warm: false)
    }

    private func installRealContent() {
        guard let setup, let box, let root = HomeSettingsRoot.make(setup: setup, box: box) else { return }
        if host == nil {
            mount(AnyView(root), warm: true)
        } else if !hasRealContent {
            host?.rootView = AnyView(root)
            host?.view.setNeedsLayout()
            host?.view.layoutIfNeeded()
        }
        hasRealContent = true
        box.favoriteImport?.enterPage(box.settingsPageID)
    }

    private func mount(_ content: AnyView, warm: Bool) {
        guard let scene = foregroundScene() else { return }
        let controller = host ?? UIHostingController(rootView: content)
        if host == nil {
            controller.view.backgroundColor = .systemGroupedBackground
            disableSafeAreaFeedback(on: controller)
            host = controller
        } else {
            controller.rootView = content
        }
        let panel = window ?? HomeSettingsWindow(windowScene: scene)
        let shell = container ?? HomeSettingsContainerController(content: controller)
        panel.frame = scene.screen.bounds
        panel.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isUserInteractionEnabled = false
        panel.isHidden = true
        panel.rootViewController = shell
        window = panel
        container = shell
        shell.view.setNeedsLayout()
        shell.view.layoutIfNeeded()
        panel.isHidden = false
        if warm {
            _ = controller.view.snapshotView(afterScreenUpdates: true)
        }
    }

    private func slide(onScreen: Bool) {
        guard let panel = window, let shell = container else { return }
        isShown = onScreen
        panel.isHidden = false
        if onScreen {
            panel.backgroundColor = .clear
            panel.isOpaque = false
            (panel as? HomeSettingsWindow)?.passesTouchesThrough = false
            panel.isUserInteractionEnabled = true
            panel.makeKey()
        } else {
            panel.backgroundColor = .clear
            panel.isOpaque = false
        }
        shell.setShown(onScreen, animated: true) { [weak self] in
            guard let self, self.isShown == onScreen else { return }
            if onScreen {
                // 盖住之后不再合成底下的地图，避免往上滚时和地图抢 GPU。
                panel.backgroundColor = .systemGroupedBackground
                panel.isOpaque = true
                return
            }
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.isUserInteractionEnabled = false
            (panel as? HomeSettingsWindow)?.passesTouchesThrough = true
            self.restoreUnderlyingWindow()
            self.onDismiss?()
        }
    }

    private func disableSafeAreaFeedback(on controller: UIHostingController<AnyView>) {
        guard #available(iOS 16.4, *) else { return }
        // 滚动时安全区来回改会让 Form 在一个方向上连续重排。
        controller.safeAreaRegions = .container
    }

    private func requestClose() {
        box?.dismissSettings()
    }

    private func restoreUnderlyingWindow() {
        guard let scene = window?.windowScene else { return }
        let underlying = scene.windows.first { $0 !== window && !$0.isHidden && $0.windowLevel <= .normal }
        underlying?.makeKey()
    }

    private func foregroundScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

}

struct HomeSettingsRoot: View {
    let setup: SetupCoordinator
    let actions: LocationActionCoordinator
    let favoriteImport: FavoriteImportCoordinator
    let favorites: FavoriteLocationStore
    let session: SpoofSession
    let pageID: UUID
    let isPresented: () -> Bool
    let onClose: () -> Void

    static func make(setup: SetupCoordinator, box: MapHomeSheetBox) -> HomeSettingsRoot? {
        guard let actions = box.actions, let favoriteImport = box.favoriteImport,
              let favorites = box.favorites, let session = box.session else { return nil }
        return HomeSettingsRoot(
            setup: setup,
            actions: actions,
            favoriteImport: favoriteImport,
            favorites: favorites,
            session: session,
            pageID: box.settingsPageID,
            isPresented: { [weak box] in box?.settingsOnScreen == true },
            onClose: { [weak box] in box?.dismissSettings() }
        )
    }

    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()
            NavigationView {
                SettingsView(
                    setup: setup,
                    actions: actions,
                    favoriteImport: favoriteImport,
                    isSettingsPresented: isPresented,
                    onClose: onClose,
                    favoritePageID: pageID,
                    favorites: favorites,
                    session: session
                )
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
    }
}

private struct HomeSettingsChrome: View {
    let onClose: () -> Void

    var body: some View {
        NavigationView {
            Color(UIColor.systemGroupedBackground)
                .ignoresSafeArea()
                .navigationTitle("设置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成", action: onClose)
                    }
                }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
