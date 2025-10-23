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
    private var currentRecordingBaseName: String?

    private let microphoneDirectory: URL
    private let systemDirectory: URL
    private let mixDirectory: URL
    private let queue = DispatchQueue(label: "com.meetingrecorder.audio", qos: .userInitiated)

    var onRecordingStopped: (() -> Void)?

    // MARK: - Init

    override init() {
        let paths = AppPaths.shared
        self.microphoneDirectory = paths.microphoneRecordingsDirectory
        self.systemDirectory = paths.systemRecordingsDirectory
        self.mixDirectory = paths.mixedRecordingsDirectory

        super.init()

        print("🎙️  DualAudioRecorder инициализирован")
        print("📁 Папки сохранения:")
        print("   🎤 Микрофон: \(microphoneDirectory.path)")
        print("   💻 Система: \(systemDirectory.path)")
        print("   🎧 Миксы: \(mixDirectory.path)")
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

        let microphoneURL = audioFile?.url
        let systemURL = systemAudioFile?.url
        let baseName = currentRecordingBaseName

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

        print("📂 Папки назначения:")
        print("   🎤 \(microphoneDirectory.lastPathComponent): \(microphoneDirectory.path)")
        print("   💻 \(systemDirectory.lastPathComponent): \(systemDirectory.path)")
        print("   🎧 \(mixDirectory.lastPathComponent): \(mixDirectory.path)")

        if let microphoneURL, let systemURL, let baseName {
            print("🎚️ Подготавливаем сведение и загрузку для \(baseName)...")
            Task.detached { [weak self] in
                await self?.mixDownRecordings(
                    microphoneURL: microphoneURL,
                    systemURL: systemURL,
                    baseName: baseName
                )
            }
        }

        isRecording = false
        audioFile = nil
        systemAudioFile = nil
        recordingStartTime = nil
        currentRecordingBaseName = nil

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
        let baseName = String(timestamp)
        currentRecordingBaseName = baseName

        // Используем формат микрофона
        guard let micFormat = microphoneEngine?.inputNode.outputFormat(forBus: 0) else {
            throw NSError(domain: "DualAudioRecorder", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Не получен формат микрофона"])
        }

        // Файл для микрофона
        let micFilename = "microphone_\(baseName).wav"
        let micURL = microphoneDirectory.appendingPathComponent(micFilename)
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

        let sysFilename = "system_\(baseName).wav"
        let sysURL = systemDirectory.appendingPathComponent(sysFilename)
        systemAudioFile = try AVAudioFile(forWriting: sysURL, settings: settings)
        print("📝 Создан файл системы: \(sysFilename)")
    }

    private func mixDownRecordings(microphoneURL: URL, systemURL: URL, baseName: String) async {
        print("🎚️ Сведение дорожек для \(baseName) запущено...")
        do {
            let outputURL = try await mixAudioFiles(
                microphoneURL: microphoneURL,
                systemURL: systemURL,
                baseName: baseName
            )
            let fileSize = getFileSize(outputURL)
            print("🎧 Сведение завершено: \(outputURL.lastPathComponent)")
            print("   Размер: \(fileSize)")
            print("   Путь: \(outputURL.path)")
            print("☁️ Отправка микса в Supabase (если настроено)...")

            Task.detached(priority: .background) {
                do {
                    try await SupabaseUploader.shared.uploadMix(at: outputURL, baseName: baseName)
                    print("📤 Supabase: микс \(outputURL.lastPathComponent) отправлен")
                } catch {
                    print("⚠️ Supabase: не удалось загрузить \(outputURL.lastPathComponent): \(error.localizedDescription)")
                    print("   Продолжаем работу офлайн, файл доступен локально.")
                }
            }
        } catch {
            print("❌ Ошибка сведения дорожек: \(error.localizedDescription)")
        }
    }

    private func mixAudioFiles(microphoneURL: URL, systemURL: URL, baseName: String) async throws -> URL {
        let outputURL = mixDirectory.appendingPathComponent("mix_\(baseName).m4a")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()

        let microphoneAsset = AVURLAsset(url: microphoneURL)
        let systemAsset = AVURLAsset(url: systemURL)

        let microphoneTrack = try await loadAudioTrack(from: microphoneAsset)
        let systemTrack = try await loadAudioTrack(from: systemAsset)

        guard let microphoneCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let systemCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(
                domain: "DualAudioRecorder",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось создать дорожки для сведения"]
            )
        }

        let microphoneDuration = try await loadDuration(for: microphoneAsset)
        let systemDuration = try await loadDuration(for: systemAsset)

        try microphoneCompositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: microphoneDuration),
            of: microphoneTrack,
            at: .zero
        )

        try systemCompositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: systemDuration),
            of: systemTrack,
            at: .zero
        )

        let audioMix = AVMutableAudioMix()
        let microphoneParameters = AVMutableAudioMixInputParameters(track: microphoneCompositionTrack)
        microphoneParameters.setVolume(1.0, at: .zero)
        let systemParameters = AVMutableAudioMixInputParameters(track: systemCompositionTrack)
        systemParameters.setVolume(1.0, at: .zero)
        audioMix.inputParameters = [microphoneParameters, systemParameters]

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(
                domain: "DualAudioRecorder",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось создать экспортёр для сведения"]
            )
        }

        exporter.audioMix = audioMix
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a

        let maxDuration = CMTimeMaximum(microphoneDuration, systemDuration)
        if maxDuration.isNumeric && maxDuration.isValid && !maxDuration.isIndefinite {
            exporter.timeRange = CMTimeRange(start: .zero, duration: maxDuration)
        }

        try await export(exporter)
        return outputURL
    }

    private func loadAudioTrack(from asset: AVURLAsset) async throws -> AVAssetTrack {
        try await withCheckedThrowingContinuation { continuation in
            asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
                var error: NSError?
                let status = asset.statusOfValue(forKey: "tracks", error: &error)
                switch status {
                case .loaded:
                    if let track = asset.tracks(withMediaType: .audio).first {
                        continuation.resume(returning: track)
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "DualAudioRecorder",
                            code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "Аудиодорожка отсутствует"]
                        ))
                    }
                case .failed:
                    continuation.resume(throwing: error ?? NSError(
                        domain: "DualAudioRecorder",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Не удалось загрузить дорожку"]
                    ))
                case .cancelled:
                    continuation.resume(throwing: NSError(
                        domain: "DualAudioRecorder",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "Загрузка дорожки отменена"]
                    ))
                default:
                    continuation.resume(throwing: NSError(
                        domain: "DualAudioRecorder",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "Неизвестный статус загрузки дорожки"]
                    ))
                }
            }
        }
    }

    private func loadDuration(for asset: AVURLAsset) async throws -> CMTime {
        try await withCheckedThrowingContinuation { continuation in
            asset.loadValuesAsynchronously(forKeys: ["duration"]) {
                var error: NSError?
                let status = asset.statusOfValue(forKey: "duration", error: &error)
                switch status {
                case .loaded:
                    continuation.resume(returning: asset.duration)
                case .failed:
                    continuation.resume(throwing: error ?? NSError(
                        domain: "DualAudioRecorder",
                        code: 9,
                        userInfo: [NSLocalizedDescriptionKey: "Не удалось получить длительность"]
                    ))
                case .cancelled:
                    continuation.resume(throwing: NSError(
                        domain: "DualAudioRecorder",
                        code: 10,
                        userInfo: [NSLocalizedDescriptionKey: "Получение длительности отменено"]
                    ))
                default:
                    continuation.resume(throwing: NSError(
                        domain: "DualAudioRecorder",
                        code: 11,
                        userInfo: [NSLocalizedDescriptionKey: "Неизвестный статус длительности"]
                    ))
                }
            }
        }
    }

    private func export(_ exporter: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: exporter.error ?? NSError(
                        domain: "DualAudioRecorder",
                        code: 12,
                        userInfo: [NSLocalizedDescriptionKey: "Экспорт завершился с ошибкой"]
                    ))
                case .cancelled:
                    continuation.resume(throwing: NSError(
                        domain: "DualAudioRecorder",
                        code: 13,
                        userInfo: [NSLocalizedDescriptionKey: "Экспорт отменён"]
                    ))
                default:
                    break
                }
            }
        }
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
