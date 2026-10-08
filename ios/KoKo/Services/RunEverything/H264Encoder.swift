import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Low-latency H.264 Annex-B encoder for phone-as-webcam experiments.
/// Realtime, no B-frames, Baseline. MJPEG path remains the fallback.
final class H264Encoder {
    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "koko.phonecam.h264")
    private var width = 0
    private var height = 0
    private var frameIndex: Int64 = 0
    private var framesSinceKey = 0
    private let keyInterval: Int
    private let bitrate: Int
    private var sps: Data?
    private var pps: Data?

    init(keyInterval: Int = 12, bitrate: Int = 900_000) {
        self.keyInterval = max(4, keyInterval)
        self.bitrate = max(200_000, bitrate)
    }

    deinit { invalidate() }

    func invalidate() {
        queue.sync {
            if let session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            session = nil
            width = 0
            height = 0
            sps = nil
            pps = nil
            frameIndex = 0
            framesSinceKey = 0
        }
    }

    /// Encode one BGRA/ARGB pixel buffer → Annex-B access unit.
    func encode(pixelBuffer: CVPixelBuffer, forceKey: Bool = false) -> (Data, Bool)? {
        queue.sync {
            encodeLocked(pixelBuffer: pixelBuffer, forceKey: forceKey)
        }
    }

    private func encodeLocked(pixelBuffer: CVPixelBuffer, forceKey: Bool) -> (Data, Bool)? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return nil }
        if session == nil || width != w || height != h {
            guard createSession(width: w, height: h) else { return nil }
        }
        guard let session else { return nil }

        let needKey = forceKey || framesSinceKey >= keyInterval || sps == nil
        framesSinceKey = needKey ? 0 : framesSinceKey + 1

        var props: CFDictionary?
        if needKey {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }

        var outData: Data?
        var outKey = false
        var outSPS: Data?
        var outPPS: Data?
        let sem = DispatchSemaphore(value: 0)
        let pts = CMTimeMake(value: frameIndex, timescale: 30)
        frameIndex += 1

        let callback: VTCompressionOutputHandler = { status, infoFlags, sample in
            defer { sem.signal() }
            _ = infoFlags
            guard status == noErr, let sample else { return }
            var isKey = needKey
            if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
               let first = arr.first {
                if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
                    isKey = !notSync
                }
            }
            outKey = isKey
            outData = Self.annexB(from: sample, includeParameterSets: isKey)
            if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
                var count = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
                )
                for i in 0..<count {
                    var ptr: UnsafePointer<UInt8>?
                    var size = 0
                    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                    ) == noErr, let ptr, size > 0 else { continue }
                    let d = Data(bytes: ptr, count: size)
                    if i == 0 { outSPS = d } else if i == 1 { outPPS = d }
                }
            }
        }

        let st = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: props,
            infoFlagsOut: nil,
            outputHandler: callback
        )
        guard st == noErr else { return nil }
        _ = sem.wait(timeout: .now() + 1.0)
        if let outSPS { sps = outSPS }
        if let outPPS { pps = outPPS }
        guard let data = outData, !data.isEmpty else { return nil }
        return (data, outKey)
    }

    private func createSession(width w: Int, height h: Int) -> Bool {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        width = w
        height = h
        sps = nil
        pps = nil

        var sess: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(w),
            height: Int32(h),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &sess
        )
        guard st == noErr, let sess else { return false }

        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 12 as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyInterval as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(sess)
        session = sess
        RE2Log.info("phonecam H264 encoder \(w)x\(h) bitrate=\(bitrate) keyEvery=\(keyInterval)")
        return true
    }

    private static func annexB(from sample: CMSampleBuffer, includeParameterSets: Bool) -> Data? {
        var out = Data()
        if includeParameterSets,
           let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt,
                    parameterSetIndex: i,
                    parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                ) == noErr, let ptr, size > 0 {
                    out.append(contentsOf: [0, 0, 0, 1])
                    out.append(ptr, count: size)
                }
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return out.isEmpty ? nil : out }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let dataPointer, totalLength > 4 else {
            return out.isEmpty ? nil : out
        }
        var offset = 0
        let bytes = UnsafeRawPointer(dataPointer).bindMemory(to: UInt8.self, capacity: totalLength)
        while offset + 4 <= totalLength {
            let nalLen = Int(bytes[offset]) << 24
                | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            offset += 4
            guard nalLen > 0, offset + nalLen <= totalLength else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(Data(bytes: bytes.advanced(by: offset), count: nalLen))
            offset += nalLen
        }
        return out.isEmpty ? nil : out
    }
}
