import Foundation
import SQLite3

/// Reads an Anki collection database extracted from an `.apkg`.
struct AnkiCollectionReader: Sendable {
    struct NoteType: Sendable, Equatable {
        var id: Int64
        var name: String
        /// 0 = standard, 1 = cloze
        var type: Int
        var fieldNames: [String]
    }

    struct RawNote: Sendable, Equatable {
        var id: Int64
        var modelID: Int64
        var tags: [String]
        var fields: [String]
    }

    struct DeckInfo: Sendable, Equatable {
        var id: Int64
        var name: String
    }

    struct Collection: Sendable {
        var noteTypes: [Int64: NoteType]
        var decks: [Int64: DeckInfo]
        var notes: [RawNote]
        var primaryDeckName: String
    }

    static func load(databaseURL: URL) throws -> Collection {
        let db = try openDatabase(at: databaseURL)
        defer { sqlite3_close(db) }

        let tables = try Set(tableNames(db: db))
        if tables.isEmpty {
            let size = (try? FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? NSNumber)?.intValue ?? -1
            throw DeckImportError.parsingFailed(
                "Anki database is empty (no tables, \(size) bytes at \(databaseURL.lastPathComponent)). Usually a truncated ZIP/zstd extract of collection.anki21b — try re-exporting the .apkg from Anki (media optional)."
            )
        }

        // Modern AnKing packages store notetypes in dedicated tables.
        // Prefer that over legacy `col.models`, which may be a stub.
        let noteTypes: [Int64: NoteType]
        if tables.contains("notetypes") {
            noteTypes = try loadNoteTypesFromTable(db: db)
        } else if tables.contains("col") {
            do {
                noteTypes = try loadNoteTypesFromColModels(db: db)
            } catch {
                throw DeckImportError.parsingFailed(
                    "Couldn't read Anki note types from col.models. Use a full AnKing .apkg (not a tiny stub export). Tables: \(tables.sorted().joined(separator: ", "))."
                )
            }
        } else {
            throw DeckImportError.parsingFailed(
                "Anki database missing notetypes/col. Tables found: \(tables.sorted().joined(separator: ", "))."
            )
        }

        let decks: [Int64: DeckInfo]
        if tables.contains("decks") {
            decks = try loadDecksFromTable(db: db)
        } else {
            decks = try loadDecksFromCol(db: db)
        }

        let notes = try loadNotes(db: db)

        let primaryDeckName = preferredDeckName(from: decks)

        return Collection(
            noteTypes: noteTypes,
            decks: decks,
            notes: notes,
            primaryDeckName: primaryDeckName
        )
    }

    private static func preferredDeckName(from decks: [Int64: DeckInfo]) -> String {
        let names = decks.values.map(\.name)
            .map { $0.replacingOccurrences(of: "\u{1f}", with: "::") }
            .filter { !$0.isEmpty && $0 != "Default" }

        // Prefer shortest top-level name (e.g. "AnKing Step Deck" over nested).
        return names.sorted { $0.count < $1.count }.first
            ?? decks.values.map(\.name).sorted().first
            ?? "Imported Anki Deck"
    }

    // MARK: - Note types

    private static func loadNoteTypesFromColModels(db: OpaquePointer) throws -> [Int64: NoteType] {
        guard let modelsJSON = try? scalarText(db: db, sql: "SELECT models FROM col LIMIT 1"),
              let data = modelsJSON.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw DeckImportError.parsingFailed("Couldn't read Anki note types (models).")
        }

