import AppKit
import SwiftUI

@MainActor
final class IncomingCallWindowController {
    static let shared = IncomingCallWindowController()

    private var panel: NSPanel?

    private init() {}

    func show(
        number: String?,
        canAnswer: Bool,
        onAnswer: @escaping () -> Void,
        onReject: @escaping () -> Void
    ) {
        let rootView = IncomingCallOverlayView(
            number: number ?? "未知号码",
            canAnswer: canAnswer,
            onAnswer: { [weak self] in
                self?.dismiss()
                onAnswer()
            },
            onReject: { [weak self] in
                self?.dismiss()
                onReject()
            }
        )

        let hostingController = NSHostingController(rootView: rootView)
        let contentSize = NSSize(width: 392, height: 178)
        let panel: NSPanel
        if let existing = self.panel {
            existing.contentViewController = hostingController
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .transient,
                .ignoresCycle
            ]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.animationBehavior = .utilityWindow
            panel.contentViewController = hostingController
            self.panel = panel
        }

        panel.setContentSize(contentSize)
        position(panel)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - frame.width - 22,
            y: visibleFrame.maxY - frame.height - 22
        ))
    }
}

private struct IncomingCallOverlayView: View {
    let number: String
    let canAnswer: Bool
    let onAnswer: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.16))
                        .frame(width: 46, height: 46)
                    Image(systemName: "phone.arrow.down.left.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.green)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("蜂窝来电")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(number)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 12)

                Image(systemName: "waveform")
                    .font(.title2)
                    .symbolEffect(.variableColor.iterative)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 12) {
                Button(role: .destructive, action: onReject) {
                    Label("拒接", systemImage: "phone.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .adaptiveGlassButton()
                .tint(.red)

                Button(action: onAnswer) {
                    Label("接听", systemImage: "phone.fill")
                        .frame(maxWidth: .infinity)
                }
                .adaptiveGlassButton(.prominent)
                .tint(.green)
                .disabled(!canAnswer)
                .help(canAnswer ? "接听蜂窝来电" : "USB 语音通道尚未就绪")
            }
            .controlSize(.large)
        }
        .frame(width: 340)
        .adaptiveGlassSurface(
            cornerRadius: 24,
            padding: 18,
            tint: Color.green.opacity(0.08),
            isInteractive: true
        )
        .padding(10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("蜂窝来电，\(number)")
    }
}
