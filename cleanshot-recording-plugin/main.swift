import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO

let schemaVersion = 1
let activityID = "com.benjamin.cleanshot-recording"
let pluginTitle = "CleanShot Recording"
let pollInterval: TimeInterval = 0.4
let updateInterval: TimeInterval = 1.0


let previewSeconds: TimeInterval = 10
let previewCloseGrace: TimeInterval = 1.5
let finishSettleTime: TimeInterval = 0.5
let finishTimeout: TimeInterval = 8.0
let inlineImageLimit = 48_000
let savingLabel = "Saving Recording…"
// The host renders lake content itself and rate-limits plugin commands, so the
// spin is time-based: the angle comes from the clock, and the frame rate starts
// at the safe floor and climbs until the host stops answering every frame.
let spinnerStepsPerRevolution = 120
let spinnerRevolutionsPerSecond: Double = 0.9
// The host answers "Update rate limit exceeded" at roughly twenty lake commands
// a second and then holds the plugin off for about a second, which is what made
// the swap look frozen. Sixteen keeps the spin under the cap with room for the
// exit patch and the preview card, so neither is ever refused.
let savingFramesPerSecond: Double = 16

// Messages that arrived while sendWithRepair() was waiting for a response.
var pendingMessages: [[String: Any]] = []
let videoExtensions = [".mov", ".mp4", ".m4v", ".mkv", ".avi", ".ts"]
let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DynamicLake/CleanShotPlugin.log")

func log(_ message: String) {
    do {
        let fm = FileManager.default
        try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
           (attrs[.size] as? NSNumber)?.intValue ?? 0 > 1_000_000 {
            let backup = logURL.deletingPathExtension().appendingPathExtension("log.1")
            try? fm.removeItem(at: backup)
            try fm.moveItem(at: logURL, to: backup)
        }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let line = "\(formatter.string(from: Date())) [\(getpid())] \(message)\n"
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
    } catch { }
}

// The Accessibility stop press runs off the polling loop, which hands the
// result back through this box.
final class ResultBox {
    private let lock = NSLock()
    private var value: String?

    func set(_ newValue: String) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func take() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value = nil
        return current
    }
}

final class Client {
    let socketPath: String
    private var fd: Int32 = -1
    private var buffer = Data()
    private var expectedLength: Int?

    init() {
        socketPath = ProcessInfo.processInfo.environment["DYNAMICLAKE_JSON_SOCKET"] ?? "/tmp/dynamiclake-json-\(getuid()).sock"
    }

    func connect() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTCONN) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.baseAddress!.copyMemory(from: pathBytes, byteCount: pathBytes.count)
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOTCONN) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    func send(_ message: [String: Any]) throws {
        guard fd >= 0 else { throw POSIXError(.ENOTCONN) }
        let payload = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        try frame.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if n > 0 { sent += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // The socket is non-blocking and the host is not draining
                    // fast enough for a large frame (the inline stop-ring PNG):
                    // wait for room instead of failing the whole request.
                    var handle = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = Darwin.poll(&handle, 1, 5_000)
                    if ready > 0 { continue }
                    if ready == 0 { throw POSIXError(.ETIMEDOUT) }
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func readAvailable() throws -> [[String: Any]] {
        guard fd >= 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = Darwin.recv(fd, &bytes, bytes.count, 0)
            if n > 0 { buffer.append(bytes, count: n); continue }
            if n == 0 { throw POSIXError(.ECONNRESET) }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var messages = [[String: Any]]()
        while true {
            if expectedLength == nil {
                guard buffer.count >= 4 else { break }
                let length = buffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                buffer.removeFirst(4)
                expectedLength = Int(length)
            }
            guard let expectedLength, buffer.count >= expectedLength else { break }
            let data = buffer.prefix(expectedLength)
            buffer.removeFirst(expectedLength)
            self.expectedLength = nil
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { messages.append(object) }
        }
        return messages
    }
}

func run(_ arguments: [String], timeout: TimeInterval = 2) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    // Drain stdout while the child runs. Waiting until exit can deadlock once
    // lsof fills the pipe's kernel buffer (typically 64 KB).
    let reader = output.fileHandleForReading
    let writer = output.fileHandleForWriting
    let readerFinished = DispatchGroup()
    var capturedOutput = Data()
    let outputLock = NSLock()
    readerFinished.enter()
    DispatchQueue.global(qos: .utility).async {
        let data = reader.readDataToEndOfFile()
        outputLock.lock()
        capturedOutput = data
        outputLock.unlock()
        readerFinished.leave()
    }
    do {
        try process.run()
    } catch {
        try? writer.close()
        readerFinished.wait()
        try? reader.close()
        return ""
    }
    try? writer.close()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning { process.terminate(); process.waitUntilExit() }
    readerFinished.wait()
    try? reader.close()
    outputLock.lock()
    defer { outputLock.unlock() }
    return String(data: capturedOutput, encoding: .utf8) ?? ""
}

func cleanShotPIDs() -> [String] { run(["pgrep", "-x", "CleanShot X"]).split(separator: "\n").map { String($0) } }

func looksLikeRecordingFile(_ path: String) -> Bool {
    let lower = path.lowercased()
    return videoExtensions.contains { lower.hasSuffix($0) } || (lower.contains("cleanshot") && lower.contains("/media/"))
}

func recordingFile(for pids: [String]) -> String? {
    guard !pids.isEmpty else { return nil }
    let output = run(["lsof", "-nP", "-F", "pfan", "-p", pids.joined(separator: ",")])
    var access: String?
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
        let tag = line.first!
        let value = String(line.dropFirst())
        if tag == "f" { access = nil }
        else if tag == "a" { access = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        else if tag == "n", ["w", "u", "wu"].contains(access ?? ""), looksLikeRecordingFile(value) { return value }
    }
    return nil
}

final class RecordingDetector {
    private let pidRefreshInterval: TimeInterval = 1.0
    private let inactiveScanInterval: TimeInterval = 1.0
    private var pids = [String]()
    private var lastPIDRefresh = Date.distantPast
    private var lastScan = Date.distantPast
    private var lastResult: (Bool, String, String?) = (false, "idle", nil)

