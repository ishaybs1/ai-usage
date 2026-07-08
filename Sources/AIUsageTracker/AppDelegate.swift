import SwiftUI
import AppKit
import Combine

/// Owns the app shell using AppKit directly: an `NSStatusItem` for the menu-bar 🧠 (reliable
/// in no-Dock/accessory apps, unlike SwiftUI's `MenuBarExtra`), an `NSPopover` for the panel,
/// and on-demand `NSWindow`s for the dashboard / coach.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = UsageViewModel()
    private(set) lazy var coach = CoachViewModel(usage: viewModel)

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var dashboardWindow: NSWindow?
    private var coachWindow: NSWindow?
    private var settingsWindow: NSWindow?
    /// Periodic background refresh so the menu-bar total stays current without opening the popover.
    private var refreshTimer: Timer?
    private static let refreshInterval: TimeInterval = 15 * 60   // 15 minutes

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        // macOS persists the user's ⌘-dragged position per autosaveName, so once placed it
        // stays put across relaunches (apps can't set the position directly).
        statusItem.autosaveName = "AIUsageTracker.status"
        if let button = statusItem.button {
            // Emoji + text label (always renders in color, unmistakable) instead of a
            // monochrome SF Symbol that blends into the system icons.
            button.title = "🧠"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                viewModel: viewModel,
                onOpenDashboard: { [weak self] in self?.showDashboard() },
                onOpenCoach: { [weak self] in self?.showCoach() },
                onOpenSettings: { [weak self] in self?.showSettings() }
            )
        )

        // Keep the menu-bar title/icon in sync with the view model.
        viewModel.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusButton() } }
            .store(in: &cancellables)
        updateStatusButton()

        startRefreshTimer()
    }

    /// Re-scan local sessions every 15 minutes so the total stays fresh in the background.
    private func startRefreshTimer() {
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.viewModel.load(force: true) }
        }
        // .common so it keeps firing while the popover/menus are tracking a run-loop mode.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let prefix: String
        switch viewModel.budgetStatus {
        case .over:    prefix = "🔴"   // over budget
        case .warning: prefix = "🟠"   // trending over
        case .under, .none: prefix = "🧠"
        }
        button.image = nil
        // Compact: emoji only (no cost text) — smallest possible footprint so the item is
        // far less likely to be pushed under the notch on a crowded menu bar. The color of the
        // emoji still encodes budget status; the full amount lives in the popover.
        button.title = prefix
        button.toolTip = "AI usage today: \(viewModel.menuBarTitle)"
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            Task { await viewModel.load() }   // refresh to the newest available data on every open
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: Windows

    func showDashboard() {
        if dashboardWindow == nil {
            dashboardWindow = makeWindow(title: "AI Usage Dashboard",
                                         view: DashboardView(viewModel: viewModel),
                                         width: 1000, height: 640)
        }
        Task { await viewModel.load() }   // refresh to the newest available data on every open
        present(dashboardWindow!)
    }

    func showCoach() {
        if coachWindow == nil {
            coachWindow = makeWindow(title: "Cost Coach",
                                     view: CoachView(coach: coach, usage: viewModel),
                                     width: 480, height: 640)
        }
        Task { await viewModel.load() }   // refresh to the newest available data on every open
        present(coachWindow!)
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "AI Usage Settings",
                                        view: SettingsView(viewModel: viewModel),
                                        width: 420, height: 480)
        }
        present(settingsWindow!)
    }

    private func makeWindow<V: View>(title: String, view: V, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        popover.performClose(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
