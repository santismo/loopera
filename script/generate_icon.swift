import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = root.appendingPathComponent("build/Loopera.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let font = NSFont.systemFont(ofSize: size * 0.72)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .paragraphStyle: paragraph
    ]
    let emoji = "🎥" as NSString
    let textSize = emoji.size(withAttributes: attributes)
    let rect = NSRect(
        x: 0,
        y: (size - textSize.height) / 2 - size * 0.03,
        width: size,
        height: textSize.height
    )
    emoji.draw(in: rect, withAttributes: attributes)
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "LooperaIcon", code: 1)
    }
    try png.write(to: iconset.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c", "icns",
    iconset.path,
    "-o", resources.appendingPathComponent("AppIcon.icns").path
]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    throw NSError(domain: "LooperaIcon", code: Int(process.terminationStatus))
}
