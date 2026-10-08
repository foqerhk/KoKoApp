import AVFoundation
import CoreImage
import os
import UIKit

/// Captures the phone camera for "Use Phone as Webcam".
/// Default: full MJPEG (proven path that showed a picture). H.264 remains opt-in only.
final class PhoneCameraStreamer: NSObject, ObservableObject {
    enum Codec: String, Sendable {
        case mjpeg
        case h264
    }

    @MainActor @Published private(set) var isRunning = false
    @MainActor @Published private(set) var position: AVCaptureDevice.Position = .front
    @MainActor @Published private(set) var previewImage: UIImage?
    @MainActor @Published private(set) var lastError: String?
    @MainActor @Published private(set) var activeCodec: Codec = .mjpeg

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "koko.phonecam.session")
    private let output = AVCaptureVideoDataOutput()
    private var deviceInput: AVCaptureDeviceInput?
    /// Invoked on the capture queue (not MainActor).
    private var frameHandler: ((Data, Int, Int, Bool, Codec) -> Void)?
    private var throttleLock = os_unfair_lock()
    private var captureLastSent: CFTimeInterval = 0
    private var previewLastSent: CFTimeInterval = 0
    private var targetFPS: Double = 10
    private var codec: Codec = .mjpeg
    private var h264 = H264Encoder(keyInterval: 12, bitrate: 900_000)

    /// MJPEG by default. H.264 only via `re2.phoneCamCodec=h264` / `KOKO_PHONECAM_H264=1`.
    static var preferredCodec: Codec {
        if ProcessInfo.processInfo.environment["KOKO_PHONECAM_H264"] == "1" { return .h264 }
        if ProcessInfo.processInfo.arguments.contains("-RE2PhoneCamH264") { return .h264 }
        let raw = (UserDefaults.standard.string(forKey: "re2.phoneCamCodec") ?? "mjpeg").lowercased()
        return raw == "h264" ? .h264 : .mjpeg
    }

    func onFrame(_ handler: @escaping (Data, Int, Int, Bool, Codec) -> Void) {
        frameHandler = handler
    }

    func setTargetFPS(_ fps: Double) {
        let v = min(15, max(3, fps))
        os_unfair_lock_lock(&throttleLock)
        targetFPS = v
        os_unfair_lock_unlock(&throttleLock)
    }

    func setCodec(_ codec: Codec) {
        os_unfair_lock_lock(&throttleLock)
        self.codec = codec
        os_unfair_lock_unlock(&throttleLock)
        if codec != .h264 {
            h264.invalidate()
        }
        Task { @MainActor in self.activeCodec = codec }
    }

    @MainActor
    func start(position: AVCaptureDevice.Position = .front) async {
        lastError = nil
        let granted = await requestAccess()
        guard granted else {
            lastError = String(localized: "Camera permission denied")
            return
        }
        let pos = position
        let want = Self.preferredCodec
        setCodec(want)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.configureSession(position: pos)
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                let running = self.session.isRunning
                Task { @MainActor in
                    self.position = pos
                    self.isRunning = running
                    cont.resume()
                }
            }
        }
    }

    @MainActor
    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.session.beginConfiguration()
            if let input = self.deviceInput {
                self.session.removeInput(input)
            }
            self.deviceInput = nil
            for out in self.session.outputs {
                self.session.removeOutput(out)
            }
            self.session.commitConfiguration()
            self.h264.invalidate()
            Task { @MainActor in
                self.isRunning = false
                self.previewImage = nil
            }
        }
    }

    @MainActor
    func flip() async {
        let next: AVCaptureDevice.Position = position == .front ? .back : .front
        await start(position: next)
    }

    private func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    private func configureSession(position: AVCaptureDevice.Position) {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        if let old = deviceInput {
            session.removeInput(old)
            deviceInput = nil
        }
        for out in session.outputs {
            session.removeOutput(out)
        }

        guard let device = Self.device(for: position) else {
            session.commitConfiguration()
            Task { @MainActor in
                self.lastError = String(localized: "No camera available")
                self.isRunning = false
            }
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                deviceInput = input
            }
        } catch {
            session.commitConfiguration()
            Task { @MainActor in
                self.lastError = error.localizedDescription
                self.isRunning = false
            }
            return
        }

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        if let conn = output.connection(with: .video) {
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            if conn.isVideoMirroringSupported {
                conn.isVideoMirrored = position == .front
            }
        }
        session.commitConfiguration()
    }

    private static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            return d
        }
        return AVCaptureDevice.default(for: .video)
    }
}

extension PhoneCameraStreamer: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(&throttleLock)
        let minInterval = 1.0 / max(3.0, targetFPS)
        let mode = codec
        let tooSoon = now - captureLastSent < minInterval
        if !tooSoon { captureLastSent = now }
        os_unfair_lock_unlock(&throttleLock)
        if tooSoon { return }

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let srcW = CGFloat(CVPixelBufferGetWidth(pb))
        let srcH = CGFloat(CVPixelBufferGetHeight(pb))
        guard srcW > 0, srcH > 0 else { return }
        // Proven MJPEG sizing (pre-keyframe experiment). H264 can stay smaller.
        let maxEdge: CGFloat = mode == .h264 ? 640 : 560
        let scale = min(1, maxEdge / max(srcW, srcH))
        let tw = max(2, Int((srcW * scale).rounded(.down) / 2) * 2)
        let th = max(2, Int((srcH * scale).rounded(.down) / 2) * 2)

        let ci = CIImage(cvPixelBuffer: pb)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(tw) / srcW, y: CGFloat(th) / srcH))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        var scaledPB: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(nil, tw, th, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &scaledPB)
        guard let scaledPB else { return }
        ctx.render(scaled, to: scaledPB)

        let handler = frameHandler
        if mode == .h264 {
            if let (annexB, isKey) = h264.encode(pixelBuffer: scaledPB, forceKey: false) {
                handler?(annexB, tw, th, isKey, .h264)
            } else if let jpeg = Self.jpeg(from: scaledPB, quality: 0.32) {
                handler?(jpeg, tw, th, true, .mjpeg)
            }
        } else if let jpeg = Self.jpeg(from: scaledPB, quality: 0.32) {
            handler?(jpeg, tw, th, true, .mjpeg)
        }

        // Preview is HUD-only — refresh ~3fps so SwiftUI/MainActor aren't flooded
        // while the desktop gesture surface needs the run loop.
        if now - previewLastSent >= (1.0 / 3.0) {
            previewLastSent = now
            if let cg = ctx.createCGImage(CIImage(cvPixelBuffer: scaledPB), from: CGRect(x: 0, y: 0, width: tw, height: th)) {
                let ui = UIImage(cgImage: cg)
                Task { @MainActor in self.previewImage = ui }
            }
        }
    }

    private static func jpeg(from pb: CVPixelBuffer, quality: CGFloat) -> Data? {
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard let cg = ctx.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) else {
            return nil
        }
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
    }
}