    private func pidIsRunning(_ value: String) -> Bool {
        guard let pid = pid_t(value) else { return false }
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    func detect() -> (Bool, String, String?) {
        let now = Date()
        if now.timeIntervalSince(lastPIDRefresh) >= pidRefreshInterval || !pids.allSatisfy(pidIsRunning) {
            pids = cleanShotPIDs()
            lastPIDRefresh = now
        }

        // While idle, avoid repeatedly spawning lsof. During a recording we
        // keep the original 0.4-second cadence so dismissal remains prompt.
        let scanInterval: TimeInterval = lastResult.0 ? pollInterval : inactiveScanInterval
        guard now.timeIntervalSince(lastScan) >= scanInterval else { return lastResult }
        lastScan = now
        if let path = recordingFile(for: pids) {
            lastResult = (true, "CleanShot writing \(path)", path)
        } else {
            lastResult = (false, "idle", nil)
        }
        return lastResult
    }
}

func axAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
}

func axString(_ element: AXUIElement, _ attribute: CFString) -> String {
    axAttribute(element, attribute) as? String ?? ""
}

func axChildren(_ element: AXUIElement, _ attribute: CFString = kAXChildrenAttribute as CFString) -> [AXUIElement] {
    axAttribute(element, attribute) as? [AXUIElement] ?? []
}

let stopTitles = ["Stop Recording", "Stop Screen Recording"]
let timerRegex = try! NSRegularExpression(pattern: "^\\d{1,2}:\\d{2}(:\\d{2})?$")

func stopFromMenu(_ app: AXUIElement) -> String? {
    guard let extrasValue = axAttribute(app, "AXExtrasMenuBar" as CFString) else { return nil }
    let extras = extrasValue as! AXUIElement
    for barItem in axChildren(extras) {
        for menu in axChildren(barItem) {
            for item in axChildren(menu) where stopTitles.contains(axString(item, kAXTitleAttribute as CFString)) {
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? "pressed" : "press failed"
            }
        }
    }
    return nil
}

func stopFromToolbar(_ app: AXUIElement) -> String? {
    for window in axChildren(app, kAXWindowsAttribute as CFString) {
        let children = axChildren(window)
        let buttons = children.filter { axString($0, kAXRoleAttribute as CFString) == "AXButton" }
        let hasTimer = children.contains {
            axString($0, kAXRoleAttribute as CFString) == "AXStaticText" && timerRegex.firstMatch(in: axString($0, kAXValueAttribute as CFString).trimmingCharacters(in: .whitespaces), range: NSRange(location: 0, length: axString($0, kAXValueAttribute as CFString).trimmingCharacters(in: .whitespaces).utf16.count)) != nil
        }
        if hasTimer && (2...6).contains(buttons.count), let button = buttons.first {
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success ? "pressed" : "press failed"
        }
    }
    return nil
}

func stopRecording() -> String {
    guard AXIsProcessTrusted() else { return "untrusted" }
    let pids = cleanShotPIDs()
    guard !pids.isEmpty else { return "cleanshot not running" }
    var found = false
    for value in pids {
        guard let pid = pid_t(value) else { continue }
        let app = AXUIElementCreateApplication(pid)
        if let result = stopFromMenu(app) { return result }
        found = true
        if let result = stopFromToolbar(app) { return result }
    }
    return found ? "no stop control" : "no cleanshot window"
}

func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
func compactDot() -> [String: Any] {
    // Neither the compact live-activity slot nor a lake accepts a size on an
    // SF Symbol image, so use a text bullet: it is tintable, auto-centres, and
    // stays smaller than the 28 pt default image, like the iPhone indicator.
    ["type": "text", "id": "recording-dot", "text": "●", "tint": "red"]
}

// The compact notch slot only accepts a text component: it rejects size on
// images, weight on text, and a blank text. A text glyph is therefore the only
// dot the host will draw there, so it stays a plain bullet.
func timer(_ startedAt: Date) -> [String: Any] { ["type": "timer", "id": "recording-duration", "startDate": iso(startedAt), "endDate": iso(startedAt.addingTimeInterval(86_400)), "countsDown": false, "tint": "red"] }
func label(_ text: String, tint: String = "white", padding: Double = 0) -> [String: Any] {
    var label: [String: Any] = ["type": "text", "id": "recording-label", "text": text, "tint": tint]
    if padding != 0 { label["padding"] = ["leading": padding] }
    return label
}
func stopRingBase64() -> String {
    // CleanShot's own stop button is a white ring around a red rounded square.
    // A lake button always paints a filled disc behind its glyph, so draw the
    // control as an inline image instead and make the image tappable.
    // Render at 2x (80 px for a 40 pt control) in sRGB. An exact 2:1
    // downsample keeps the circle's edge smoothly antialiased. Rendering at 8x
    // snapped the edge to the pixel grid, which looked stair-stepped at 1x.
    // 2x also stays sharp if the lake is ever shown on a Retina display.
    let side = 80
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "" }
    let size = CGFloat(side)
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.setShouldAntialias(true)

    // Filled annulus rather than a stroked ellipse: a centred stroke left only
    // ~1.6 px of solid white at 1x, which read as a thin grey outline. Both
    // edges are fills now, and the geometry is sized so that at 40 pt the ring
    // and square land on whole-pixel boundaries: a fully solid 2 pt white band
    // instead of one white pixel with grey shoulders.
    let outerRadius = size * 0.5
    let innerRadius = outerRadius - size * 0.05
    let center = CGPoint(x: size / 2, y: size / 2)
    let ring = CGMutablePath()
    ring.addEllipse(in: CGRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2))
    ring.addEllipse(in: CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
    context.addPath(ring)
    context.setFillColor(CGColor(colorSpace: sRGB, components: [1, 1, 1, 1]) ?? CGColor(gray: 1, alpha: 1))
    context.fillPath(using: .evenOdd)

    // Square matches the reference: 16 pt inside a 40 pt ring.
    let squareWidth = size * 0.40
    let squareHeight = size * 0.40
    let radius = min(squareWidth, squareHeight) * 0.22
    let square = CGRect(x: (size - squareWidth) / 2, y: (size - squareHeight) / 2, width: squareWidth, height: squareHeight)
    context.addPath(CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil))
    // #FF4245 in sRGB converts to the same (254, 38, 78) display colour the
    // host uses for the "red" timer tint on this screen.
    context.setFillColor(CGColor(colorSpace: sRGB, components: [1.0, 66.0 / 255.0, 69.0 / 255.0, 1]) ?? CGColor(red: 1, green: 0.26, blue: 0.27, alpha: 1))
    context.fillPath()

    guard let image = context.makeImage() else { return "" }
    let png = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return "" }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return "" }
    return (png as Data).base64EncodedString()
}

