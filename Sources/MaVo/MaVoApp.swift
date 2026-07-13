import AppKit
import SwiftUI

@main
struct MaVoApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate
    @StateObject private var appState: AppState

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        state.start()
    }

    var body: some Scene {
        MenuBarExtra(isInserted: menuBarInsertionBinding) {
            MenuContentView()
                .environmentObject(appState)
        } label: {
            MenuBarLabel()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MaVoSettingsView()
                .environmentObject(appState)
        }
    }

    private var menuBarInsertionBinding: Binding<Bool> {
        Binding(
            get: { appState.isMenuBarExtraInserted },
            set: { appState.setMenuBarExtraInsertedFromSystem($0) }
        )
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 3) {
            if let callIconName {
                Image(systemName: callIconName)
            } else {
                MenuBarSignalIcon(
                    bars: appState.modem.signalBars,
                    state: appState.modem.state,
                    dataEnabled: appState.network.isEnabled
                )
            }
            if appState.unreadCount > 0 {
                Text("\(min(appState.unreadCount, 99))")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .help(helpText)
    }

    private var callIconName: String? {
        switch appState.call.phase {
        case .incoming:
            return "phone.arrow.down.left.fill"
        case .dialing, .alerting:
            return "phone.arrow.up.right.fill"
        case .active, .ending, .recovering:
            return "phone.fill"
        case .unavailable, .idle, .error:
            return nil
        }
    }

    private var helpText: String {
        if appState.call.phase == .incoming {
            return "来电：\(appState.call.number ?? "未知号码")"
        }
        if appState.call.hasCall {
            return "蜂窝通话：\(appState.call.number ?? "未知号码")"
        }
        if !appState.modem.isConnected { return "MaVo：模块未插入" }
        let dataStatus = appState.network.isEnabled ? "蜂窝联网已开启" : "蜂窝联网未开启"
        if let signal = appState.modem.signalDBm {
            return "\(appState.modem.operatorName ?? "蜂窝网络") · \(signal) dBm · \(dataStatus)"
        }
        return "MaVo：模块已连接 · \(dataStatus)"
    }
}

private struct MenuBarSignalIcon: View {
    let bars: Int
    let state: ModemConnectionState
    let dataEnabled: Bool

    var body: some View {
        Image(nsImage: templateImage)
            .renderingMode(.template)
            .frame(width: iconWidth, height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func isLit(_ level: Int) -> Bool {
        state == .connected && level <= min(max(bars, 0), 4)
    }

    private var templateImage: NSImage {
        let size = NSSize(width: iconWidth, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            if state == .disconnected {
                drawDisconnectedIcon()
            } else {
                for level in 1...4 {
                    let alpha: CGFloat = isLit(level) ? 1 : 0.24
                    NSColor(calibratedWhite: 0, alpha: alpha).setFill()

                    let height = CGFloat(2 + level * 3)
                    let rect = NSRect(
                        x: CGFloat(level - 1) * 4,
                        y: 2,
                        width: 3,
                        height: height
                    )
                    NSBezierPath(
                        roundedRect: rect,
                        xRadius: 1.5,
                        yRadius: 1.5
                    ).fill()
                }

                drawBadge()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private var iconWidth: CGFloat {
        switch state {
        case .connected:
            return dataEnabled ? 26 : 17
        case .connecting, .error:
            return 23
        case .disconnected:
            return 20
        }
    }

    private func drawBadge() {
        switch state {
        case .connected where dataEnabled:
            drawDataBadge()
        case .connecting:
            drawBadgeText("…", size: 7.5)
        case .error:
            drawBadgeText("!", size: 8)
        case .disconnected:
            break
        case .connected:
            break
        }
    }

    private func drawDisconnectedIcon() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let symbol = NSImage(
            systemSymbolName: "antenna.radiowaves.left.and.right.slash",
            accessibilityDescription: "蜂窝模块未插入"
        )?.withSymbolConfiguration(configuration)
            ?? NSImage(
                systemSymbolName: "antenna.radiowaves.left.and.right",
                accessibilityDescription: "蜂窝模块未插入"
            )?.withSymbolConfiguration(configuration)

        guard let symbol else { return }
        let bounds = NSRect(x: 0, y: 0, width: 20, height: 18)
        symbol.draw(
            in: aspectFitRect(for: symbol.size, in: bounds),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    private func aspectFitRect(for sourceSize: NSSize, in bounds: NSRect) -> NSRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return bounds }
        let scale = min(
            bounds.width / sourceSize.width,
            bounds.height / sourceSize.height
        )
        let size = NSSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func drawDataBadge() {
        guard let symbol = NSImage(
            systemSymbolName: "arrow.up.arrow.down.circle.fill",
            accessibilityDescription: "蜂窝联网已开启"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        ) else {
            drawBadgeText("↕", size: 9)
            return
        }
        symbol.draw(
            in: NSRect(x: 16.5, y: 8.5, width: 9.5, height: 9.5),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    private func drawBadgeText(_ text: String, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        text.draw(
            in: NSRect(x: 16, y: 9.5, width: 6, height: 8),
            withAttributes: attributes
        )
    }

    private var accessibilityLabel: String {
        switch state {
        case .connected:
            let dataStatus = dataEnabled ? "，蜂窝联网已开启" : ""
            return "蜂窝信号 \(bars) 格\(dataStatus)"
        case .connecting:
            return "正在连接蜂窝模块"
        case .error:
            return "蜂窝模块异常"
        case .disconnected:
            return "蜂窝模块未插入"
        }
    }
}
