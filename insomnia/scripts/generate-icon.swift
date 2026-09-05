#!/usr/bin/swift
import Foundation

// Run from any directory: swift insomnia/scripts/generate-icon.swift
// Uses the app's CupMark shapes directly; only Xcode's Swift tools and iconutil
// are needed. No application or window is launched.
let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("insomnia-icon-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "InsomniaIcon", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(executable) failed"])
    }
}

let source = temporary.appendingPathComponent("main.swift")
try #"""
import AppKit
import SwiftUI

// Use the filled running-state artwork, with its original 24-unit geometry.
// Center its visible bounds rather than its asymmetric design grid.
@MainActor
func render(pixels: Int, to destination: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(red: 0.12, green: 0.14, blue: 0.19, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 80, y: 80, width: 864, height: 864),
                           cornerWidth: 194, cornerHeight: 194, transform: nil))
    context.fillPath()
    let markSize: CGFloat = 720
    let rect = CGRect(x: 159.5, y: 77, width: markSize, height: markSize)
    let cream = CGColor(red: 0.97, green: 0.95, blue: 0.90, alpha: 1)
    context.setFillColor(cream)
    context.addPath(CupMarkBody().path(in: rect).cgPath)
    context.fillPath()
    context.setStrokeColor(cream)
    context.setLineWidth(CupMark.lineWidth(for: markSize))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(CupMark().path(in: rect).cgPath)
    context.strokePath()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: destination)
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(pixels: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
"""#.write(to: source, atomically: true, encoding: .utf8)

let renderer = temporary.appendingPathComponent("render-icon")
let ui = package.appendingPathComponent("Sources/Insomnia/UI")
try run("/usr/bin/swiftc", ["-swift-version", "6", source.path,
    ui.appendingPathComponent("CupMark.swift").path, ui.appendingPathComponent("Motion.swift").path,
    "-o", renderer.path])
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try run(renderer.path, [iconset.path])
let output = package.appendingPathComponent("Resources/AppIcon.icns")
try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output.path])
print("Generated \(output.path)")