let stopRingImageData = stopRingBase64()

// The iOS recording card turns its stop ring into a spinner while the file is
// saved: a white arc with a gap that steps around the red square, then a white
// progress ring. The lake has no native spinner, so the frames are rendered
// here and pushed as inline images.
var spinnerCache: [String: String] = [:]

func spinnerImageBase64(step: Int) -> String {
    let side = 80
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "" }
    let size = CGFloat(side)
    let center = CGPoint(x: size / 2, y: size / 2)
    let band = size * 0.05
    let radius = size * 0.5 - band / 2
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.setShouldAntialias(true)
    context.setLineWidth(band)
    context.setLineCap(.round)
    let white = CGColor(colorSpace: sRGB, components: [1, 1, 1, 1]) ?? CGColor(gray: 1, alpha: 1)

    // 280° arc with a gap; the gap travels one step per frame.
    let sweep = CGFloat.pi * 2 * (280.0 / 360.0)
    // Decreasing angle turns the arc clockwise on screen.
    let start = CGFloat.pi / 2 - CGFloat(step % spinnerStepsPerRevolution) * (CGFloat.pi * 2 / CGFloat(spinnerStepsPerRevolution))
    context.setStrokeColor(white)
    context.addArc(center: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
    context.strokePath()

    // The red square stays put while the ring moves, like the reference.
    let squareWidth = size * 0.40
    let cornerRadius = squareWidth * 0.22
    let square = CGRect(x: (size - squareWidth) / 2, y: (size - squareWidth) / 2, width: squareWidth, height: squareWidth)
    context.addPath(CGPath(roundedRect: square, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    context.setFillColor(CGColor(colorSpace: sRGB, components: [1.0, 66.0 / 255.0, 69.0 / 255.0, 1]) ?? CGColor(red: 1, green: 0.26, blue: 0.27, alpha: 1))
    context.fillPath()

    guard let image = context.makeImage() else { return "" }
    let png = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return "" }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return "" }
    return (png as Data).base64EncodedString()
}

func spinnerFrameBase64(step: Int) -> String {
    let index = ((step % spinnerStepsPerRevolution) + spinnerStepsPerRevolution) % spinnerStepsPerRevolution
    let key = "spin-\(index)"
    if let cached = spinnerCache[key] { return cached }
    let data = spinnerImageBase64(step: index)
    spinnerCache[key] = data
    return data
}

func spinnerView(step: Int, size: Int = 40) -> [String: Any] {
    // Reuse the stop image's component id so the spinner replaces the ring in
    // place: the lake keeps its layout and nothing animates in or out. The
    // different actionID makes presses during saving do nothing.
    ["type": "image", "id": "stop-recording", "source": "inlineData", "mimeType": "image/png", "base64Data": spinnerFrameBase64(step: step), "size": size, "actionID": "saving-spinner"]
}

func savingExitMessage() -> [String: Any] {
    // Dim the label but keep the ring at its size: shrinking it shrinks the lake
    // before the taller preview card grows it again, which read as a bounce.
    ["schemaVersion": schemaVersion, "requestID": requestID("collapse"), "type": "lakePatch", "components": [spinnerView(step: 0), label(savingLabel, tint: "gray", padding: 1)]]
}

func stopButton() -> [String: Any] {
    if !stopRingImageData.isEmpty {
        return ["type": "image", "id": "stop-recording", "source": "inlineData", "mimeType": "image/png", "base64Data": stopRingImageData, "actionID": "stop-recording", "size": 40]
    }
    return ["type": "button", "id": "stop-recording", "systemImage": "stop.fill", "tint": "red", "shape": "circle", "role": "destructive", "actionID": "stop-recording"]
}

