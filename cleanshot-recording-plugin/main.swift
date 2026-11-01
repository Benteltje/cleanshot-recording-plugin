import ApplicationServices
import Darwin
import Foundation

let schemaVersion = 1
let activityID = "com.benjamin.cleanshot-recording"
let pluginTitle = "CleanShot Recording"
let pollInterval: TimeInterval = 0.4
let lingerSeconds: TimeInterval = 2.5
let updateInterval: TimeInterval = 1.0
let videoExtensions = [".mov", ".mp4", ".m4v", ".mkv", ".avi", ".ts"]
let forceFiles = ["/tmp/cleanshot-recording-force", NSHomeDirectory() + "/.cleanshot-recording-force"]
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
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    do { try process.run() } catch { return "" }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning { process.terminate(); process.waitUntilExit() }
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

func detect() -> (Bool, String) {
    for marker in forceFiles where FileManager.default.fileExists(atPath: marker) { return (true, "force marker \(marker)") }
    let pids = cleanShotPIDs()
    if let path = recordingFile(for: pids) { return (true, "CleanShot writing \(path)") }
    return (false, "idle")
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
func dot() -> [String: Any] { ["type": "image", "id": "recording-dot", "source": "sfSymbol", "systemImage": "circle.fill", "tint": "red"] }
func timer(_ startedAt: Date) -> [String: Any] { ["type": "timer", "id": "recording-duration", "startDate": iso(startedAt), "endDate": iso(startedAt.addingTimeInterval(86_400)), "countsDown": false, "tint": "red"] }
func label(_ text: String, tint: String = "white") -> [String: Any] { ["type": "text", "id": "recording-label", "text": text, "tint": tint] }
func stopButton() -> [String: Any] { ["type": "button", "id": "stop-recording", "systemImage": "stop.fill", "tint": "red", "actionID": "stop-recording", "value": 1] }

func createMessage(_ startedAt: Date) -> [String: Any] {
    ["schemaVersion": schemaVersion, "requestID": "rec-\(Int(startedAt.timeIntervalSince1970))", "type": "create", "activityID": activityID, "title": pluginTitle, "priority": "high", "size": "small", "surfaces": ["compactLiveActivity": ["leftSlot": dot()], "extraLiveActivity": ["leftSlot": label("Screen Recording")]]]
}
func lakeMessage(_ startedAt: Date) -> [String: Any] {
    ["schemaVersion": schemaVersion, "requestID": "lake-\(Int(startedAt.timeIntervalSince1970))", "type": "lake", "lake": ["hideHeader": true, "content": [["type": "hstack", "alignment": "center", "spacing": 0, "children": [["type": "vstack", "alignment": "leading", "spacing": 2, "children": [["type": "hstack", "alignment": "center", "spacing": 0, "children": [dot(), timer(startedAt)]], label("Screen Recording")]], ["type": "spacer"], stopButton()]]]]]
}
func clearLakeMessage() -> [String: Any] { ["schemaVersion": schemaVersion, "requestID": "lake-clear-\(Int(Date().timeIntervalSince1970))", "type": "lake", "lake": ["hideHeader": true, "content": []]] }
func dismissMessage() -> [String: Any] { ["schemaVersion": schemaVersion, "requestID": "dismiss-\(Int(Date().timeIntervalSince1970))", "type": "dismiss", "activityID": activityID] }
func permissionMessage() -> [String: Any] { ["schemaVersion": schemaVersion, "requestID": "permission-\(Int(Date().timeIntervalSince1970))", "type": "requestPermission", "permission": "accessibility"] }

func stripField(_ message: inout [String: Any], path: String, field: String) -> Bool {
    let parts = path.split(separator: ".").filter { !$0.isEmpty && $0 != "$" }.map(String.init)
    func remove(_ node: inout [String: Any], _ index: Int) -> Bool {
        if index == parts.count { return node.removeValue(forKey: field) != nil }
        guard var child = node[parts[index]] as? [String: Any] else { return false }
        let removed = remove(&child, index + 1)
        node[parts[index]] = child
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
                    guard let type = reply["type"] as? String, ["response", "error"].contains(type), (reply["requestID"] as? String == nil || reply["requestID"] as? String == requestID) else { continue }
                    answered = true
                    if reply["ok"] as? Bool == true { if name != "update" { log("\(name) accepted") }; return true }
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
    var published = false, lastPositive = Date.distantPast, lastReason = "idle", frame: [String: Any]?
    var startedAt = Date.distantPast, lastUpdate = Date.distantPast, stopPressedAt = Date.distantPast, lastStopAttempt = Date.distantPast
    while true {
        do {
            for message in try client.readAvailable() where message["type"] as? String == "action" && message["actionID"] as? String == "stop-recording" {
                let now = Date()
                guard now.timeIntervalSince(lastStopAttempt) >= 1 else { continue }
                lastStopAttempt = now; log("stop requested from lake button")
                let result = stopRecording(); log("stop result: \(result)")
                if result == "pressed" { stopPressedAt = Date() }
                else if result == "untrusted" { _ = sendWithRepair(client, permissionMessage(), "permission") }
            }
        } catch { log("host closed the socket"); return 0 }
        let (active, reason) = detect()
        let now = Date()
        if active { lastPositive = now }
        let linger: TimeInterval = now.timeIntervalSince(stopPressedAt) < 15 ? 0.6 : lingerSeconds
        let wanting = active || now.timeIntervalSince(lastPositive) < linger
        if reason != lastReason { log("state: \(reason) (wanting=\(wanting))"); lastReason = reason }
        if wanting && !published {
            if frame == nil { if !sendWithRepair(client, lakeMessage(now), "lake") { log("lake content rejected; continuing without it") }; frame = createMessage(now) }
            let ok = sendWithRepair(client, frame!, "create")
            published = ok; startedAt = now; lastUpdate = now
            if !ok { frame = nil; Thread.sleep(forTimeInterval: 2) }
        } else if wanting && published && now.timeIntervalSince(lastUpdate) >= updateInterval, var update = frame {
            update["type"] = "update"; update["requestID"] = "update-\(Int(now.timeIntervalSince1970))"
            _ = sendWithRepair(client, update, "update"); lastUpdate = now
        } else if !wanting && published {
            _ = sendWithRepair(client, dismissMessage(), "dismiss"); _ = sendWithRepair(client, clearLakeMessage(), "lake-clear")
            published = false; frame = nil
        }
        _ = startedAt // preserved state: the activity timer begins when the card is published.
        Thread.sleep(forTimeInterval: pollInterval)
    }
}

exit(main())
