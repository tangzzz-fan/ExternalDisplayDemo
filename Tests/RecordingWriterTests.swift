import AVFoundation
import XCTest

@testable import ExternalDisplayDemo

final class RecordingWriterTests: XCTestCase {

    func testFinishProducesPlayableVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writer-test.mp4")
        let writer = RecordingWriter(url: url)

        for index in 0..<45 {
            writer.append(try Self.sampleBuffer(frame: index), type: .video)
        }

        let output = try await writer.finish()

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)

        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), Self.width)
        XCTAssertEqual(Int(size.height), Self.height)

        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 1.0)
        XCTAssertLessThan(duration.seconds, 2.0)
    }

    func testFinishWithoutSamplesFails() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writer-empty.mp4")
        let writer = RecordingWriter(url: url)

        do {
            _ = try await writer.finish()
            XCTFail("空录制应当抛错")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testCancelRemovesFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writer-cancel.mp4")
        let writer = RecordingWriter(url: url)
        writer.append(try Self.sampleBuffer(frame: 0), type: .video)

        writer.cancel()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAudioAndVideoStartTogether() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writer-av.mp4")
        let writer = RecordingWriter(url: url)

        let videoFrames = Int(Double(Self.fps) * 2)
        let audioChunks = Int(Double(Self.sampleRate) * 2) / Self.framesPerAudioChunk

        var videoIndex = 0
        var audioIndex = 0

        while videoIndex < videoFrames || audioIndex < audioChunks {
            let videoTime = Double(videoIndex) / Double(Self.fps)
            let audioTime = Double(audioIndex * Self.framesPerAudioChunk) / Double(Self.sampleRate)

            if videoIndex < videoFrames, audioIndex >= audioChunks || videoTime <= audioTime {
                writer.append(try Self.sampleBuffer(frame: videoIndex), type: .video)
                videoIndex += 1
            } else {
                writer.append(try Self.audioSampleBuffer(chunk: audioIndex), type: .audioApp)
                audioIndex += 1
            }
        }

        let output = try await writer.finish()
        let asset = AVURLAsset(url: output)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)

        let videoStart = try await XCTUnwrap(videoTracks.first).load(.timeRange).start.seconds
        let audioStart = try await XCTUnwrap(audioTracks.first).load(.timeRange).start.seconds
        XCTAssertEqual(videoStart, audioStart, accuracy: 0.05)

        let videoDuration = try await XCTUnwrap(videoTracks.first).load(.timeRange).duration.seconds
        let audioDuration = try await XCTUnwrap(audioTracks.first).load(.timeRange).duration.seconds
        XCTAssertEqual(videoDuration, audioDuration, accuracy: 0.1)
    }

    func testAudioSurvivesWriter() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("writer-tone.mp4")
        let writer = RecordingWriter(url: url)

        let videoFrames = Int(Self.fps)
        let audioChunks = Int(Self.sampleRate) / Self.framesPerAudioChunk

        var videoIndex = 0
        var audioIndex = 0

        while videoIndex < videoFrames || audioIndex < audioChunks {
            let videoTime = Double(videoIndex) / Double(Self.fps)
            let audioTime = Double(audioIndex * Self.framesPerAudioChunk) / Double(Self.sampleRate)

            if videoIndex < videoFrames, audioIndex >= audioChunks || videoTime <= audioTime {
                writer.append(try Self.sampleBuffer(frame: videoIndex), type: .video)
                videoIndex += 1
            } else {
                writer.append(try Self.audioSampleBuffer(chunk: audioIndex), type: .audioApp)
                audioIndex += 1
            }
        }

        let output = try await writer.finish()
        let peak = try await Self.peakAmplitude(of: output)

        XCTAssertGreaterThan(peak, 0.05, "音轨被写成了静音")
    }

    private static let width = 320
    private static let height = 240
    private static let fps: Int32 = 30
    private static let sampleRate: Int32 = 48_000
    private static let framesPerAudioChunk = 1024
    private static let bytesPerAudioFrame = 4

    private static func audioSampleBuffer(chunk: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerAudioFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerAudioFrame),
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var format: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        XCTAssertEqual(formatStatus, noErr)
        let formatDescription = try XCTUnwrap(format)

        let byteCount = framesPerAudioChunk * bytesPerAudioFrame
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        XCTAssertEqual(blockStatus, noErr)
        let block = try XCTUnwrap(blockBuffer)

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        if let dataPointer {
            let samples = UnsafeMutableRawPointer(dataPointer)
                .bindMemory(to: Int16.self, capacity: framesPerAudioChunk * 2)
            for frame in 0..<framesPerAudioChunk {
                let value = Int16(12_000 * sin(2 * Double.pi * 440 * Double(frame) / Double(sampleRate)))
                samples[frame * 2] = value
                samples[frame * 2 + 1] = value
            }
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: CMTimeValue(chunk * framesPerAudioChunk), timescale: sampleRate),
            decodeTimeStamp: .invalid
        )

        var sampleSize = bytesPerAudioFrame
        var sampleBuffer: CMSampleBuffer?
        let bufferStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: framesPerAudioChunk,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(bufferStatus, noErr)
        return try XCTUnwrap(sampleBuffer)
    }

    private static func peakAmplitude(of url: URL) async throws -> Float {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        reader.startReading()

        var peak: Float = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }

            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            )
            guard let pointer, length > 0 else { continue }

            let count = length / MemoryLayout<Float>.size
            let samples = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: count)
            for index in 0..<count {
                peak = max(peak, abs(samples[index]))
            }
        }

        return peak
    }

    private static func sampleBuffer(frame: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw RecordingWriter.Failure.noVideoSample
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, Int32(frame * 5 % 250), CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        )
        let formatDescription = try XCTUnwrap(format)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: fps),
            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: fps),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        return try XCTUnwrap(sampleBuffer)
    }
}
