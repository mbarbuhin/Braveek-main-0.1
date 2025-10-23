import Foundation
import Supabase

actor SupabaseUploader {
    static let shared = SupabaseUploader()

    private let client: SupabaseClient?
    private let bucket: String?

    init() {
        let environment = ProcessInfo.processInfo.environment
        if
            let urlString = environment["SUPABASE_URL"],
            let url = URL(string: urlString),
            let anonKey = environment["SUPABASE_ANON_KEY"],
            let bucket = environment["SUPABASE_BUCKET"]
        {
            self.client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
            self.bucket = bucket
            print("☁️ SupabaseUploader: облачная загрузка активна (bucket: \(bucket))")
        } else {
            self.client = nil
            self.bucket = nil
            print("⚠️ SupabaseUploader: переменные окружения не заданы, загрузка отключена")
        }
    }

    func uploadMix(at fileURL: URL, baseName: String) async throws {
        guard let client, let bucket else {
            print("📴 SupabaseUploader: пропускаем загрузку \(fileURL.lastPathComponent)")
            return
        }

        let data = try Data(contentsOf: fileURL)
        let path = "mixes/\(baseName).m4a"
        print("☁️ SupabaseUploader: начинаем загрузку \(path)")

        do {
            let options = FileOptions(cacheControl: nil, contentType: "audio/mp4", upsert: true)
            try await client.storage.from(bucket).upload(
                path: path,
                data: data,
                fileOptions: options
            )
            print("✅ SupabaseUploader: загрузка завершена \(path)")
        } catch {
            print("❌ SupabaseUploader: ошибка загрузки \(path): \(error.localizedDescription)")
            throw error
        }
    }
}
