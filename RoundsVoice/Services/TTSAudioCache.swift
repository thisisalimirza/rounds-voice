import CryptoKit
import Foundation

/// In-memory LRU cache for OpenAI TTS audio so short phrases and repeats aren't re-fetched.
actor TTSAudioCache {
    static let shared = TTSAudioCache()

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let maxEntries = 64
    private let maxBytes = 24 * 1024 * 1024
    private var totalBytes = 0

    private struct Entry {
        var data: Data
        var byteCount: Int
    }

    static func cacheKey(model: String, voice: String, speed: Double, text: String) -> String {
        let payload = "\(model)|\(voice)|\(String(format: "%.2f", speed))|\(text)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func data(for key: String) -> Data? {
        guard let entry = entries[key] else { return nil }
        // Refresh LRU order.
        order.removeAll { $0 == key }
        order.append(key)
        return entry.data
    }

    func store(_ data: Data, for key: String) {
        guard !data.isEmpty else { return }
        if let existing = entries[key] {
            totalBytes -= existing.byteCount
            order.removeAll { $0 == key }
        }
        entries[key] = Entry(data: data, byteCount: data.count)
        order.append(key)
        totalBytes += data.count
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while totalBytes > maxBytes || order.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) {
                totalBytes -= removed.byteCount
            }
        }
    }
}
