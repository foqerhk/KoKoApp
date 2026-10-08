import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreImage

/// Annex-B decoder (H.264 or HEVC) → CGImage.
/// Production: hardware VT first, software fallback. Soft-only only when explicitly forced.
final class H264Decoder {
    enum Codec {
        case h264
        case hevc
    }

    private static let forceSoftDefaultsKey = "re2.forceSoftDecode"

    /// Debug-only: force software VT decoder. `-RE2SoftDecode` / `KOKO_RE2_SOFT_DECODE=1` /
    /// `UserDefaults` `re2.forceSoftDecode`. Default production path does **not** set this.
    static var forceSoftware: Bool {
        if ProcessInfo.processInfo.arguments.contains("-RE2SoftDecode") { return true }
        if ProcessInfo.processInfo.environment["KOKO_RE2_SOFT_DECODE"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: forceSoftDefaultsKey)
    }

    /// Clear persisted soft-only flag so normal launches stay HW-first.
    static func clearForceSoftwareDefault() {
        UserDefaults.standard.removeObject(forKey: forceSoftDefaultsKey)
    }

    private var codec: Codec = .h264
    private var formatDesc: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var ptsValue: Int64 = 0
    private var loggedSessionFail = false
    private var loggedDecodeFail = false
    private let queue = DispatchQueue(label: "re2.video.decoder")
    private let pendingLock = NSLock()
    private var pendingDecodes = 0
    /// Last fatal decoder error (E2E / black-screen diagnosis).
    private(set) var lastError: String = ""
    /// Which VT path created the current session (for soft-decode smoke).
    private(set) var lastSessionBackend: String = ""

    /// Switch wire codec; resets parameter sets / session.
    func setCodec(_ codec: Codec) {
        queue.sync {
            guard self.codec != codec else { return }
            self.codec = codec
            self.invalidateSession()
            self.vps = nil
            self.sps = nil
            self.pps = nil
            self.loggedSessionFail = false
            self.loggedDecodeFail = false
            self.lastError = ""
            RE2Log.info("video decoder codec → \(codec == .hevc ? "h265" : "h264")")
        }
    }

    func reset() {
        queue.sync {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            formatDesc = nil
            vps = nil
            sps = nil
            pps = nil
            ptsValue = 0
            loggedSessionFail = false
            loggedDecodeFail = false
            lastError = ""
            lastSessionBackend = ""
        }
    }

    func decode(annexB: Data, isKey: Bool, onImage: @escaping (CGImage) -> Void) {
        pendingLock.lock()
        if pendingDecodes >= 3, !isKey {
            pendingLock.unlock()
            return
        }
        pendingDecodes += 1
        pendingLock.unlock()
        queue.async {
            defer {
                self.pendingLock.lock()
                self.pendingDecodes = max(0, self.pendingDecodes - 1)
                self.pendingLock.unlock()
            }
            self.decodeLocked(annexB: annexB, isKey: isKey, onImage: onImage)
        }
    }

    private func decodeLocked(annexB: Data, isKey: Bool, onImage: @escaping (CGImage) -> Void) {
        let nals = Self.splitAnnexB(annexB)
        if nals.isEmpty {
            if !loggedDecodeFail {
                loggedDecodeFail = true
                RE2Log.error("\(codecTag) splitAnnexB empty bytes=\(annexB.count) key=\(isKey)")
            }
            return
        }
        switch codec {
        case .h264:
            for nal in nals {
                guard !nal.isEmpty else { continue }
                let nt = nal[0] & 0x1F
                switch nt {
                case 7:
                    if sps != nal {
                        sps = nal
                        invalidateSession()
                    }
                case 8:
                    if pps != nal {
                        pps = nal
                        invalidateSession()
                    }
                case 5, 1:
                    guard ensureSession() else { continue }
                    decodeNAL(nal, onImage: onImage)
                default:
                    break
                }
            }
        case .hevc:
            for nal in nals {
                guard !nal.isEmpty else { continue }
                let nt = Int((nal[0] >> 1) & 0x3F)
                switch nt {
                case 32: // VPS
                    if vps != nal {
                        vps = nal
                        invalidateSession()
                    }
                case 33: // SPS
                    if sps != nal {
                        sps = nal
                        invalidateSession()
                    }
                case 34: // PPS
                    if pps != nal {
                        pps = nal
                        invalidateSession()
                    }
                case 16, 17, 18, 19, 20, 21, // BLA / IDR / CRA
                    0, 1: // TRAIL_N / TRAIL_R
                    guard ensureSession() else { continue }
                    decodeNAL(nal, onImage: onImage)
                default:
                    break
                }
            }
        }
    }

    private var codecTag: String { codec == .hevc ? "h265" : "h264" }