func createMessage(_ startedAt: Date) -> [String: Any] {
    ["schemaVersion": schemaVersion, "requestID": "rec-\(Int(startedAt.timeIntervalSince1970))", "type": "create", "activityID": activityID, "title": pluginTitle, "priority": "high", "size": "small", "surfaces": ["compactLiveActivity": ["leftSlot": compactDot()], "extraLiveActivity": ["leftSlot": label("Screen Recording")]]]
}
func lakeMessage(_ startedAt: Date) -> [String: Any] {
    ["schemaVersion": schemaVersion, "requestID": requestID("lake"), "type": "lake", "lake": ["hideHeader": true, "content": [["type": "hstack", "alignment": "center", "spacing": 0, "children": [["type": "vstack", "alignment": "leading", "spacing": 0, "children": [["type": "hstack", "alignment": "center", "spacing": 2, "children": [compactDot(), timer(startedAt)]], label("Screen Recording", padding: 1)]], ["type": "spacer"], stopButton()]]]]]
}
func frozenDuration(_ seconds: TimeInterval) -> [String: Any] {
    // Replaces the ticking timer once saving starts: the duration is read from a
    // clock in the host, so the only way to stop it is to swap in a static text.
    let total = Int(max(0, seconds).rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    let text = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    return ["type": "text", "id": "recording-duration", "text": text, "tint": "red", "weight": "semibold"]
}

func savingLakeMessage(_ startedAt: Date, step: Int, elapsed: TimeInterval) -> [String: Any] {
    // Same geometry as the live card, so swapping the stop control for the
    // spinner never resizes the lake.
    return [
        "schemaVersion": schemaVersion,
        "requestID": requestID("saving"),
        "type": "lake",
        "lake": [
            "hideHeader": true,
            "content": [
                [
                    "type": "hstack", "alignment": "center", "spacing": 0,
                    "children": [
                        [
                            "type": "vstack", "alignment": "leading", "spacing": 0,
                            "children": [
                                ["type": "hstack", "alignment": "center", "spacing": 2, "children": [compactDot(), frozenDuration(elapsed)]],
                                label(savingLabel, padding: 1)
                            ]
                        ],
                        ["type": "spacer"],
                        spinnerView(step: step)
                    ]
                ]
            ]
        ]
    ]
}
func savingPatchMessage(step: Int) -> [String: Any] {
    // A patch replaces just the spinner component, so a frame costs a small
    // message and no lake-wide rebuild.
    ["schemaVersion": schemaVersion, "requestID": requestID("saving"), "type": "lakePatch", "components": [spinnerView(step: step)]]
}
func clearLakeMessage() -> [String: Any] { ["schemaVersion": schemaVersion, "requestID": "lake-clear-\(Int(Date().timeIntervalSince1970))", "type": "lake", "lake": ["hideHeader": true, "content": []]] }
func dismissMessage() -> [String: Any] { ["schemaVersion": schemaVersion, "requestID": "dismiss-\(Int(Date().timeIntervalSince1970))", "type": "dismiss", "activityID": activityID] }
func permissionMessage() -> [String: Any] { ["schemaVersion": schemaVersion, "requestID": "permission-\(Int(Date().timeIntervalSince1970))", "type": "requestPermission", "permission": "accessibility"] }

func requestID(_ prefix: String) -> String { "\(prefix)-\(Int(Date().timeIntervalSince1970 * 1000))" }

enum Phase { case idle, live, finishing, preview }

struct PreviewInfo {
    let path: String
    let name: String
    let folder: String
    let duration: Double
    let thumbnail: String?
}

// Building a preview reads media files and grabs a frame, which is far too
// slow for the polling loop; it runs on a background queue and hands the
// result back here once it is ready.
final class PreviewBox {
    private let lock = NSLock()
    private var ready = false
    private var value: PreviewInfo?

    func set(_ newValue: PreviewInfo?) {
        lock.lock()
        value = newValue
        ready = true
        lock.unlock()
    }

    func take() -> (Bool, PreviewInfo?) {
        lock.lock()
        defer { lock.unlock() }
        guard ready else { return (false, nil) }
        let current = value
        value = nil
        ready = false
        return (true, current)
    }
}

func fileSize(_ path: String) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
    return (attributes[.size] as? NSNumber)?.int64Value
}

func fileModificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

func durationText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "--:--" }
    let total = max(0, Int(seconds.rounded()))
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
    return String(format: "%02d:%02d", total / 60, total % 60)
}

func displayFolder(_ path: String) -> String {
    let parent = (path as NSString).deletingLastPathComponent
    // CleanShot's internal media folder is not a meaningful "save location".
    if parent.contains("/Application Support/CleanShot/") { return "CleanShot Media" }
    return (parent as NSString).abbreviatingWithTildeInPath
}

func videoDuration(_ path: String) -> Double? {
    // This is a short-lived command-line monitor, so the synchronous property
    // is simpler than bridging an async load back into the polling loop.
    let seconds = CMTimeGetSeconds(AVURLAsset(url: URL(fileURLWithPath: path)).duration)
    return seconds.isFinite && seconds > 0 ? seconds : nil
}

func thumbnailBase64(_ path: String, duration: Double) -> String? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 480)
    // A frame just after the start avoids the black fade most recordings open on.
    let seconds = max(0.1, min(duration > 0 ? duration * 0.1 : 0.5, 1.0))
    guard let frame = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil) else { return nil }

    // The lake renders square artwork, so crop the centre out of the video frame.
    let side = min(frame.width, frame.height)
    guard side > 0 else { return nil }
    let square = frame.cropping(to: CGRect(x: (frame.width - side) / 2, y: (frame.height - side) / 2, width: side, height: side)) ?? frame
    let output = 200
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: output, height: output, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(square, in: CGRect(x: 0, y: 0, width: output, height: output))
    guard let image = context.makeImage() else { return nil }

    // Decoded inline images must stay under 48 KB. Drop quality if needed.
    for quality in [0.62, 0.45, 0.3] {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        if data.count <= inlineImageLimit { return (data as Data).base64EncodedString() }
    }
    return nil
}

func cleanShotMediaRoot() -> String {
    NSHomeDirectory() + "/Library/Application Support/CleanShot/media"
}

// CleanShot keeps its own ordered list of finished captures here. It already
// points at the final .mp4 even when the temporary .mov disappeared.
func historyMediaVideo(since: Date) -> String? {
    let preferences = NSHomeDirectory() + "/Library/Preferences/pl.maketheweb.cleanshotx.plist"
    guard let data = FileManager.default.contents(atPath: preferences),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let history = plist["mediaHistory"] as? Data,
          let entries = try? JSONSerialization.jsonObject(with: history) as? [[String: Any]] else { return nil }
    var best: (path: String, date: Date)?
    for entry in entries {
        guard let value = entry["url"] as? String, let url = URL(string: value), url.isFileURL else { continue }
        let lower = url.path.lowercased()
        guard videoExtensions.contains(where: { lower.hasSuffix($0) }) else { continue }
        let date: Date
        if let created = entry["creationDate"] as? Double {
            date = Date(timeIntervalSinceReferenceDate: created)
        } else if let modified = fileModificationDate(url.path) {
            date = modified
        } else {
            continue
        }
        guard date >= since, (fileSize(url.path) ?? 0) > 4_096 else { continue }
        if best == nil || date > best!.date { best = (url.path, date) }
    }
    return best?.path
}

// CleanShot records to a temporary .mov inside its media folder and renames it
// to .mp4 after stopping, so the path captured from lsof can disappear.
func newestMediaVideo(since: Date) -> String? {
    let fm = FileManager.default
    let root = cleanShotMediaRoot()
    guard let folders = try? fm.contentsOfDirectory(atPath: root) else { return nil }
    var best: (path: String, date: Date)?
    for folder in folders {
        let directory = root + "/" + folder
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
        for name in names {
            let lower = name.lowercased()
            guard videoExtensions.contains(where: { lower.hasSuffix($0) }) else { continue }
            let path = directory + "/" + name
            guard let modified = fileModificationDate(path), modified >= since else { continue }
            guard (fileSize(path) ?? 0) > 4_096 else { continue }
            if best == nil || modified > best!.date { best = (path, modified) }
        }
    }
    return best?.path
}

