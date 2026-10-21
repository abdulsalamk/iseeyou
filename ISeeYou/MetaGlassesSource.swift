import Foundation
import CoreMedia
import MWDATCore
import MWDATCamera

// Control methods and SDK state transitions run on the main queue. Frames are
// forwarded directly to the bounded inference queue, never processed on main.
final class MetaGlassesSource: @unchecked Sendable {
    var onSetupStatus: ((String) -> Void)?
    private var wearables: (any WearablesInterface)?
    private var deviceSelector: AutoDeviceSelector?
    private var availabilityTask: Task<Void, Never>?
    private var session: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private var sessionTokens = ListenerTokenBag()
    private var streamTokens = ListenerTokenBag()
    private var attempt = UUID()
    private var frameHandler: ((CMSampleBuffer) -> Void)?
    private var stateHandler: ((Bool, String) -> Void)?
    private var setupTask: Task<Void, Never>?

    private func configure() throws -> any WearablesInterface {
        if let wearables { return wearables }
        try Wearables.configure()
        let shared = Wearables.shared
        wearables = shared
        let selector = AutoDeviceSelector(wearables: shared)
        deviceSelector = selector
        availabilityTask = Task { @MainActor [weak self] in
            for await device in selector.activeDeviceStream() {
                guard !Task.isCancelled, let self else { return }
                print("[ISeeYou.Meta] eligibleDevice=\(device != nil)")
                if self.session == nil {
                    self.onSetupStatus?(device == nil
                        ? "Waiting for glasses. Wear them with arms open and check the Meta app connection."
                        : "Glasses ready. Allow camera if needed, then tap Start.")
                }
            }
        }
        return shared
    }
    func connect() {
        setupTask?.cancel()
        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let api = try self.configure()
                try await api.startRegistration()
                self.onSetupStatus?("Registration returned. Allow glasses camera, then tap Start.")
            } catch { self.onSetupStatus?("Glasses registration: " + error.localizedDescription) }
        }
    }
    func authorizeCamera() {
        setupTask?.cancel()
        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let api = try self.configure()
                let status = try await api.checkPermissionStatus(.camera)
                let granted = status == .granted ? status : try await api.requestPermission(.camera)
                self.onSetupStatus?(granted == .granted ? "Glasses camera allowed. Tap Start to stream." : "Glasses camera permission denied.")
            } catch { self.onSetupStatus?("Glasses permission: " + error.localizedDescription) }
        }
    }
    func handleCallback(_ url: URL) {
        guard GlassesCallbackPolicy.accepts(url) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.configure().handleUrl(url)
                self.onSetupStatus?("Glasses callback received. Allow camera or tap Start when ready.")
            } catch { self.onSetupStatus?("Glasses callback: " + error.localizedDescription) }
        }
    }
    func start(onFrame: @escaping (CMSampleBuffer) -> Void, onState: @escaping (Bool, String) -> Void) {
        stop()
        let lease = UUID(); attempt = lease
        frameHandler = onFrame; stateHandler = onState
        Task { @MainActor [weak self] in
            guard let self, self.attempt == lease else { return }
            do {
                let api = try self.configure()
                guard api.registrationState == .registered else {
                    self.fail("Connect Meta glasses before starting.", lease: lease); return
                }
                guard try await api.checkPermissionStatus(.camera) == .granted else {
                    self.fail("Tap Allow glasses camera first, then Start again.", lease: lease); return
                }
                guard self.attempt == lease else { return }
                guard let selector = self.deviceSelector else { return }
                self.onSetupStatus?("Looking for ready glasses…")
                // Discovery is asynchronous. Retain the selector across starts and
                // allow its initial device update to arrive before creating a session.
                for _ in 0..<50 {
                    guard self.attempt == lease else { return }
                    if selector.activeDevice != nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard self.attempt == lease else { return }
                guard selector.activeDevice != nil else {
                    self.fail("No ready glasses found. Wear them with arms open; check Developer Mode and the glasses connection in Meta AI.", lease: lease)
                    return
                }
                let connection = try api.createSession(deviceSelector: selector)
                self.session = connection
                connection.statePublisher.listen { [weak self] state in
                    DispatchQueue.main.async {
                        guard let self, self.attempt == lease else { return }
                        switch state {
                        case .started: self.beginStream(connection, lease: lease)
                        case .paused: self.fail("Glasses session paused. Tap Start to retry.", lease: lease)
                        case .stopped: self.fail("Glasses disconnected. Tap Start to retry.", lease: lease)
                        default: break
                        }
                    }
                }.store(in: self.sessionTokens)
                connection.errorPublisher.listen { [weak self] error in
                    DispatchQueue.main.async { self?.fail(error.localizedDescription, lease: lease) }
                }.store(in: self.sessionTokens)
                try connection.start()
            } catch { self.fail(error.localizedDescription, lease: lease) }
        }
    }
    private func beginStream(_ connection: DeviceSession, lease: UUID) {
        guard camera == nil, attempt == lease else { return }
        do {
            guard let camera = try connection.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 15)) else {
                fail("Cannot create glasses camera stream.", lease: lease); return
            }
            self.camera = camera
            let frameHandler = self.frameHandler
            camera.stream.videoFramePublisher.listen { frame in frameHandler?(frame.sampleBuffer) }.store(in: streamTokens)
            camera.stream.statePublisher.listen { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.attempt == lease else { return }
                    switch state {
                    case .streaming: self.stateHandler?(true, "Meta glasses camera active · estimates unverified")
                    case .paused: self.fail("Glasses camera paused. Tap Start to retry.", lease: lease)
                    case .stopped: self.fail("Glasses camera stopped. Tap Start to retry.", lease: lease)
                    default: break
                    }
                }
            }.store(in: streamTokens)
            camera.stream.errorPublisher.listen { [weak self] error in
                DispatchQueue.main.async { self?.fail(error.localizedDescription, lease: lease) }
            }.store(in: streamTokens)
            camera.stream.start()
        } catch { fail(error.localizedDescription, lease: lease) }
    }
    private func fail(_ message: String, lease: UUID) {
        guard attempt == lease else { return }
        let callback = stateHandler
        stop()
        callback?(false, message)
    }
    func stop() {
        attempt = UUID()
        streamTokens.clear(); sessionTokens.clear()
        camera?.stop(); camera = nil
        session?.stop(); session = nil
        frameHandler = nil; stateHandler = nil
    }
}

enum GlassesCallbackPolicy {
    static func accepts(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return false }
        return url.scheme == "iseeyou" || (url.scheme == "https" && url.host == "abdulsalamk.github.io" && (parts.path == "/iseeyou" || parts.path.hasPrefix("/iseeyou/")))
    }
}

// Drop incoming frames while inference is busy: no queue of stale glasses frames.
final class InferenceFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func begin() -> Bool { lock.withLock { if busy { return false }; busy = true; return true } }
    func end() { lock.withLock { busy = false } }
}
