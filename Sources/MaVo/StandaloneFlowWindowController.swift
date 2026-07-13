import AppKit
import SwiftUI

@MainActor
final class StandaloneFlowWindowController: NSObject, NSWindowDelegate {
    static let shared = StandaloneFlowWindowController()

    private enum Flow: Hashable {
        case smsComposer
        case atConsole
        case settings
        case messageDetail
    }

    private weak var appState: AppState?
    private var windows: [Flow: NSWindow] = [:]

    private override init() {
        super.init()
    }

    func configure(appState: AppState) {
        self.appState = appState
    }

    func showSMSComposer(to destination: String = "") {
        show(
            .smsComposer,
            title: destination.isEmpty ? "新短信" : "回复短信",
            size: NSSize(width: 520, height: 440),
            content: SMSComposerView(destination: destination) { [weak self] in
                self?.close(.smsComposer)
            }
        )
    }

    func showATConsole() {
        show(
            .atConsole,
            title: "AT 控制台",
            size: NSSize(width: 700, height: 560),
            content: ATConsoleView { [weak self] in self?.close(.atConsole) }
        )
    }

    func showSettings() {
        show(
            .settings,
            title: "MaVo 设置",
            size: NSSize(width: 500, height: 650),
            content: MaVoSettingsView { [weak self] in self?.close(.settings) }
        )
    }

    func showMessageDetail(_ message: SMSMessage) {
        show(
            .messageDetail,
            title: "短信详情",
            size: NSSize(width: 500, height: 500),
            content: SMSDetailView(message: message) { [weak self] in self?.close(.messageDetail) }
        )
    }

    private func show<Content: View>(
        _ flow: Flow,
        title: String,
        size: NSSize,
        content: Content
    ) {
        guard let appState else { return }
        let rootView = AnyView(content.environmentObject(appState))
        let hostingController = NSHostingController(rootView: rootView)

        let window: NSWindow
        if let existing = windows[flow] {
            window = existing
            window.contentViewController = hostingController
        } else {
            window = NSWindow(contentViewController: hostingController)
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Keep content interactions (notably SMS text selection) from
            // turning into a window drag and triggering macOS edge tiling.
            window.isMovableByWindowBackground = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            windows[flow] = window
        }

        window.title = title
        window.setContentSize(size)
        window.center()
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func close(_ flow: Flow) {
        windows[flow]?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              let flow = windows.first(where: { $0.value === closingWindow })?.key else {
            return
        }
        windows.removeValue(forKey: flow)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.windows.values.contains(where: \.isVisible),
                  !MainWindowController.shared.isVisible else {
                return
            }
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}
