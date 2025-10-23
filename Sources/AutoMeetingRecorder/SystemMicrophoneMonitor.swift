import Foundation
import CoreAudio

class SystemMicrophoneMonitor {
    private var microphoneDeviceID: AudioDeviceID = 0
    private var isMonitoring = false
    private var lastState = false
    
    var onMicrophoneStateChanged: ((Bool) -> Void)?
    
    init() {
        print("🎧 Инициализация мониторинга микрофона...")
    }
    
    func start() throws {
        guard !isMonitoring else {
            print("⚠️  Мониторинг уже запущен")
            return
        }
        
        // Находим микрофон по умолчанию
        guard let deviceID = getDefaultInputDevice() else {
            throw NSError(domain: "SystemMicrophoneMonitor", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Не найден микрофон"])
        }
        
        microphoneDeviceID = deviceID
        let deviceName = getDeviceName(deviceID)
        print("✅ Найден микрофон: \(deviceName) (ID: \(deviceID))")
        
        // Подписываемся на изменения состояния
        try setupPropertyListener()
        
        isMonitoring = true
        print("✅ Мониторинг запущен")
    }
    
    func stop() {
        guard isMonitoring else { return }
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectRemovePropertyListener(
            microphoneDeviceID,
            &propertyAddress,
            audioDevicePropertyListenerProc,
            Unmanaged.passUnretained(self).toOpaque()
        )
        
        isMonitoring = false
        print("⏹️  Мониторинг остановлен")
    }
    
    // MARK: - Private
    
    private func setupPropertyListener() throws {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectAddPropertyListener(
            microphoneDeviceID,
            &propertyAddress,
            audioDevicePropertyListenerProc,
            Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard status == noErr else {
            throw NSError(domain: "SystemMicrophoneMonitor", code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Не удалось подписаться на события"])
        }
    }
    
    fileprivate func checkMicrophoneState() {
        let isActive = isDeviceActive(microphoneDeviceID)
        if isActive != lastState {
            lastState = isActive

            // 1) Мгновенно отдать событие наверх (без блокировок MainActor)
            Task {
                print("🔔 [MON] mic=\(isActive ? "TRUE" : "FALSE") → deliver callback")
                self.onMicrophoneStateChanged?(isActive)
            }

            // 2) Косметика — в фоне
            Task.detached { [weak self] in
                guard let self else { return }
                if isActive {
                    if let processName = self.getProcessUsingMicrophone() {
                        print("   Процесс: \(processName)")
                    } else {
                        print("   Процесс: (не определён)")
                    }
                    print("🟢 Микрофон АКТИВИРОВАН (приложение использует его)")
                } else {
                    print("⚪️ Микрофон ДЕАКТИВИРОВАН")
                }
            }
        }
    }
    
    private func getDefaultInputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        guard status == noErr && deviceID != 0 else { return nil }
        return deviceID
    }
    
    private func getDeviceName(_ deviceID: AudioDeviceID) -> String {
        var propertySize = UInt32(MemoryLayout<CFString>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceName: CFString = "" as CFString
        
        guard AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceName
        ) == noErr else { return "Unknown" }
        
        return deviceName as String
    }
    
    private func isDeviceActive(_ deviceID: AudioDeviceID) -> Bool {
        var isRunning = UInt32(0)
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &isRunning
        )
        
        return status == noErr && isRunning != 0
    }
    
    private func getProcessUsingMicrophone() -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["-c", "Safari", "-c", "zoom", "-c", "Discord", "-c", "Teams"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8),
               output.contains("audio") {
                if output.contains("Safari") { return "Safari" }
                if output.contains("zoom") { return "Zoom" }
                if output.contains("Discord") { return "Discord" }
                if output.contains("Teams") { return "Teams" }
            }
        } catch {
            // Не критично
        }
        
        return nil
    }
    
    deinit {
        stop()
    }
}

// MARK: - C Callback

private func audioDevicePropertyListenerProc(
    inObjectID: AudioObjectID,
    inNumberAddresses: UInt32,
    inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = inClientData else { return noErr }
    
    let monitor = Unmanaged<SystemMicrophoneMonitor>
        .fromOpaque(clientData)
        .takeUnretainedValue()
    
    monitor.checkMicrophoneState()
    
    return noErr
}

