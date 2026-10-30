import AVFoundation
import Foundation
import QuartzCore

struct Sample: Encodable {
    let elapsed: Double
    let width: Double?
    let height: Double?
    let playhead: Double?
    let timeControlStatus: Int
    let waitingReason: String?
    let frameWidth: Int?
    let frameHeight: Int?
}

struct Access: Encodable {
    let indicatedBitrate: Double?
    let observedBitrate: Double?
    let downloadedBytes: Int64
}

struct Report: Encodable {
    let schema: Int
    let status: String
    let preferredWidth: Int
    let preferredHeight: Int
    let samples: [Sample]
    let access: [Access]
    let errorDomain: String?
    let errorCode: Int?
}

@main
struct Probe {
    static func known(_ value: Double) -> Double? { value.isFinite && value >= 0 ? value : nil }

    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 5, let url = URL(string: args[1]), url.scheme == "http", url.host == "127.0.0.1",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let width = Int(args[2]), let height = Int(args[3]),
              (0...4096).contains(width), (0...4096).contains(height),
              (width == 0) == (height == 0), let duration = Double(args[4]), duration.isFinite,
              (1...15).contains(duration) else { exit(2) }
        let item = AVPlayerItem(url: url)
        item.preferredMaximumResolution = CGSize(width: width, height: height)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.isMuted = true
        player.volume = 0
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let started = ContinuousClock.now
        player.play()
        var samples: [Sample] = []
        while ContinuousClock.now - started < .seconds(duration) {
            let elapsed = ContinuousClock.now - started
            let parts = elapsed.components
            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            let frame = output.hasNewPixelBuffer(forItemTime: itemTime)
                ? output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) : nil
            samples.append(Sample(elapsed: Double(parts.seconds) + Double(parts.attoseconds) / 1e18,
                width: known(item.presentationSize.width), height: known(item.presentationSize.height),
                playhead: known(player.currentTime().seconds), timeControlStatus: player.timeControlStatus.rawValue,
                waitingReason: player.reasonForWaitingToPlay?.rawValue,
                frameWidth: frame.map(CVPixelBufferGetWidth), frameHeight: frame.map(CVPixelBufferGetHeight)))
            if item.status == .failed { break }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
        }
        let advanced = samples.contains { ($0.playhead ?? 0) > 0 && ($0.width ?? 0) > 0 && ($0.height ?? 0) > 0 && ($0.frameWidth ?? 0) > 0 && ($0.frameHeight ?? 0) > 0 }
        let error = item.error as NSError?
        let report = Report(schema: 1, status: item.status != .failed && advanced ? "observed" : "unavailable",
            preferredWidth: width, preferredHeight: height, samples: samples,
            access: (item.accessLog()?.events ?? []).map {
                Access(indicatedBitrate: known($0.indicatedBitrate), observedBitrate: known($0.observedBitrate),
                       downloadedBytes: $0.numberOfBytesTransferred)
            }, errorDomain: error?.domain, errorCode: error?.code)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(report)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        } catch { exit(2) }
        // Scope cleanup runs on normal return; the parent evaluates status.
    }
}
