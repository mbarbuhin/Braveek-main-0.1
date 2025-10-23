import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreAudio

@available(macOS 13.0, *)
class DualAudioRecorder: NSObject {
    // MARK: - Properties
    
    private var stream: SCStream?
    private var microphoneEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var systemAudioFile: AVAudioFile?

    private var isRecording = false
    private var recordingStartTime: Date?

    private let outputDirectory: URL
    private let queue = DispatchQueue(label: "com.meetingrecorder.audio", qos: .userInitiated)

    var onRecordingStopped: (() -> Void)?

    // MARK: - Init

    override init() {
        self.outputDirectory = AppPaths.shared.recordingsDirectory

        super.init()

        print("🎙️  DualAudioRecorder инициализирован")
        print("📁 Записи сохраняются: \(outputDirectory.path)")
    }
    
    // MARK: - Public Methods
    
    func startRecording() async throws {
        guard !isRecording else {
            print("⚠️  Запись уже идёт")
            return
        }
        
        print("\n🎬 Начинаем запись...")
        
        // 1. Настраиваем микрофон
        try setupMicrophone()
        
        // 2. Получаем доступные источники аудио
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        
        // 3. Настраиваем конфигурацию для системного аудио
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        
        // Создаём фильтр (захватываем всё системное аудио)
        let filter = SCContentFilter(display: content.displays.first!, excludingWindows: [])
        
        // 4. Создаём поток для системного аудио
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        
        // 5. Создаём файлы для записи
        try createAudioFiles()
        
        // 6. Добавляем вывод аудио
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        
        // 7. Запускаем поток системного аудио
        try await stream?.startCapture()
        
        // 8. Запускаем микрофон
        try microphoneEngine?.start()
        
        isRecording = true
        recordingStartTime = Date()
        
        print("✅ Запись началась!")
        print("   📺 Системный звук: захватывается")
        print("   🎤 Микрофон: активен")
    }
    
    func stopRecording() {
        guard isRecording else {
            print("⚠️  Запись не активна")
            return
        }
        
        print("\n⏹️  Останавливаем запись...")
        
        Task {
            try? await stream?.stopCapture()
            stream = nil
        }
        
        microphoneEngine?.stop()
        microphoneEngine?.inputNode.removeTap(onBus: 0)
        microphoneEngine = nil
        
        if let startTime = recordingStartTime {
            let duration = Date().timeIntervalSince(startTime)
            print("⏱️  Длительность: \(formatDuration(duration))")
        }
        
        if let audioFile = audioFile {
            let filename = audioFile.url.lastPathComponent
            let fileSize = getFileSize(audioFile.url)
            print("✅ Микрофон сохранён: \(filename)")
            print("   Размер: \(fileSize)")
        }
        
        if let systemFile = systemAudioFile {
            let filename = systemFile.url.lastPathComponent
            let fileSize = getFileSize(systemFile.url)
            print("✅ Системное аудио сохранено: \(filename)")
            print("   Размер: \(fileSize)")
        }
        
        print("📂 Папка: \(outputDirectory.path)")
        
        isRecording = false
        audioFile = nil
        systemAudioFile = nil
        recordingStartTime = nil
        
        onRecordingStopped?()
    }
    
    // MARK: - Private Methods
    
    private func setupMicrophone() throws {
        microphoneEngine = AVAudioEngine()
        guard let engine = microphoneEngine else { return }
        
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        print("🎤 Микрофон: \(format.sampleRate)Hz, \(format.channelCount) каналов")
        
        // Устанавливаем tap для записи микрофона
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.writeMicrophoneBuffer(buffer)
        }
    }
    
    private func writeMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let file = audioFile else { return }
        
        queue.async {
            do {
                try file.write(from: buffer)
            } catch {
                print("❌ Ошибка записи микрофона: \(error.localizedDescription)")
            }
        }
    }
    
    private func writeSystemAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecording, let file = systemAudioFile else { return }
        
        queue.async {
            do {
                try file.write(from: buffer)
            } catch {
                print("❌ Ошибка записи системного аудио: \(error.localizedDescription)")
            }
        }
    }
    
    private func createAudioFiles() throws {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .prefix(19)
    
        // Используем формат микрофона
        guard let micFormat = microphoneEngine?.inputNode.outputFormat(forBus: 0) else {
            throw NSError(domain: "DualAudioRecorder", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Не получен формат микрофона"])
        }

        // Файл для микрофона
        let micFilename = "microphone_\(timestamp).wav"
        let micURL = outputDirectory.appendingPathComponent(micFilename)
        audioFile = try AVAudioFile(forWriting: micURL, settings: micFormat.settings)
        print("📝 Создан файл микрофона: \(micFilename)")

        // Файл для системного аудио (стерео)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    
        let sysFilename = "system_\(timestamp).wav"
        let sysURL = outputDirectory.appendingPathComponent(sysFilename)
        systemAudioFile = try AVAudioFile(forWriting: sysURL, settings: settings)
        print("📝 Создан файл системы: \(sysFilename)")
    }
    
    private func getFileSize(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            return "unknown"
        }
        
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    deinit {
        if isRecording {
            stopRecording()
        }
    }
}

// MARK: - SCStreamDelegate

@available(macOS 13.0, *)
extension DualAudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("❌ Поток остановлен с ошибкой: \(error.localizedDescription)")
        stopRecording()
    }
}

// MARK: - SCStreamOutput

@available(macOS 13.0, *)
extension DualAudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isRecording, type == .audio else { return }
        
        // Конвертируем CMSampleBuffer в AVAudioPCMBuffer
        guard let audioBuffer = createPCMBuffer(from: sampleBuffer) else { return }
        
        writeSystemAudioBuffer(audioBuffer)
    }
    
    private func createPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        
        let format = AVAudioFormat(streamDescription: audioStreamBasicDescription)!
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        
        buffer.frameLength = AVAudioFrameCount(frameCount)
        
        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        
        return buffer
    }
}
