import AppKit
import ApplicationServices
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

private enum EvdevBtn {
    static let left: UInt32 = 0x110
    static let right: UInt32 = 0x111
    static let middle: UInt32 = 0x112
}

@objc(AnowawMacApp)
public final class AnowawMacApp: NSObject {
    @objc public var bundleId: String = ""
    @objc public var localizedName: String = ""
    @objc public var appURL: URL?
    @objc public var pid: pid_t = 0
}

@objc(AnowawMacBridge)
public final class AnowawMacBridge: NSObject {
    private var core: UnsafeMutableRawPointer?
    private var socketName: String = ""
    private var bridgeThread: Thread?
    private var running = false
    private var windows: [UInt64: AnowawMacWindow] = [:]
    private let captureQueue = DispatchQueue(label: "com.aspauldingcode.Wawona.anowaw.capture")
    private let windowsLock = NSLock()

    @objc public class func enumerateApps() -> [AnowawMacApp] {
        var out: [AnowawMacApp] = []
        var seen = Set<String>()
        for ra in NSWorkspace.shared.runningApplications where ra.activationPolicy == .regular {
            guard let bid = ra.bundleIdentifier else { continue }
            let app = AnowawMacApp()
            app.bundleId = bid
            app.localizedName = ra.localizedName ?? bid
            app.appURL = ra.bundleURL
            app.pid = ra.processIdentifier
            out.append(app)
            seen.insert(bid)
        }
        for dir in ["/Applications", "/System/Applications"] {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                guard let bid = Bundle(url: url)?.bundleIdentifier, !seen.contains(bid) else { continue }
                let app = AnowawMacApp()
                app.bundleId = bid
                app.localizedName = (name as NSString).deletingPathExtension
                app.appURL = url
                app.pid = 0
                out.append(app)
                seen.insert(bid)
            }
        }
        return out
    }

    @objc public class func hasCapturePermission() -> Bool { CGPreflightScreenCaptureAccess() }
    @objc public class func hasInputPermission() -> Bool { AXIsProcessTrusted() }

    @objc public init?(socketName: String) {
        super.init()
        self.socketName = socketName
        if anowaw_abi_version() != 1 { return nil }
        running = true
        let thread = Thread(target: self, selector: #selector(bridgeThreadMain), object: nil)
        thread.name = "anowaw-bridge"
        bridgeThread = thread
        thread.start()
    }

    @objc private func bridgeThreadMain() {
        autoreleasepool {
            core = socketName.withCString { anowaw_start($0) }
            if core == nil {
                NSLog("anowaW: failed to connect to nested Weston socket %@", socketName)
                running = false
                return
            }
        }
        let cap = 256
        var events = [AnowawInputEvent](repeating: AnowawInputEvent(), count: cap)
        while running {
            autoreleasepool {
                guard let core else { return }
                anowaw_dispatch(core)
                let n = anowaw_poll_input(core, &events, cap)
                if n > 0 {
                    for i in 0..<n { injectEvent(&events[i]) }
                }
                windowsLock.lock()
                let keys = Array(windows.keys)
                windowsLock.unlock()
                for h in keys {
                    if anowaw_close_requested(core, h) != 0 { closeApp(h) }
                }
                usleep(8000)
            }
        }
        if let core { anowaw_stop(core) }
        self.core = nil
    }

    @objc public func bridgeApp(withBundleId bundleId: String, completion: @escaping (UInt64, NSError?) -> Void) {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if let ra = runningApps.first {
            locateAndBridge(for: ra, bundleId: bundleId, completion: completion)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            completion(0, NSError(domain: "anowaw", code: 404, userInfo: [NSLocalizedDescriptionKey: "app not found"]))
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { ra, err in
            if let err = err ?? (ra == nil ? NSError(domain: "anowaw", code: 500, userInfo: nil) : nil) {
                completion(0, err)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                locateAndBridge(for: ra!, bundleId: bundleId, completion: completion)
            }
        }
    }

    private func locateAndBridge(for ra: NSRunningApplication, bundleId: String, completion: @escaping (UInt64, NSError?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error { completion(0, error); return }
            guard let content else { completion(0, nil); return }
            let target = content.windows.first {
                $0.owningApplication?.processID == ra.processIdentifier && $0.isOnScreen && $0.frame.size.width > 1 && $0.frame.size.height > 1
            }
            guard let target else {
                completion(0, NSError(domain: "anowaw", code: 410, userInfo: [NSLocalizedDescriptionKey: "no capturable window for app"]))
                return
            }
            startCapture(for: target, bundleId: bundleId, pid: ra.processIdentifier, completion: completion)
        }
    }

    private func startCapture(for scWindow: SCWindow, bundleId: String, pid: pid_t, completion: @escaping (UInt64, NSError?) -> Void) {
        let w = UInt32(scWindow.frame.size.width)
        let h = UInt32(scWindow.frame.size.height)
        var handle: UInt64 = 0
        performOnBridgeThreadSync {
            guard let core else { return }
            bundleId.withCString { bid in
                (scWindow.title ?? bundleId).withCString { title in
                    handle = anowaw_bridge_app(core, bid, title, w, h)
                }
            }
        }
        if handle == 0 {
            completion(0, NSError(domain: "anowaw", code: 500, userInfo: [NSLocalizedDescriptionKey: "anowaw_bridge_app failed"]))
            return
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(w)
        cfg.height = Int(h)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.queueDepth = 3
        let ctx = AnowawMacWindow()
        ctx.handle = handle
        ctx.pid = pid
        ctx.windowId = CGWindowID(scWindow.windowID)
        ctx.windowOrigin = scWindow.frame.origin
        ctx.owner = self
        let stream = SCStream(filter: filter, configuration: cfg, delegate: ctx)
        do {
            try stream.addStreamOutput(ctx, type: .screen, sampleHandlerQueue: captureQueue)
        } catch {
            closeApp(handle)
            completion(0, error as NSError)
            return
        }
        ctx.stream = stream
        windowsLock.lock()
        windows[handle] = ctx
        windowsLock.unlock()
        stream.startCapture { err in
            if let err {
                self.closeApp(handle)
                completion(0, err as NSError)
                return
            }
            completion(handle, nil)
        }
    }

    func pushFrame(forHandle handle: UInt64, pixelBuffer pb: CVPixelBuffer) {
        guard let core else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        let len = stride * height
        anowaw_push_frame(core, handle, base.assumingMemoryBound(to: UInt8.self), len, UInt32(width), UInt32(height), UInt32(stride), ANOWAW_FORMAT_BGRA8888)
    }

    private func injectEvent(_ ev: UnsafePointer<AnowawInputEvent>) {
        windowsLock.lock()
        let ctx = windows[ev.pointee.handle]
        windowsLock.unlock()
        guard let ctx else { return }
        switch ev.pointee.kind {
        case ANOWAW_INPUT_POINTER_MOTION:
            let p = CGPoint(x: ctx.windowOrigin.x + ev.pointee.x, y: ctx.windowOrigin.y + ev.pointee.y)
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left), toPid: ctx.pid)
        case ANOWAW_INPUT_POINTER_BUTTON:
            var btn = CGMouseButton.left
            var down = CGEventType.leftMouseDown
            var up = CGEventType.leftMouseUp
            if ev.pointee.code == EvdevBtn.right { btn = .right; down = .rightMouseDown; up = .rightMouseUp }
            else if ev.pointee.code == EvdevBtn.middle { btn = .center; down = .otherMouseDown; up = .otherMouseUp }
            let p = CGPoint(x: ctx.windowOrigin.x + ev.pointee.x, y: ctx.windowOrigin.y + ev.pointee.y)
            post(CGEvent(mouseEventSource: nil, mouseType: ev.pointee.value != 0 ? down : up, mouseCursorPosition: p, mouseButton: btn), toPid: ctx.pid)
        case ANOWAW_INPUT_POINTER_AXIS:
            post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-ev.pointee.y), wheel2: Int32(-ev.pointee.x), wheel3: 0), toPid: ctx.pid)
        case ANOWAW_INPUT_KEY:
            let kc = macKeyCode(forEvdev: ev.pointee.code)
            if kc != 0xFFFF {
                post(CGEvent(keyboardEventSource: nil, virtualKey: kc, keyDown: ev.pointee.value != 0), toPid: ctx.pid)
            }
        case ANOWAW_INPUT_POINTER_FOCUS:
            if ev.pointee.value == 1 {
                NSRunningApplication(processIdentifier: ctx.pid)?.activate()
            }
        default: break
        }
    }

    private func post(_ event: CGEvent?, toPid pid: pid_t) {
        guard let event else { return }
        CGEventPostToPid(pid, event)
    }

    private func macKeyCode(forEvdev code: UInt32) -> CGKeyCode {
        switch code {
        case 1: return 53
        case 28: return 36
        case 14: return 51
        case 15: return 48
        case 57: return 49
        case 30: return 0
        case 48: return 11
        case 46: return 8
        case 32: return 2
        case 18: return 14
        case 33: return 3
        case 105: return 123
        case 106: return 124
        case 103: return 126
        case 108: return 125
        default: return 0xFFFF
        }
    }

    @objc public func closeApp(_ handle: UInt64) {
        windowsLock.lock()
        let ctx = windows.removeValue(forKey: handle)
        windowsLock.unlock()
        ctx?.stream?.stopCapture { _ in }
        ctx?.stream = nil
        performOnBridgeThreadAsync { [weak self] in
            guard let self, let core = self.core else { return }
            anowaw_close_app(core, handle)
        }
    }

    @objc public func stop() {
        running = false
        windowsLock.lock()
        let keys = Array(windows.keys)
        windowsLock.unlock()
        for k in keys { closeApp(k) }
    }

    private func performOnBridgeThreadSync(_ block: @escaping () -> Void) {
        guard let bridgeThread else { block(); return }
        if Thread.current == bridgeThread { block(); return }
        perform(#selector(runBlock(_:)), on: bridgeThread, with: block, waitUntilDone: true)
    }

    private func performOnBridgeThreadAsync(_ block: @escaping () -> Void) {
        guard let bridgeThread else { block(); return }
        if Thread.current == bridgeThread { block(); return }
        perform(#selector(runBlock(_:)), on: bridgeThread, with: block, waitUntilDone: false)
    }

    @objc private func runBlock(_ block: () -> Void) { block() }
}

private final class AnowawMacWindow: NSObject, SCStreamDelegate, SCStreamOutput {
    var handle: UInt64 = 0
    var pid: pid_t = 0
    var windowId: CGWindowID = 0
    var windowOrigin = CGPoint.zero
    weak var owner: AnowawMacBridge?
    var stream: SCStream?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer), let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        owner?.pushFrame(forHandle: handle, pixelBuffer: pb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("anowaW: SCStream stopped for handle %llu: %@", handle, error.localizedDescription)
        owner?.closeApp(handle)
    }
}