func exportedRecording(matching duration: Double, since: Date, excluding: String) -> String? {
    let fm = FileManager.default
    let home = NSHomeDirectory()
    let folders = [home + "/Desktop", home + "/Downloads", home + "/Movies", home + "/Documents"]
    var best: (path: String, date: Date)?
    for folder in folders {
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
        for name in names {
            let lower = name.lowercased()
            guard videoExtensions.contains(where: { lower.hasSuffix($0) }) else { continue }
            let path = folder + "/" + name
            guard path != excluding else { continue }
            guard let modified = fileModificationDate(path), modified >= since.addingTimeInterval(-15) else { continue }
            guard (fileSize(path) ?? 0) > 4_096 else { continue }
            guard let candidate = videoDuration(path), abs(candidate - duration) <= 0.75 else { continue }
            if best == nil || modified > best!.date { best = (path, modified) }
        }
    }
    return best?.path
}

func makePreviewInfo(path: String, since: Date) -> PreviewInfo? {
    guard FileManager.default.fileExists(atPath: path), (fileSize(path) ?? 0) > 0 else { return nil }
    let duration = videoDuration(path) ?? 0
    let shownPath: String
    if duration > 0, let exported = exportedRecording(matching: duration, since: since, excluding: path) {
        shownPath = exported
    } else {
        shownPath = path
    }
    let shownDuration = (shownPath == path ? duration : videoDuration(shownPath)) ?? duration
    return PreviewInfo(
        path: shownPath,
        name: (shownPath as NSString).lastPathComponent,
        folder: displayFolder(shownPath),
        duration: shownDuration,
        thumbnail: thumbnailBase64(shownPath, duration: shownDuration)
    )
}

func previewDot() -> [String: Any] {
    // Same small text treatment as the live red dot, but signals "finished".
    ["type": "text", "id": "recording-dot", "text": "✓", "tint": "green"]
}

func actionImage(_ symbol: String, id: String, tint: String = "white", size: Int = 24, title: String) -> [String: Any] {
    // Images with an action are what the host renders reliably here; buttons
    // with a custom shape were accepted but left the old card on screen.
    ["type": "image", "id": id, "source": "sfSymbol", "systemImage": symbol, "tint": tint, "size": size, "actionID": id, "title": title]
}

// The lake has no alpha or transition API, so the card's entrance is drawn as a
// short run of patches — the path the spinner already proves the host renders.
// A burst of full lake updates is simply refused as rate limited.
// The entrance is a brightening, not a resize: changing component sizes makes
// the host re-lay out the card on every frame, which reads as judder no matter
// how many frames get through. Tint steps never move anything.
let previewRevealInterval = 0.12

struct RevealState {
    let thumbSize: Int
    let thumbRadius: Int
    let iconSize: Int
    let ink: String
}

func revealState(_ reveal: Double) -> RevealState {
    // Fixed geometry at every step; only the ink brightens.
    RevealState(thumbSize: 64, thumbRadius: 12, iconSize: 24, ink: reveal >= 1 ? "white" : "gray")
}

func previewThumbnail(_ info: PreviewInfo, _ state: RevealState) -> [String: Any] {
    if let data = info.thumbnail {
        return ["type": "image", "id": "preview-thumbnail", "source": "inlineData", "mimeType": "image/jpeg", "base64Data": data, "actionID": "preview-watch", "title": "Watch", "size": state.thumbSize, "cornerRadius": state.thumbRadius, "contentMode": "fill"]
    }
    return ["type": "image", "id": "preview-thumbnail", "source": "sfSymbol", "systemImage": "film", "tint": "gray", "actionID": "preview-watch", "title": "Watch", "size": state.thumbSize]
}

func previewName(_ info: PreviewInfo, _ state: RevealState) -> [String: Any] {
    ["type": "text", "id": "preview-name", "text": info.name, "tint": state.ink, "weight": "semibold"]
}

func previewActionImages(_ state: RevealState) -> [[String: Any]] {
    [
        actionImage("folder", id: "preview-reveal", tint: state.ink, size: state.iconSize, title: "Show in Finder"),
        actionImage("doc.on.doc", id: "preview-copy", tint: state.ink, size: state.iconSize, title: "Copy"),
        actionImage("trash", id: "preview-delete", tint: "red", size: state.iconSize, title: "Delete")
    ]
}

func previewContent(_ info: PreviewInfo, note: String?, reveal: Double = 1) -> [[String: Any]] {
    let state = revealState(reveal)
    let meta = note ?? "\(durationText(info.duration))  ·  \(info.folder)"
    let actions: [String: Any] = ["type": "hstack", "alignment": "center", "spacing": 20, "children": previewActionImages(state)]
    let details: [String: Any] = [
        "type": "vstack", "alignment": "leading", "spacing": 6, "children": [
            previewName(info, state),
            ["type": "text", "id": "preview-meta", "text": meta, "tint": note == nil ? "gray" : "green", "style": "compact"],
            actions
        ]
    ]
    return [["type": "hstack", "alignment": "center", "spacing": 14, "children": [previewThumbnail(info, state), details, ["type": "spacer"]]]]
}

func previewRevealMessage(_ info: PreviewInfo) -> [String: Any] {
    // Only the text and the action row change, so the patch stays small and
    // leaves the layout untouched.
    let state = revealState(1)
    var components: [[String: Any]] = [previewName(info, state)]
    components.append(contentsOf: previewActionImages(state))
    return ["schemaVersion": schemaVersion, "requestID": requestID("reveal"), "type": "lakePatch", "components": components]
}

func previewLakeMessage(_ info: PreviewInfo, note: String? = nil, reveal: Double = 1) -> [String: Any] {
    ["schemaVersion": schemaVersion, "requestID": requestID("preview"), "type": "lake", "lake": ["hideHeader": true, "content": previewContent(info, note: note, reveal: reveal)]]
}

func previewUpdateMessage(_ base: [String: Any]) -> [String: Any] {
    var update = base
    update["type"] = "update"
    update["requestID"] = requestID("preview-update")
    update["surfaces"] = ["compactLiveActivity": ["leftSlot": previewDot()], "extraLiveActivity": ["leftSlot": label("Recording Saved")]]
    return update
}

