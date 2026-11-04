import AVFoundation
import LittleSurfaceCore
import Metal
import UIKit

enum TimelapseExportError: LocalizedError {
    case nothingRecorded
    case cannotDraw
    case interrupted
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .nothingRecorded: return "There's nothing to replay yet."
        case .cannotDraw: return "The video frames couldn't be drawn on this device."
        case .interrupted: return "It stopped because the app left the screen. Stay in the app until it's done."
        case .cannotWrite(let reason): return reason
        }
    }
}

/// Turns the recorded steps into a video. Runs on whichever background thread calls it, with a
/// renderer of its own, so the project stays editable meanwhile.
enum TimelapseExporter {
    static let pixelSize = 1080

    static func export(_ snapshot: ProjectSnapshot, device: MTLDevice, to url: URL, progress: @escaping (Double) -> Void) throws {
        let frames = snapshot.timelapse
        guard !frames.isEmpty else { throw TimelapseExportError.nothingRecorded }
        guard let renderer = ViewportRenderer(device: device),
              let target = renderer.makeOffscreenTarget(width: pixelSize, height: pixelSize) else { throw TimelapseExportError.cannotDraw }

        let replay = RetopoEngine.forReplay(of: snapshot)
        // The whole model stays in frame, along with anything built out past it.
        var bounds = AABB.empty
        for source in snapshot.sources where source.isVisible {
            for p in source.positions { bounds.grow(p) }
        }
        if let last = try? frames[frames.count - 1].decoded(), !last.mesh.isEmpty { bounds.grow(last.mesh.bounds) }
        replay.replayBounds = bounds
        // Twice the size in pixels as in points, so lines come out as they do on an iPad's screen.
        let viewSize = Vec2(repeating: Float(pixelSize) / 2)
        let shots = TimelapseDirector.shots(for: frames, bounds: bounds, camera: snapshot.camera.applied(to: Camera()), viewSize: viewSize)

        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw TimelapseExportError.cannotWrite(error.localizedDescription)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelSize,
            AVVideoHeightKey: pixelSize,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: pixelSize,
            kCVPixelBufferHeightKey as String: pixelSize,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw TimelapseExportError.cannotWrite(writer.error?.localizedDescription ?? "The video file couldn't be started.")
        }
        writer.startSession(atSourceTime: .zero)

        func abandon() {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
        }

        let badge = makeBadge()
        var shown: Int?
        var reported = -1
        for (i, shot) in shots.enumerated() {
            do {
                try autoreleasepool {
                    try Task.checkCancellation()
                    if shot.frameIndex != shown {
                        shown = shot.frameIndex
                        if shot.frameIndex < 0 {
                            replay.showForReplay(mesh: Mesh(), sketches: [])
                        } else {
                            let frame = try frames[shot.frameIndex].decoded()
                            replay.showForReplay(mesh: frame.mesh, sketches: frame.sketches)
                        }
                    }
                    guard renderer.renderOffscreen(engine: replay, camera: shot.camera, into: target) else { throw TimelapseExportError.interrupted }
                    while !input.isReadyForMoreMediaData {
                        if writer.status != .writing { throw TimelapseExportError.interrupted }
                        try Task.checkCancellation()
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    guard let pool = adaptor.pixelBufferPool else { throw TimelapseExportError.interrupted }
                    var made: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
                    guard let buffer = made else { throw TimelapseExportError.cannotDraw }
                    compose(target, badge: badge, into: buffer)
                    let time = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(TimelapseDirector.framesPerSecond))
                    guard adaptor.append(buffer, withPresentationTime: time) else { throw TimelapseExportError.interrupted }
                }
            } catch {
                abandon()
                throw error
            }
            let percent = (i + 1) * 100 / shots.count
            if percent / 5 != reported {
                reported = percent / 5
                progress(Double(percent) / 100)
            }
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            let reason = writer.error?.localizedDescription ?? "The video couldn't be finished."
            abandon()
            throw TimelapseExportError.cannotWrite(reason)
        }
    }

    private static func compose(_ target: ViewportRenderer.OffscreenTarget, badge: CGImage?, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<target.height {
            memcpy(base + row * rowBytes, target.pixels.contents() + row * target.bytesPerRow, target.bytesPerRow)
        }
        guard let badge,
              let context = CGContext(data: base, width: target.width, height: target.height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.draw(badge, in: CGRect(x: 36, y: 36, width: badge.width, height: badge.height))
    }

    /// The logo and the name, on a pill that reads against any model.
    private static func makeBadge() -> CGImage? {
        let name = NSAttributedString(string: "Little Surface", attributes: [
            .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
            .foregroundColor: UIColor(white: 0.1, alpha: 1),
        ])
        let textSize = name.size()
        let logoSize: CGFloat = 60, inset: CGFloat = 12
        let size = CGSize(width: inset + logoSize + 16 + ceil(textSize.width) + 28, height: logoSize + inset * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(white: 1, alpha: 0.9).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2).fill()
            let logoRect = CGRect(x: inset, y: inset, width: logoSize, height: logoSize)
            UIBezierPath(roundedRect: logoRect, cornerRadius: logoSize * 0.225).addClip()
            UIImage(named: "Logo")?.draw(in: logoRect)
            UIGraphicsGetCurrentContext()?.resetClip()
            name.draw(at: CGPoint(x: inset + logoSize + 16, y: (size.height - textSize.height) / 2))
        }
        return image.cgImage
    }
}
