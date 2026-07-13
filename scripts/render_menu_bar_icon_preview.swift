import AppKit
import Foundation

enum PreviewState {
    case disconnected
    case connected
    case enabled
    case error

    var width: CGFloat {
        switch self {
        case .disconnected: return 20
        case .connected: return 17
        case .enabled: return 26
        case .error: return 23
        }
    }

    var title: String {
        switch self {
        case .disconnected: return "未插入模块"
        case .connected: return "已连接"
        case .enabled: return "蜂窝联网开启"
        case .error: return "连接异常"
        }
    }
}

func aspectFitRect(for sourceSize: NSSize, in bounds: NSRect) -> NSRect {
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

func renderTemplate(_ state: PreviewState) -> NSImage {
    let image = NSImage(size: NSSize(width: state.width, height: 18), flipped: false) { _ in
        if state == .disconnected {
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            let symbol = NSImage(
                systemSymbolName: "antenna.radiowaves.left.and.right.slash",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(configuration)
                ?? NSImage(
                    systemSymbolName: "antenna.radiowaves.left.and.right",
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(configuration)
            if let symbol {
                symbol.draw(
                    in: aspectFitRect(
                        for: symbol.size,
                        in: NSRect(x: 0, y: 0, width: 20, height: 18)
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }
            return true
        }

        for level in 1...4 {
            let isLit = state != .error && level <= 3
            NSColor(calibratedWhite: 0, alpha: isLit ? 1 : 0.24).setFill()
            let rect = NSRect(
                x: CGFloat(level - 1) * 4,
                y: 2,
                width: 3,
                height: CGFloat(2 + level * 3)
            )
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }

        if state == .enabled,
           let symbol = NSImage(
               systemSymbolName: "arrow.up.arrow.down.circle.fill",
               accessibilityDescription: nil
           )?.withSymbolConfiguration(
               NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
           ) {
            symbol.draw(
                in: NSRect(x: 16.5, y: 8.5, width: 9.5, height: 9.5),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        } else if state == .error {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            "!".draw(in: NSRect(x: 16, y: 9.5, width: 6, height: 8), withAttributes: attributes)
        }
        return true
    }
    image.isTemplate = true
    return image
}

func whiteTemplate(_ source: NSImage) -> NSImage {
    let output = NSImage(size: source.size)
    output.lockFocus()
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: source.size)).fill()
    source.draw(
        in: NSRect(origin: .zero, size: source.size),
        from: .zero,
        operation: .destinationIn,
        fraction: 1
    )
    output.unlockFocus()
    return output
}

let outputPath = CommandLine.arguments.dropFirst().first
    ?? "output/menu-bar-icon-preview.png"
let canvasSize = NSSize(width: 960, height: 240)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Unable to create preview bitmap")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

let states: [PreviewState] = [.disconnected, .connected, .enabled, .error]
for (index, state) in states.enumerated() {
    let card = NSRect(x: 18 + CGFloat(index) * 236, y: 18, width: 216, height: 204)
    NSColor(calibratedRed: 0.09, green: 0.14, blue: 0.27, alpha: 1).setFill()
    NSBezierPath(roundedRect: card, xRadius: 24, yRadius: 24).fill()

    let source = whiteTemplate(renderTemplate(state))
    let scale: CGFloat = 6
    let enlarged = NSSize(width: source.size.width * scale, height: source.size.height * scale)
    source.draw(
        in: NSRect(
            x: card.midX - enlarged.width / 2,
            y: card.midY - enlarged.height / 2 + 14,
            width: enlarged.width,
            height: enlarged.height
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    source.draw(
        in: NSRect(
            x: card.maxX - source.size.width - 12,
            y: card.maxY - source.size.height - 10,
            width: source.size.width,
            height: source.size.height
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    state.title.draw(
        in: NSRect(x: card.minX + 8, y: card.minY + 17, width: card.width - 16, height: 24),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
    )
}
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode preview")
}
let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try data.write(to: outputURL, options: .atomic)
print(outputURL.path)
