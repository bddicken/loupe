import AVFoundation
import ScreenCaptureKit

/// What to record and how. Built on the main actor, then handed to the recorder.
struct RecordingConfiguration {
    let display: SCDisplay
    let filter: SCContentFilter
    /// The recorded region in display-local points, top-left origin (ScreenCaptureKit's convention).
    let sourceRect: CGRect
    /// Output size in pixels (even, and within H.264's limits).
    let pixelSize: CGSize
    let framesPerSecond: Int
    let showsCursor: Bool
    let capturesSystemAudio: Bool
    let microphone: AVCaptureDevice?
}

/// Streams a display region with ScreenCaptureKit (plus an optional
/// microphone) into an H.264 MP4. All sample handling happens on one serial queue.
final class ScreenRecorder: NSObject, @unchecked Sendable {
    let outputURL: URL
    private let configuration: RecordingConfiguration
    private let queue = DispatchQueue(label: "dev.loupe.recorder")
    private var stream: SCStream?
    private var micSession: AVCaptureSession?
    private let writer: RecordingWriter
    /// Called (on the main queue) if the stream stops on its own, e.g. the
    /// user ends sharing from the system's menu bar indicator, or if the
    /// file stops being written (e.g. the disk is full).
    var onStreamError: (@MainActor (Error) -> Void)?
    private var reportedWriterFailure = false

    init(configuration: RecordingConfiguration, outputURL: URL) throws {
        self.configuration = configuration
        self.outputURL = outputURL
        writer = try RecordingWriter(
            url: outputURL,
            pixelSize: configuration.pixelSize,
            framesPerSecond: configuration.framesPerSecond,
            systemAudio: configuration.capturesSystemAudio,
            microphone: configuration.microphone != nil
        )
        super.init()
    }

    func start() async throws {
        let config = SCStreamConfiguration()
        config.sourceRect = configuration.sourceRect
        config.width = Int(configuration.pixelSize.width)
        config.height = Int(configuration.pixelSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))
        config.showsCursor = configuration.showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6
        config.capturesAudio = configuration.capturesSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        do {
            let stream = SCStream(filter: configuration.filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if configuration.capturesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            }
            self.stream = stream

            if let device = configuration.microphone {
                startMicrophone(device)
            }
            try await stream.startCapture()
        } catch {
            // Don't leave the microphone running or an empty file behind.
            stream = nil
            await cancel()
            throw error
        }
    }

    private func startMicrophone(_ device: AVCaptureDevice) {
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        // Ask for 48 kHz mono float so the writer never has to guess the format.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        session.startRunning()
        micSession = session
    }

    /// Changes which windows are recorded, mid-recording.
    func updateFilter(_ filter: SCContentFilter) async throws {
        try await stream?.updateContentFilter(filter)
    }

    /// Stops capturing and finalizes the file. Returns the movie's duration in seconds.
    func stop() async throws -> Double {
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        try? await stream?.stopCapture()
        stream = nil
        micSession?.stopRunning()
        micSession = nil
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.writer.finish(at: end) { result in continuation.resume(with: result) }
            }
        }
    }

    /// Stops capturing and deletes whatever was written.
    func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
        micSession?.stopRunning()
        micSession = nil
        await withCheckedContinuation { continuation in
            queue.async {
                self.writer.cancel()
                try? FileManager.default.removeItem(at: self.outputURL)
                continuation.resume()
            }
        }
    }
}

extension ScreenRecorder: SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // Idle frames (nothing changed on screen) carry no image.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete else { return }
            writer.appendVideo(sampleBuffer)
        case .audio:
            writer.appendAudio(sampleBuffer, source: .system)
        default:
            break
        }
        reportWriterFailure()
    }

    /// Runs on `queue`: tells the controller as soon as the file can't be written.
    private func reportWriterFailure() {
        guard !reportedWriterFailure, let error = writer.failure else { return }
        reportedWriterFailure = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onStreamError?(error) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onStreamError?(error) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        writer.appendAudio(sampleBuffer, source: .microphone)
        reportWriterFailure()
    }
}

/// Wraps AVAssetWriter: starts the session on the first video frame. Only
/// used on the recorder's queue.
private final class RecordingWriter {
    enum AudioSource { case system, microphone }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?

    private var sessionStart: CMTime?
    private var lastVideoTime = CMTime.invalid
    private var lastAudioTime: [ObjectIdentifier: CMTime] = [:]
    private var isFinished = false

    /// Set once the writer has failed (disk full, encoder error); nothing more will be written.
    var failure: Error? {
        guard !isFinished, writer.status == .failed else { return nil }
        return writer.error ?? CocoaError(.fileWriteUnknown)
    }

    init(url: URL, pixelSize: CGSize, framesPerSecond: Int, systemAudio: Bool, microphone: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let pixels = pixelSize.width * pixelSize.height
        let bitRate = min(max(pixels * Double(framesPerSecond) * 0.12, 2_000_000), 40_000_000)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelSize.width,
            AVVideoHeightKey: pixelSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        func audioInput(channels: Int) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        systemAudioInput = systemAudio ? audioInput(channels: 2) : nil
        microphoneInput = microphone ? audioInput(channels: 1) : nil
        for input in [systemAudioInput, microphoneInput].compactMap({ $0 }) where writer.canAdd(input) {
            writer.add(input)
        }

        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinished, writer.status == .writing else { return }
        let time = sampleBuffer.presentationTimeStamp
        if sessionStart == nil {
            writer.startSession(atSourceTime: time)
            sessionStart = time
        }
        if lastVideoTime.isValid, time <= lastVideoTime { return }
        guard videoInput.isReadyForMoreMediaData else { return }
        if videoInput.append(sampleBuffer) {
            lastVideoTime = time
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer, source: AudioSource) {
        guard !isFinished, writer.status == .writing, let start = sessionStart else { return }
        guard let input = source == .system ? systemAudioInput : microphoneInput else { return }
        let time = sampleBuffer.presentationTimeStamp
        // Audio from before the first frame would make the movie start with a black frame.
        guard time >= start else { return }
        let key = ObjectIdentifier(input)
        if let last = lastAudioTime[key], time <= last { return }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(sampleBuffer) {
            lastAudioTime[key] = time
        }
    }

    func finish(at hostTime: CMTime, completion: @escaping (Result<Double, Error>) -> Void) {
        guard !isFinished else { return }
        isFinished = true
        guard let start = sessionStart, writer.status == .writing else {
            writer.cancelWriting()
            completion(.failure(writer.error ?? RecordingError.noFrames))
            return
        }
        // Hold the last frame until the moment Stop was pressed.
        let end = max(hostTime, lastVideoTime + CMTime(value: 1, timescale: 60))
        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        writer.endSession(atSourceTime: end)
        writer.finishWriting { [writer] in
            if writer.status == .completed {
                completion(.success((end - start).seconds))
            } else {
                completion(.failure(writer.error ?? CocoaError(.fileWriteUnknown)))
            }
        }
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        writer.cancelWriting()
    }
}

enum RecordingError: LocalizedError {
    case noFrames
    case displayUnavailable

    var errorDescription: String? {
        switch self {
        case .noFrames: "Nothing was recorded."
        case .displayUnavailable: "That display is no longer available."
        }
    }
}