func liveUpdateMessage(_ base: [String: Any], title: String = "Screen Recording") -> [String: Any] {
    var update = base
    update["type"] = "update"
    update["requestID"] = requestID("update")
    update["surfaces"] = ["compactLiveActivity": ["leftSlot": compactDot()], "extraLiveActivity": ["leftSlot": label(title)]]
    return update
}

func stripField(_ message: inout [String: Any], path: String, field: String) -> Bool {
    let parts = path.split(separator: ".").filter { !$0.isEmpty && $0 != "$" }.map(String.init)
    func parse(_ part: String) -> (name: String, index: Int?) {
        guard let open = part.firstIndex(of: "["), part.hasSuffix("]"),
              let index = Int(part[part.index(after: open)..<part.index(before: part.endIndex)]) else {
            return (part, nil)
        }
        return (String(part[..<open]), index)
    }
    func remove(_ node: inout [String: Any], _ index: Int) -> Bool {
        if index == parts.count { return node.removeValue(forKey: field) != nil }
        let (name, arrayIndex) = parse(parts[index])
        if let arrayIndex {
            guard var children = node[name] as? [[String: Any]], children.indices.contains(arrayIndex) else { return false }
            var child = children[arrayIndex]
            let removed = remove(&child, index + 1)
            children[arrayIndex] = child
            node[name] = children
            return removed
        }
        guard var child = node[name] as? [String: Any] else { return false }
        let removed = remove(&child, index + 1)
        node[name] = child
        return removed
    }
    return remove(&message, 0)
}

