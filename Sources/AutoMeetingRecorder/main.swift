import Foundation
import AVFoundation
import ScreenCaptureKit

print("╔════════════════════════════════════════════════════╗")
print("║   🎙️  Auto Meeting Recorder для macOS M4         ║")
print("║   Автоматическая запись встреч                    ║")
print("╚════════════════════════════════════════════════════╝\n")

guard #available(macOS 13.0, *) else {
    print("❌ Требуется macOS 13.0 или новее")
    exit(1)
}

@available(macOS 13.0, *)
func checkPermissions() async -> Bool {
    print("🔐 Проверка разрешений...\n")
    
    // Микрофон
    print("1️⃣  Проверка микрофона...")
    let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    
    switch micStatus {
    case .authorized:
        print("   ✅ Микрофон: OK")
    case .notDetermined:
        print("   ⏳ Запрашиваем доступ...")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        if !granted {
            print("   ❌ Доступ отклонён")
            return false
        }
        print("   ✅ Микрофон: OK")
    case .denied, .restricted:
        print("   ❌ Нет доступа к микрофону")
        print("   💡 Системные настройки → Конфиденциальность → Микрофон")
        return false
    @unknown default:
        return false
    }
    
    // Screen Recording
    print("\n2️⃣  Проверка записи экрана (для системного звука)...")
    do {
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        print("   ✅ Запись экрана: OK")
        return true
    } catch {
        print("   ❌ Нет доступа к записи экрана")
        print("\n📋 Откройте:")
        print("   Системные настройки → Конфиденциальность")
        print("   → Запись экрана → Добавьте Terminal\n")
        return false
    }
}

@available(macOS 13.0, *)
final class RecordingManager {
    let recorder = DualAudioRecorder()
    let monitor = SystemMicrophoneMonitor()

    // Текущее состояние
    private(set) var isCurrentlyRecording = false
    private var micIsActiveNow = false

    // Антидребезг: отложенные задачи
    private var pendingStartTask: Task<Void, Never>?
    private var pendingStopTask: Task<Void, Never>?

    // Настройки антидребезга
    private let startDebounceMs: UInt64 = 500   // устойчивый TRUE 0.5s
    private let stopDebounceMs:  UInt64 = 3000  // устойчивый FALSE 3s

    func setup() {
        monitor.onMicrophoneStateChanged = { [weak self] isActive in
            self?.handleMicStateChange(isActive)
        }
        try? monitor.start()
    }

    // MARK: - Авто-логика

    private func handleMicStateChange(_ isActive: Bool) {
        micIsActiveNow = isActive

        if isActive {
            print("🔔 [AUTO] mic=TRUE → arming start in \(startDebounceMs)ms")
            // отменяем ожидаемый стоп
            pendingStopTask?.cancel(); pendingStopTask = nil

            // если уже пишем — выходим
            guard !isCurrentlyRecording else { return }

            // дебаунсим старт
            pendingStartTask?.cancel()
            pendingStartTask = Task.detached { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(nanoseconds: self.startDebounceMs * 1_000_000)
                guard !Task.isCancelled else { return }
                guard self.micIsActiveNow, !self.isCurrentlyRecording else { return }
                await self.startRecordingAuto()
            }

        } else {
            print("🔔 [AUTO] mic=FALSE → schedule stop in \(stopDebounceMs)ms")
            // отменяем ожидаемый старт
            pendingStartTask?.cancel(); pendingStartTask = nil

            // если не пишем — ничего
            guard isCurrentlyRecording else { return }

            // дебаунсим стоп
            pendingStopTask?.cancel()
            pendingStopTask = Task.detached { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(nanoseconds: self.stopDebounceMs * 1_000_000)
                guard !Task.isCancelled else { return }
                guard !self.micIsActiveNow, self.isCurrentlyRecording else { return }
                self.stopRecordingAuto()
            }
        }
    }

    private func startRecordingAuto() async {
        print("🎤 [AUTO] start requested")
        do {
            try await recorder.startRecording()
            isCurrentlyRecording = true
            print("✅ [AUTO] started")
        } catch {
            print("❌ [AUTO] start error: \(error.localizedDescription)")
        }
    }

    private func stopRecordingAuto() {
        print("⏹️  [AUTO] stop requested")
        recorder.stopRecording()
        isCurrentlyRecording = false
        print("✅ [AUTO] stopped")
    }

    // MARK: - Ручное управление

    func startManually() {
        guard !isCurrentlyRecording else {
            print("⚠️  Запись уже идёт")
            return
        }
        pendingStopTask?.cancel(); pendingStopTask = nil
        Task.detached { [weak self] in
            guard let self = self else { return }
            do {
                try await self.recorder.startRecording()
                self.isCurrentlyRecording = true
            } catch {
                print("❌ Ошибка: \(error.localizedDescription)")
            }
        }
    }

    func stopManually() {
        guard isCurrentlyRecording else {
            print("⚠️  Запись не активна")
            return
        }
        pendingStartTask?.cancel(); pendingStartTask = nil
        recorder.stopRecording()
        isCurrentlyRecording = false
    }
}

@available(macOS 13.0, *)
func main() async {
    let hasPermissions = await checkPermissions()
    guard hasPermissions else {
        print("\n❌ Недостаточно разрешений")
        exit(1)
    }
    
    print("\n" + String(repeating: "─", count: 52))
    print("✅ Система готова!\n")
    
    let manager = RecordingManager()
    manager.setup()
    
    print("📝 Как работает:")
    print("   1. Зайдите в Safari на встречу")
    print("   2. Начните говорить → запись начнётся автоматически")
    print("   3. После 2 секунд тишины → запись остановится")
    print("   4. После остановки дорожки сохраняются по папкам и сводятся в M4A")
    print("      (mix_<timestamp>.m4a в папке Recordings/Mixes)")

    let paths = AppPaths.shared
    print("\n📂 Структура файлов:")
    print("   Корневая папка: \(paths.rootDirectory.path)")
    print("   База: \(paths.recordingsDirectory.path)")
    print("   🎤 Микрофон: \(paths.microphoneRecordingsDirectory.path)")
    print("   💻 Система: \(paths.systemRecordingsDirectory.path)")
    print("   🎧 Миксы: \(paths.mixedRecordingsDirectory.path)")
    print("   Пример готового микса: mix_YYYY-MM-DDTHH-MM-SS.m4a\n")
    
    print("🎮 Команды:")
    print("   [Enter] - Начать запись вручную")
    print("   [S] - Остановить запись")
    print("   [Q] - Выход\n")
    print(String(repeating: "─", count: 52))
    print("⏳ Говорите в микрофон для начала записи...\n")
    
    // Ввод с клавиатуры — в отдельной фоновой задаче (не блокируем MainActor)
    Task.detached {
        while true {
            guard let input = readLine()?.lowercased() else { continue }
            switch input {
            case "", " ":
                manager.startManually()
            case "s", "stop":
                manager.stopManually()
            case "q", "quit":
                print("\n👋 Завершение...")
                if manager.isCurrentlyRecording {
                    manager.stopManually()
                }
                exit(0)
            default:
                print("⚠️  Используйте: Enter, S, Q")
            }
        }
    }
}

// Signal handler для Ctrl+C
signal(SIGINT) { _ in
    print("\n\n👋 Выход...")
    exit(0)
}

Task {
    await main()
}

// Держим процесс живым
dispatchMain()