    private func invalidateSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDesc = nil
    }

    private func ensureSession() -> Bool {
        if session != nil { return true }
        guard let sps, let pps else {
            if !loggedSessionFail {
                loggedSessionFail = true
                RE2Log.error("\(codecTag) waiting for parameter sets before slice")
            }
            return false
        }
        if codec == .hevc, vps == nil {
            if !loggedSessionFail {
                loggedSessionFail = true
                RE2Log.error("h265 waiting for VPS before slice")
            }
            return false
        }

        var desc: CMVideoFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = sps.withUnsafeBytes { spsRaw in
                guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress else { return OSStatus(-1) }
                return pps.withUnsafeBytes { ppsRaw in
                    guard let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return OSStatus(-1) }
                    var sizes = [sps.count, pps.count]
                    return [spsBase, ppsBase].withUnsafeBufferPointer { ptrs in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrs.baseAddress!,
                            parameterSetSizes: &sizes,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &desc
                        )
                    }
                }
            }
        case .hevc:
            guard let vps else { return false }
            status = vps.withUnsafeBytes { vpsRaw in
                guard let vpsBase = vpsRaw.bindMemory(to: UInt8.self).baseAddress else { return OSStatus(-1) }
                return sps.withUnsafeBytes { spsRaw in
                    guard let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress else { return OSStatus(-1) }
                    return pps.withUnsafeBytes { ppsRaw in
                        guard let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return OSStatus(-1) }
                        var sizes = [vps.count, sps.count, pps.count]
                        return [vpsBase, spsBase, ppsBase].withUnsafeBufferPointer { ptrs in
                            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: ptrs.baseAddress!,
                                parameterSetSizes: &sizes,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &desc
                            )
                        }
                    }
                }
            }
        }
        guard status == noErr, let desc else {
            if !loggedSessionFail {
                loggedSessionFail = true
                RE2Log.error("\(codecTag) formatDesc failed status=\(status) vps=\(vps?.count ?? 0) sps=\(sps.count) pps=\(pps.count)")
            }
            return false
        }
        formatDesc = desc
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        // Default: hardware → software → VT default. Soft-only for explicit smoke, or
        // when the bitstream exceeds Apple HW decode (~8K) — 16K full-blood needs soft VT.
        let softOnly = Self.forceSoftware
        let overHW = dims.width > 8192 || dims.height > 8192
        let attempts: [(label: String, spec: [CFString: Any]?)] = (softOnly || overHW)
            ? [
                ("software", [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false]),
                ("default", nil)
            ]
            : [
                ("hardware", [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]),
                ("software", [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false]),
                ("default", nil)
            ]
        var sess: VTDecompressionSession?
        var err: OSStatus = -1
        var backend = ""
        for attempt in attempts {
            sess = nil
            err = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: desc,
                decoderSpecification: attempt.spec as CFDictionary?,
                imageBufferAttributes: attrs as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &sess
            )
            if err == noErr, sess != nil {
                backend = attempt.label
                break
            }
        }
        guard err == noErr, let sess else {
            if !loggedSessionFail {
                loggedSessionFail = true
                lastError = "VTDecompressionSessionCreate status=\(err) dims=\(dims.width)x\(dims.height) softOnly=\(softOnly)"
                RE2Log.error("\(codecTag) \(lastError) sps=\(sps.count) pps=\(pps.count)")
            }
            return false
        }
        session = sess
        lastSessionBackend = backend
        loggedSessionFail = false
        RE2Log.info("\(codecTag) decoder session ready \(dims.width)x\(dims.height) backend=\(backend) softOnly=\(softOnly) vps=\(vps?.count ?? 0) sps=\(sps.count) pps=\(pps.count)")
        return true
    }

    private func decodeNAL(_ nal: Data, onImage: @escaping (CGImage) -> Void) {
        guard let formatDesc, let session else { return }

        var avcc = Data(capacity: 4 + nal.count)
        avcc.appendUInt32BE(UInt32(nal.count))
        avcc.append(nal)

        var blockBuffer: CMBlockBuffer?
        let length = avcc.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return }
        status = avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard status == noErr else { return }

        ptsValue &+= 1
        let pts = CMTime(value: ptsValue, timescale: 600)
        var sampleSize = length
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 600),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }

        var infoFlags: VTDecodeInfoFlags = []
        let st = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                if self?.loggedDecodeFail != true {
                    self?.loggedDecodeFail = true
                    self?.lastError = "decodeFrame status=\(status)"
                    RE2Log.error("\(self?.codecTag ?? "video") \(self?.lastError ?? "")")
                }
                return
            }
            guard let cg = H264Decoder.cgImage(from: imageBuffer) else {
                if self?.loggedDecodeFail != true {
                    self?.loggedDecodeFail = true
                    let w = CVPixelBufferGetWidth(imageBuffer)
                    let h = CVPixelBufferGetHeight(imageBuffer)
                    self?.lastError = "CGImage conversion failed \(w)x\(h)"
                    RE2Log.error("\(self?.codecTag ?? "video") \(self?.lastError ?? "")")
                }
                return
            }
            onImage(cg)
        }
        if st != noErr, !loggedDecodeFail {
            loggedDecodeFail = true
            lastError = "DecodeFrame enqueue status=\(st)"
            RE2Log.error("\(codecTag) \(lastError)")
        }
    }

    static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append(i + 3)
                    i += 3
                    continue
                }
                if i + 4 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append(i + 4)
                    i += 4
                    continue
                }
            }
            i += 1
        }
        if starts.isEmpty {
            return data.isEmpty ? [] : [data]
        }
        var out: [Data] = []
        for (idx, begin) in starts.enumerated() {
            let end: Int
            if idx + 1 < starts.count {
                var nextStartCode = starts[idx + 1]
                if nextStartCode >= 4, bytes[nextStartCode - 4] == 0, bytes[nextStartCode - 3] == 0,
                   bytes[nextStartCode - 2] == 0, bytes[nextStartCode - 1] == 1 {
                    end = nextStartCode - 4
                } else {
                    end = nextStartCode - 3
                }
            } else {
                end = bytes.count
            }
            if begin < end {
                out.append(Data(bytes[begin..<end]))
            }
        }
        return out
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var out: CGImage?
        let st = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &out)
        if st == noErr, let out { return out }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }
}
