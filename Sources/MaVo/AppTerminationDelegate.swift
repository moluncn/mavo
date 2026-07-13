import AppKit
import Foundation

final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppTerminationCoordinator.shared.beginTermination(of: sender)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            MainWindowController.shared.handleApplicationReopen()
        }
        return true
    }
}

final class AppTerminationCoordinator {
    static let shared = AppTerminationCoordinator()

    var cleanup: ((@escaping (Bool) -> Void) -> Void)?
    private var terminationPending = false

    private init() {}

    func beginTermination(of application: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard let cleanup else { return .terminateNow }
        terminationPending = true
        var replied = false
        let reply: (Bool) -> Void = { shouldTerminate in
            DispatchQueue.main.async {
                guard !replied else { return }
                replied = true
                self.terminationPending = false
                application.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        }
        cleanup(reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { reply(false) }
        return .terminateLater
    }
}
