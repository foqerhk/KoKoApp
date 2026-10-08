import Foundation
import AVFoundation
import Opus

/// Plays remote AUDIO: pcm16 or Opus (raw packet / Ogg-Opus from Agent ffmpeg).
final class RE2AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var sampleRate: Double = 48000
    private var channels: AVAudioChannelCount = 1
    private var started = false
    private let queue = DispatchQueue(label: "re2.audio")
    private var opusDecoder: Opus.Decoder?
    private var ogg = OggOpusDemuxer()
    /// When true, decode is skipped (saves CPU on cellular).
    var isMuted = false

    func stop() {
        queue.sync {
            player.stop()
            engine.stop()
            started = false
            opusDecoder = nil
            ogg.reset()
        }
    }

    func play(codec: String, sampleRate: Int, channels: Int, data: Data) {
        guard !isMuted else { return }
        queue.async {
            let sr = sampleRate > 0 ? Double(sampleRate) : Double.opus48khz
            let ch = AVAudioChannelCount(max(1, channels > 0 ? channels : 1))
            if codec.lowercased() == "opus" {
                self.playOpus(data, sampleRate: sr, channels: ch)
            } else {
                self.enqueuePCM16(data, sampleRate: sr, channels: ch)
            }
        }
    }

    private func playOpus(_ data: Data, sampleRate: Double, channels: AVAudioChannelCount) {
        do {
            try ensureOpusDecoder(sampleRate: sampleRate, channels: channels)
            let packets: [Data]
            if data.starts(with: [0x4F, 0x67, 0x67, 0x53]) || ogg.isActive {
                packets = ogg.push(data)
            } else {
                packets = [data]
            }
            guard let decoder = opusDecoder else { return }
            for packet in packets {
                if packet.isEmpty { continue }
                if packet.starts(with: Data("OpusHead".utf8)) || packet.starts(with: Data("OpusTags".utf8)) {
                    continue
                }
                let buf = try decoder.decode(packet)
                enqueuePCMBuffer(buf)
            }
        } catch {
            // Drop undecodable frames.
        }
    }

    private func ensureOpusDecoder(sampleRate: Double, channels: AVAudioChannelCount) throws {
        if opusDecoder != nil, abs(self.sampleRate - sampleRate) < 1, self.channels == channels { return }
        let rate: Double
        switch Int(sampleRate) {
        case 8000: rate = .opus8khz
        case 12000: rate = .opus12khz
        case 16000: rate = .opus16khz
        case 24000: rate = .opus24khz
        default: rate = .opus48khz
        }
        guard let format = AVAudioFormat(opusPCMFormat: .int16, sampleRate: rate, channels: channels) else {
            throw RE2Error.signaling("bad opus format")
        }
        opusDecoder = try Opus.Decoder(format: format)
        self.sampleRate = rate
        self.channels = channels
        try ensureEngine(sampleRate: rate, channels: channels, format: format)
    }

    private func enqueuePCM16(_ data: Data, sampleRate: Double, channels: AVAudioChannelCount) {
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channels, interleaved: true)!
            try ensureEngine(sampleRate: sampleRate, channels: channels, format: format)
            let frameCount = AVAudioFrameCount(data.count / (2 * Int(channels)))
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
            else { return }
            buffer.frameLength = frameCount
            data.withUnsafeBytes { raw in
                guard let src = raw.baseAddress, let dst = buffer.int16ChannelData?[0] else { return }
                memcpy(dst, src, data.count)
            }
            enqueuePCMBuffer(buffer)
        } catch {}
    }

    private func enqueuePCMBuffer(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func ensureEngine(sampleRate: Double, channels: AVAudioChannelCount, format: AVAudioFormat) throws {
        if started, abs(self.sampleRate - sampleRate) < 1, self.channels == channels { return }
        if started {
            player.stop()
            engine.stop()
            if engine.attachedNodes.contains(player) {
                engine.disconnectNodeOutput(player)
            }
            started = false
        }
        self.sampleRate = sampleRate
        self.channels = channels
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
        started = true
    }
}

/// Minimal Ogg page demuxer for Agent ffmpeg `-f opus` streams.
final class OggOpusDemuxer {
    private var buffer = Data()
    private var pending = Data()
    private(set) var isActive = false

    func reset() {
        buffer.removeAll(keepingCapacity: false)
        pending.removeAll(keepingCapacity: false)
        isActive = false
    }

    func push(_ chunk: Data) -> [Data] {
        if chunk.starts(with: [0x4F, 0x67, 0x67, 0x53]) { isActive = true }
        buffer.append(chunk)
        var packets: [Data] = []
        while let pagePackets = popPage() {
            packets.append(contentsOf: pagePackets)
        }
        return packets
    }

    private func popPage() -> [Data]? {
        guard let start = buffer.range(of: Data([0x4F, 0x67, 0x67, 0x53]))?.lowerBound else {
            if buffer.count > 64 * 1024 { buffer.removeAll(keepingCapacity: true) }
            return nil
        }
        if start > 0 { buffer.removeSubrange(0..<start) }
        guard buffer.count >= 27 else { return nil }
        let nseg = Int(buffer[26])
        guard buffer.count >= 27 + nseg else { return nil }
        var bodyLen = 0
        for i in 0..<nseg { bodyLen += Int(buffer[27 + i]) }
        let headerLen = 27 + nseg
        let total = headerLen + bodyLen
        guard buffer.count >= total else { return nil }

        let segs = [UInt8](buffer.subdata(in: 27..<(27 + nseg)))
        let body = buffer.subdata(in: headerLen..<total)
        buffer.removeSubrange(0..<total)

        var out: [Data] = []
        var packet = pending
        pending = Data()
        var offset = 0
        for l in segs {
            let len = Int(l)
            packet.append(body.subdata(in: offset..<(offset + len)))
            offset += len
            if len < 255 {
                if !packet.isEmpty { out.append(packet) }
                packet = Data()
            }
        }
        if !packet.isEmpty {
            pending = packet
        }
        return out
    }
}