// C ABI (anowaw.h)
@_silgen_name("anowaw_abi_version") private func anowaw_abi_version() -> UInt32
@_silgen_name("anowaw_start") private func anowaw_start(_ socket: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
@_silgen_name("anowaw_dispatch") private func anowaw_dispatch(_ core: UnsafeMutableRawPointer?)
@_silgen_name("anowaw_poll_input") private func anowaw_poll_input(_ core: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<AnowawInputEvent>?, _ cap: Int) -> Int32
@_silgen_name("anowaw_close_requested") private func anowaw_close_requested(_ core: UnsafeMutableRawPointer?, _ handle: UInt64) -> Int32
@_silgen_name("anowaw_bridge_app") private func anowaw_bridge_app(_ core: UnsafeMutableRawPointer?, _ appId: UnsafePointer<CChar>?, _ title: UnsafePointer<CChar>?, _ w: UInt32, _ h: UInt32) -> UInt64
@_silgen_name("anowaw_push_frame") private func anowaw_push_frame(_ core: UnsafeMutableRawPointer?, _ handle: UInt64, _ data: UnsafePointer<UInt8>?, _ len: Int, _ w: UInt32, _ h: UInt32, _ stride: UInt32, _ format: UInt32)
@_silgen_name("anowaw_close_app") private func anowaw_close_app(_ core: UnsafeMutableRawPointer?, _ handle: UInt64)
@_silgen_name("anowaw_stop") private func anowaw_stop(_ core: UnsafeMutableRawPointer?)

private struct AnowawInputEvent {
    var handle: UInt64 = 0
    var kind: UInt32 = 0
    var code: UInt32 = 0
    var value: Int32 = 0
    var x: Double = 0
    var y: Double = 0
    var time_ms: UInt32 = 0
    var _reserved: UInt32 = 0
}

private let ANOWAW_FORMAT_BGRA8888: UInt32 = 0
private let ANOWAW_INPUT_POINTER_MOTION: UInt32 = 0
private let ANOWAW_INPUT_POINTER_BUTTON: UInt32 = 1
private let ANOWAW_INPUT_POINTER_AXIS: UInt32 = 2
private let ANOWAW_INPUT_KEY: UInt32 = 3
private let ANOWAW_INPUT_POINTER_FOCUS: UInt32 = 6