func sendWithRepair(_ client: Client, _ original: [String: Any], _ name: String) -> Bool {
    var message = original
    let pattern = try! NSRegularExpression(pattern: "(?:Invalid|Unknown) field '([^']+)' at (\\$[^ ]*?)\\.?")
    for _ in 0..<10 {
        let requestID = message["requestID"] as? String
        do { try client.send(message) } catch { log("\(name) send failed: \(error)"); return false }
        let deadline = Date().addingTimeInterval(1.2)
        var stripped = false
        var answered = false
        while Date() < deadline {
            do {
                for reply in try client.readAvailable() {
                    guard let type = reply["type"] as? String else { continue }
                    // Actions and lake events can arrive while we wait for this
                    // command's response. Keep them for the main loop instead
                    // of dropping a click that lands mid-update.
                    guard type == "response" || type == "error" else {
                        pendingMessages.append(reply)
                        continue
                    }
                    guard reply["requestID"] as? String == nil || reply["requestID"] as? String == requestID else { continue }
                    answered = true
                    if reply["ok"] as? Bool == true { if name != "update" && name != "saving" { log("\(name) accepted") }; return true }
                    let error = String(describing: reply["error"] ?? "")
                    log("\(name) rejected: \(error)")
                    let range = NSRange(error.startIndex..., in: error)
                    guard let match = pattern.firstMatch(in: error, range: range), let fieldRange = Range(match.range(at: 1), in: error), let pathRange = Range(match.range(at: 2), in: error), stripField(&message, path: String(error[pathRange]), field: String(error[fieldRange])) else { return false }
                    stripped = true
                    break
                }
            } catch { log("\(name) host closed the socket"); return false }
            if stripped { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !answered { log("\(name) no reply from host"); return false }
        if !stripped { return false }
    }
    log("\(name) gave up")
    return false
}

func main() -> Int32 {
    let client = Client()
    do { try client.connect() } catch { log("connect failed: \(error)"); return 1 }
    log("connected socket=\(client.socketPath) pid=\(getpid())")
    log("accessibility trusted=\(AXIsProcessTrusted())")
    let detector = RecordingDetector()
    let stopResult = ResultBox()
    let previewBox = PreviewBox()
    var phase: Phase = .idle
    var published = false, lastReason = "idle", frame: [String: Any]?
    var startedAt = Date.distantPast, lastUpdate = Date.distantPast, lastStopAttempt = Date.distantPast
    var activePath: String?
    var finishStarted = Date.distantPast, lastSize: Int64 = -1, sizeChangedAt = Date.distantPast
    var preview: PreviewInfo?
    var previewDeadline = Date.distantPast
    var lakeOpen = false
    var saving = false
    var lastSpin = Date.distantPast
    var savingStarted = Date.distantPast
    var savingSent = 0, savingReplies = 0, savingRejected = 0
    var savingPatches = true
    var savingElapsed: TimeInterval = 0
    var lastActive = false
    var previewing = false
    var previewRetried = false
    var previewRetryAt: Date?
    var revealPending = false
    var revealStep = 0
    var revealNextAt = Date.distantPast
    var lastErrorLog = Date.distantPast
    var lastFinishCheck = Date.distantPast

    func spinnerStep(at elapsed: TimeInterval) -> Int {
        let steps = max(0, elapsed) * spinnerRevolutionsPerSecond * Double(spinnerStepsPerRevolution)
        return Int(steps) % spinnerStepsPerRevolution
    }

    func publishSavingFrame() {
        guard published else { return }
        let step = spinnerStep(at: Date().timeIntervalSince(savingStarted))
        // Patches keep each frame small; if the host ever rejects one, fall
        // back to full lake messages rather than freezing the spin.
        let message = savingPatches
            ? savingPatchMessage(step: step)
            : savingLakeMessage(startedAt, step: step, elapsed: savingElapsed)
        // Only the first frame waits for a reply; the rest stream to the host,
        // and their responses are counted so the frame rate can adapt.
        do {
            try client.send(message)
            savingSent += 1
        } catch {
            log("saving frame send failed: \(error)")
        }
    }

    func startSaving() {
        guard !saving else { return }
        saving = true
        savingPatches = true
        savingSent = 0
        savingReplies = 0
        savingRejected = 0
        savingStarted = Date()
        lastSpin = savingStarted
        // Freeze the elapsed time at the moment stop was pressed.
        savingElapsed = max(0, savingStarted.timeIntervalSince(startedAt))

        // Swap the stop ring and label in place, then return immediately.
        // Waiting for the host's reply here stalled the loop for up to a
        // second, which is the pause before the spin started.
        // A full card, not a patch: the timer component is replaced by a static
        // text, and a patch that changes a component's type is accepted but not
        // applied, so the clock kept running.
        let initial = savingLakeMessage(startedAt, step: 0, elapsed: savingElapsed)
        // Waited on purpose: if this card does not land, the ticking timer stays
        // on screen, and the spinner patches below would only redecorate it.
        _ = sendWithRepair(client, initial, "lake")
        savingSent += 1
        if let update = frame.map({ liveUpdateMessage($0, title: savingLabel) }) {
            do { try client.send(update) } catch { log("saving update send failed: \(error)") }
        }
        log("saving started")
    }

    func cancelSaving() {
        guard saving else { return }
        saving = false
        log("saving cancelled")
        guard published else { return }
        _ = sendWithRepair(client, lakeMessage(startedAt), "lake")
        if let update = frame.map({ liveUpdateMessage($0) }) {
            _ = sendWithRepair(client, update, "update")
        }
    }

    func dismissPreview() {
        _ = sendWithRepair(client, dismissMessage(), "dismiss")
        _ = sendWithRepair(client, clearLakeMessage(), "lake-clear")
        previewing = false
        revealPending = false
        revealStep = 0
        _ = previewBox.take()
        saving = false
        preview = nil
        previewRetryAt = nil
        previewDeadline = .distantPast
        published = false
        frame = nil
        phase = .idle
    }

    func collapseSaving() {
        guard saving else { return }
        // One dimming step, no resizing: the card keeps its footprint and only
        // the label fades before the preview replaces it.
        do { try client.send(savingExitMessage()) } catch { }
        // Beat: the spinner's last frames have just spent the host's update
        // budget, and the lake command that follows is refused first.
        Thread.sleep(forTimeInterval: 0.16)
    }

    func beginReveal() {
        revealStep = 0
        revealPending = true
        // Let the dim card register, then brighten it.
        revealNextAt = Date().addingTimeInterval(previewRevealInterval)
    }

    func showPreview(_ info: PreviewInfo) {
        if saving {
            log("saving frames sent=\(savingSent) replies=\(savingReplies) rejected=\(savingRejected) rate=\(Int(savingFramesPerSecond))")
        }
        preview = info
        previewRetried = false
        phase = .preview
        previewDeadline = Date().addingTimeInterval(previewSeconds)
        // Collapse the saving card, then stop its frames: the exit and the
        // preview's entrance read as one hand-off rather than a cut.
        collapseSaving()
        saving = false
        if let update = frame.map({ previewUpdateMessage($0) }) {
            do { try client.send(update) } catch { log("preview update send failed: \(error)") }
        }
        // Open the card small and dim, then grow it with patches in the loop.
        if sendWithRepair(client, previewLakeMessage(info, reveal: 0), "lake") {
            beginReveal()
        } else {
            log("preview refused; retrying")
            previewRetryAt = Date().addingTimeInterval(0.15)
        }
        log("preview \(info.path) duration=\(durationText(info.duration)) folder=\(info.folder) thumbnail=\(info.thumbnail != nil)")
    }

    func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "action":
            let actionID = message["actionID"] as? String ?? ""
            if actionID == "stop-recording" {
                let now = Date()
                guard now.timeIntervalSince(lastStopAttempt) >= 1 else { return }
                lastStopAttempt = now
                log("stop requested from lake button")
                startSaving()
                // The Accessibility press takes a few hundred milliseconds;
                // run it off the loop so the spinner keeps turning meanwhile.
                DispatchQueue.global(qos: .userInitiated).async { stopResult.set(stopRecording()) }
                return
            }
            guard phase == .preview, let info = preview else { return }
            switch actionID {
            case "preview-watch":
                log("preview watch \(info.path)")
                _ = run(["open", info.path])
                dismissPreview()
            case "preview-reveal":
                log("preview reveal \(info.path)")
                _ = run(["open", "-R", info.path])
                dismissPreview()
            case "preview-copy":
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                let copied = pasteboard.writeObjects([URL(fileURLWithPath: info.path) as NSURL])
                log("preview copy \(copied)")
                if copied {
                    _ = sendWithRepair(client, previewLakeMessage(info, note: "Copied to clipboard"), "lake")
                    previewDeadline = min(previewDeadline, Date().addingTimeInterval(2.5))
                }
            case "preview-delete":
                var resulting: NSURL?
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: info.path), resultingItemURL: &resulting)
                    log("preview delete \(info.path)")
                    dismissPreview()
                } catch {
                    log("preview delete failed: \(error)")
                }
            default:
                break
            }
        case "lakeOpened":
            lakeOpen = true
            if phase == .preview {
                previewDeadline = max(previewDeadline, Date().addingTimeInterval(6))
            }
        case "lakeClosed":
            lakeOpen = false
            if phase == .preview {
                previewDeadline = min(previewDeadline, Date().addingTimeInterval(previewCloseGrace))
            }
        case "response":
            if saving, let id = message["requestID"] as? String, id.hasPrefix("saving-") { savingReplies += 1 }
        case "error":
            // Spinner frames after the first are sent without waiting for a
            // reply, so surface any rejection the host sends for them once
            // instead of once per frame.
            if let id = message["requestID"] as? String, id.hasPrefix("saving-") {
                savingRejected += 1
                if savingRejected == 1 {
                    log("saving frame rejected: \(String(describing: message["error"] ?? ""))")
                    savingPatches = false
                }
            } else if let id = message["requestID"] as? String, id.hasPrefix("preview-"), !id.hasPrefix("preview-update-") {
                log("preview rejected: \(String(describing: message["error"] ?? ""))")
                // The card is sent without waiting for a reply, so retry once
                // through the repair path rather than leaving the spinner up.
                if !previewRetried, let info = preview {
                    previewRetried = true
                    _ = sendWithRepair(client, previewLakeMessage(info), "lake")
                }
            } else {
                // Some failures arrive without the request id, so they would
                // otherwise be dropped without a trace. Rate-limit refusals
                // arrive in bursts, so only the first per second is logged.
                let now = Date()
                if now.timeIntervalSince(lastErrorLog) >= 1 {
                    lastErrorLog = now
                    log("host error: \(String(describing: message["error"] ?? message))")
                }
            }
        default:
            break
        }
    }

    while true {
        do {
            while !pendingMessages.isEmpty { handle(pendingMessages.removeFirst()) }
            for message in try client.readAvailable() { handle(message) }
        } catch { log("host closed the socket"); return 0 }

        if let result = stopResult.take() {
            log("stop result: \(result)")
            if result == "untrusted" { _ = sendWithRepair(client, permissionMessage(), "permission") }
            // If CleanShot never saw the press the recording is still running,
            // so put the stop control back.
            if result != "pressed" { cancelSaving() }
        }

        let computed = previewBox.take()
        if computed.0 {
            previewing = false
            if phase == .finishing {
                if let info = computed.1 { showPreview(info) }
                else { log("preview unavailable"); dismissPreview() }
            }
        }

        let now = Date()
        // lsof blocks for a moment; skip it right after a stop so the spinner
        // keeps its frame rate while the file is closing.
        var active = false, reason = lastReason
        var path: String?
        if !saving || now.timeIntervalSince(savingStarted) >= 1.2 {
            let result = detector.detect()
            active = result.0
            reason = result.1
            path = result.2
            lastActive = active
        } else {
            active = lastActive
        }
        if active, let path { activePath = path }
        if reason != lastReason { log("state: \(reason) (active=\(active))"); lastReason = reason }

        if active {
            // A stop press left the file open for too long: the recording is
            // still going, so take the spinner away again.
            if saving && now.timeIntervalSince(savingStarted) >= 4 { cancelSaving() }
            if phase != .live {
                log("recording started; switching to live card")
                phase = .live
                startedAt = now
                lastUpdate = Date.distantPast
                saving = false
                previewing = false
                _ = previewBox.take()
                preview = nil
                previewDeadline = .distantPast
                if published {
                    if let update = frame.map({ liveUpdateMessage($0) }) { _ = sendWithRepair(client, update, "update") }
                    _ = sendWithRepair(client, lakeMessage(startedAt), "lake")
                }
            }
            if !published {
                _ = sendWithRepair(client, lakeMessage(startedAt), "lake")
                frame = createMessage(startedAt)
                published = sendWithRepair(client, frame!, "create")
                if !published { frame = nil }
                lastUpdate = now
            } else if now.timeIntervalSince(lastUpdate) >= updateInterval, let update = frame.map({ liveUpdateMessage($0, title: saving ? savingLabel : "Screen Recording") }) {
                // Re-sending the compact surface each second keeps the host's
                // activity alive; the timer itself is rendered from startDate.
                _ = sendWithRepair(client, update, "update")
                lastUpdate = now
            }
        } else {
            switch phase {
            case .live:
                log("recording stopped; finishing")
                phase = .finishing
                finishStarted = now
                lastSize = -1
                sizeChangedAt = now
                lastFinishCheck = .distantPast
                // CleanShot's own stop control also lands here, so the saving
                // spinner covers every way a recording can end.
                startSaving()
            case .finishing:
                // Reading the history plist and scanning media folders is slow;
                // checking four times a second leaves the spinner its frames.
                guard now.timeIntervalSince(lastFinishCheck) >= 0.25 else { break }
                lastFinishCheck = now
                // CleanShot's history names the final file even after it
                // renamed the temporary .mov; fall back to the lsof path and
                // then to a scan of its media folder.
                let historyPath = historyMediaVideo(since: startedAt.addingTimeInterval(-10))
                var candidate = historyPath ?? activePath
                if candidate == nil || !FileManager.default.fileExists(atPath: candidate!) {
                    candidate = newestMediaVideo(since: startedAt.addingTimeInterval(-60))
                    if let candidate { activePath = candidate }
                }
                let waited = now.timeIntervalSince(finishStarted)
                if let candidate, let size = fileSize(candidate), size > 0 {
                    if size != lastSize {
                        lastSize = size
                        sizeChangedAt = now
                    }
                    let settled = now.timeIntervalSince(sizeChangedAt) >= finishSettleTime
                    // Give CleanShot a moment to publish the final file in its
                    // history before falling back to the temporary recording.
                    if ((settled && (historyPath != nil || waited >= 1.5)) || waited >= finishTimeout), !previewing {
                        previewing = true
                        let path = candidate
                        let since = startedAt
                        log("preview building for \(candidate)")
                        DispatchQueue.global(qos: .userInitiated).async { previewBox.set(makePreviewInfo(path: path, since: since)) }
                    }
                } else if waited >= 15 {
                    log("no recording file found after stop")
                    dismissPreview()
                }
            case .preview:
                if let retryAt = previewRetryAt, now >= retryAt, let info = preview {
                    previewRetryAt = nil
                    if sendWithRepair(client, previewLakeMessage(info, reveal: 0), "lake") {
                        beginReveal()
                    } else {
                        previewRetryAt = Date().addingTimeInterval(0.15)
                    }
                }
                if revealPending, now >= revealNextAt, let info = preview {
                    revealStep += 1
                    if revealStep == 1 {
                        do { try client.send(previewRevealMessage(info)) }
                        catch { log("reveal send failed: \(error)") }
                        revealNextAt = now.addingTimeInterval(0.25)
                    } else {
                        revealPending = false
                        // Settle on the exact card if the patch was refused.
                        do { try client.send(previewLakeMessage(info)) } catch { }
                    }
                }
                if now >= previewDeadline {
                    // Stay while the lake is open; otherwise dismiss about ten
                    // seconds after the recording finished.
                    if lakeOpen { previewDeadline = now.addingTimeInterval(previewSeconds) }
                    else { log("preview timed out"); dismissPreview() }
                }
            case .idle:
                break
            }
        }
        if saving && now.timeIntervalSince(lastSpin) >= 1 / savingFramesPerSecond {
            lastSpin = now
            publishSavingFrame()
        }
        // Spinner frames need a much finer tick than the recording poll; the
        // detector throttles its own lsof scans either way.
        // A pending retry needs a fine tick too, or the card would wait a whole
        // poll interval before it is tried again.
        Thread.sleep(forTimeInterval: (saving || revealPending || previewRetryAt != nil) ? 0.008 : pollInterval)
    }
}

exit(main())
