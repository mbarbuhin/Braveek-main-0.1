import Foundation

/// Управляет всеми папками приложения, чтобы структура была единообразной.
@available(macOS 13.0, *)
struct AppPaths {
    static let shared = AppPaths()

    /// Корневая папка в Application Support: `~/Library/Application Support/AutoMeetingRecorder`.
    let rootDirectory: URL

    /// Подпапка для аудиозаписей: `.../Recordings`.
    let recordingsDirectory: URL

    private init() {
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootDirectory = applicationSupportURL.appendingPathComponent("AutoMeetingRecorder", isDirectory: true)
        recordingsDirectory = rootDirectory.appendingPathComponent("Recordings", isDirectory: true)

        createDirectoryIfNeeded(rootDirectory)
        createDirectoryIfNeeded(recordingsDirectory)
    }

    private func createDirectoryIfNeeded(_ url: URL) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                print("📁 Создана папка: \(url.path)")
            } catch {
                print("❌ Не удалось создать папку \(url.path): \(error.localizedDescription)")
            }
        }
    }
}