        var result: [Int64: NoteType] = [:]
        for (_, value) in root {
            guard let model = value as? [String: Any], let parsed = parseModel(model) else { continue }
            result[parsed.id] = parsed
        }
        guard !result.isEmpty else {
            throw DeckImportError.parsingFailed("Couldn't read Anki note types (models).")
        }
        return result
    }

    private static func loadNoteTypesFromTable(db: OpaquePointer) throws -> [Int64: NoteType] {
        let fieldsByNoteType = loadAllFieldNames(db: db)

        var result: [Int64: NoteType] = [:]
        let sql = "SELECT id, name, config FROM notetypes"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DeckImportError.parsingFailed("Couldn't read notetypes table.")
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let name = columnText(statement, 1) ?? "Unknown"
            var type = 0

            // config is protobuf-ish; Anki stores type as varint field 1 (`0x08 <type>`).
            if let config = columnBlob(statement, 2), config.count >= 2, config[0] == 0x08 {
                type = Int(config[1])
            }

            // AnKing note types are always cloze even if type byte is missing.
            let lowered = name.lowercased()
            if lowered.contains("anking") || lowered.contains("cloze") {
                type = 1
            }

            var fieldNames = fieldsByNoteType[id] ?? []
            // If the fields table was empty/unreadable, fall back to AnKing ordinal names
            // so we don't mark every note as "empty".
            if fieldNames.isEmpty {
                fieldNames = defaultFieldNames(forNoteTypeNamed: name, cloze: type == 1)
            }

            result[id] = NoteType(id: id, name: name, type: type, fieldNames: fieldNames)
        }

        guard !result.isEmpty else {
            throw DeckImportError.parsingFailed("notetypes table was empty.")
        }
        return result
    }

    /// Load every field definition in one scan — avoids per-row `sqlite3_bind_*` pitfalls.
    private static func loadAllFieldNames(db: OpaquePointer) -> [Int64: [String]] {
        guard tableExists(db: db, name: "fields") else { return [:] }

        var grouped: [Int64: [(Int, String)]] = [:]
        let sql = "SELECT ntid, ord, name FROM fields"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let ntid = sqlite3_column_int64(statement, 0)
            let ord = Int(sqlite3_column_int(statement, 1))
            let name = columnText(statement, 2) ?? "Field\(ord)"
            grouped[ntid, default: []].append((ord, name))
        }

        var result: [Int64: [String]] = [:]
        for (ntid, pairs) in grouped {
            result[ntid] = pairs.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return result
    }

    /// AnKing / standard cloze ordinal fallback when `fields` metadata is missing.
    private static func defaultFieldNames(forNoteTypeNamed name: String, cloze: Bool) -> [String] {
        let lowered = name.lowercased()
        if lowered.contains("anking") || cloze {
            // Typical AnKingOverhaul order (extras after Text may vary; Text is always first).
            return [
                "Text",
                "Extra",
                "Personal Notes",
                "Missed Questions",
                "Lecture Notes",
                "Boards and Beyond",
                "First Aid",
                "Sketchy",
                "Pixorize",
                "Physeo",
                "One by one"
            ]
        }
        return ["Front", "Back"]
    }

    private static func parseModel(_ model: [String: Any]) -> NoteType? {
        let id: Int64
        if let n = model["id"] as? Int64 { id = n }
        else if let n = model["id"] as? Int { id = Int64(n) }
        else if let n = model["id"] as? Double { id = Int64(n) }
        else { return nil }

        let name = model["name"] as? String ?? "Unknown"
        let type = model["type"] as? Int ?? 0
        let flds = model["flds"] as? [[String: Any]] ?? []
        let fieldNames = flds
            .sorted { ($0["ord"] as? Int ?? 0) < ($1["ord"] as? Int ?? 0) }
            .compactMap { $0["name"] as? String }
        return NoteType(id: id, name: name, type: type, fieldNames: fieldNames)
    }

    // MARK: - Decks

    private static func loadDecksFromTable(db: OpaquePointer) throws -> [Int64: DeckInfo] {
        var result: [Int64: DeckInfo] = [:]
        let sql = "SELECT id, name FROM decks"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return [1: DeckInfo(id: 1, name: "Imported Anki Deck")]
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let name = (columnText(statement, 1) ?? "Deck")
                .replacingOccurrences(of: "\u{1f}", with: "::")
            result[id] = DeckInfo(id: id, name: name)
        }
        return result.isEmpty ? [1: DeckInfo(id: 1, name: "Imported Anki Deck")] : result
    }

    private static func loadDecksFromCol(db: OpaquePointer) throws -> [Int64: DeckInfo] {
        if let decksJSON = try? scalarText(db: db, sql: "SELECT decks FROM col LIMIT 1"),
           let data = decksJSON.data(using: .utf8),
           let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            var result: [Int64: DeckInfo] = [:]
            for (key, value) in root {
                guard let deck = value as? [String: Any] else { continue }
                let id = Int64(key) ?? (deck["id"] as? Int).map(Int64.init) ?? 0
                let name = (deck["name"] as? String ?? "Deck")
                    .replacingOccurrences(of: "\u{1f}", with: "::")
                result[id] = DeckInfo(id: id, name: name)
            }
            if !result.isEmpty { return result }
        }
        return [1: DeckInfo(id: 1, name: "Imported Anki Deck")]
    }

    // MARK: - Notes

    private static func loadNotes(db: OpaquePointer) throws -> [RawNote] {
        var notes: [RawNote] = []
        let sql = "SELECT id, mid, tags, flds FROM notes"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DeckImportError.parsingFailed("Couldn't read notes table.")
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            let mid = sqlite3_column_int64(statement, 1)
            let tagsRaw = columnText(statement, 2) ?? ""
            // Prefer text; fall back to blob (some builds store flds oddly).
            let fieldsRaw = columnText(statement, 3)
                ?? columnBlob(statement, 3).flatMap { String(data: $0, encoding: .utf8) }
                ?? ""

            let tags = tagsRaw
                .split(separator: " ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let fields = splitAnkiFields(fieldsRaw)
            notes.append(RawNote(id: id, modelID: mid, tags: tags, fields: fields))
        }
        return notes
    }

    /// Anki joins fields with U+001F. Tolerate stray NULs from odd exports.
    private static func splitAnkiFields(_ raw: String) -> [String] {
        if raw.contains("\u{1f}") {
            return raw.components(separatedBy: "\u{1f}")
        }
        if raw.contains("\0") {
            return raw.components(separatedBy: "\0")
        }
        return [raw]
    }

    // MARK: - SQLite helpers

    /// Anki collections are often WAL-mode. After zstd extract there is no `-wal` / `-shm`
    /// sidecar, so a normal open fails with "unable to open database file" and looks empty.
    private static func openDatabase(at url: URL) throws -> OpaquePointer {
        if let db = tryOpenImmutable(at: url) {
            return db
        }

        // Last resort: rewrite journal mode on the temp copy, then reopen immutable.
        var rw: OpaquePointer?
        if sqlite3_open_v2(url.path, &rw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle = rw {
            registerAnkiCollations(handle)
            _ = sqlite3_exec(handle, "PRAGMA journal_mode=DELETE;", nil, nil, nil)
            _ = sqlite3_exec(handle, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
            sqlite3_close(handle)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
            if let db = tryOpenImmutable(at: url) {
                return db
            }
        } else if let handle = rw {
            sqlite3_close(handle)
        }

        throw DeckImportError.parsingFailed(
            "Couldn't open Anki database (missing WAL sidecars or corrupt file)."
        )
    }

    private static func tryOpenImmutable(at url: URL) -> OpaquePointer? {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [
            URLQueryItem(name: "mode", value: "ro"),
            URLQueryItem(name: "immutable", value: "1")
        ]
        guard let uri = components.string else { return nil }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        registerAnkiCollations(handle)
        return handle
    }

    /// Anki indexes use a custom `unicase` collation. Without it, queries fail with
    /// "no such collation sequence: unicase" / "no query solution".
    private static func registerAnkiCollations(_ db: OpaquePointer) {
        sqlite3_create_collation_v2(
            db,
            "unicase",
            SQLITE_UTF8,
            nil,
            { _, length1, bytes1, length2, bytes2 in
                let left = String(
                    bytes: UnsafeRawBufferPointer(start: bytes1, count: Int(length1)),
                    encoding: .utf8
                ) ?? ""
                let right = String(
                    bytes: UnsafeRawBufferPointer(start: bytes2, count: Int(length2)),
                    encoding: .utf8
                ) ?? ""
                let ordering = left.compare(right, options: [.caseInsensitive, .diacriticInsensitive])
                switch ordering {
                case .orderedAscending: return -1
                case .orderedDescending: return 1
                case .orderedSame: return 0
                }
            },
            nil
        )
    }

    private static func scalarText(db: OpaquePointer, sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw DeckImportError.parsingFailed("SQL prepare failed: \(message)")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DeckImportError.parsingFailed("SQL returned no rows.")
        }
        return columnText(statement, 0) ?? ""
    }

    private static func tableNames(db: OpaquePointer) throws -> [String] {
        let sql = "SELECT name FROM sqlite_master WHERE type='table'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            throw DeckImportError.parsingFailed("Couldn't list Anki tables: \(message)")
        }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = columnText(statement, 0) {
                names.append(name)
            }
        }
        return names
    }

    private static func tableExists(db: OpaquePointer, name: String) -> Bool {
        // Avoid sqlite3_bind_text lifetime pitfalls — only allow known identifiers.
        let allowed: Set<String> = [
            "notetypes", "fields", "decks", "notes", "col", "cards", "templates", "config", "tags"
        ]
        guard allowed.contains(name) else { return false }
        return (try? tableNames(db: db))?.contains(name) == true
    }

    private static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func columnBlob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }
}
