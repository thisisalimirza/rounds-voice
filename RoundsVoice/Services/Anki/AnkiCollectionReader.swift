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
        var db: OpaquePointer?
        let path = databaseURL.path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw DeckImportError.parsingFailed("Couldn't open Anki database.")
        }
        defer { sqlite3_close(db) }

        // Modern AnKing packages store notetypes in dedicated tables.
        // Prefer that over legacy `col.models`, which may be a stub.
        let noteTypes: [Int64: NoteType]
        if tableExists(db: db, name: "notetypes") {
            noteTypes = try loadNoteTypesFromTable(db: db)
        } else if tableExists(db: db, name: "col") {
            // Legacy schema — or modern DB where notetypes detection failed previously.
            do {
                noteTypes = try loadNoteTypesFromColModels(db: db)
            } catch {
                throw DeckImportError.parsingFailed(
                    "Couldn't read Anki note types. This package may be an older stub collection — use a full AnKing .apkg export (collection.anki21b)."
                )
            }
        } else {
            throw DeckImportError.parsingFailed("Anki database has no notetypes or col.models.")
        }

        let decks: [Int64: DeckInfo]
        if tableExists(db: db, name: "decks") {
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

            let fieldNames = try loadFieldNames(db: db, noteTypeID: id)
            result[id] = NoteType(id: id, name: name, type: type, fieldNames: fieldNames)
        }

        guard !result.isEmpty else {
            throw DeckImportError.parsingFailed("notetypes table was empty.")
        }
        return result
    }

    private static func loadFieldNames(db: OpaquePointer, noteTypeID: Int64) throws -> [String] {
        guard tableExists(db: db, name: "fields") else { return [] }
        var names: [(Int, String)] = []
        let sql = "SELECT ord, name FROM fields WHERE ntid = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, noteTypeID)
        while sqlite3_step(statement) == SQLITE_ROW {
            let ord = Int(sqlite3_column_int(statement, 0))
            let name = columnText(statement, 1) ?? "Field\(ord)"
            names.append((ord, name))
        }
        return names.sorted { $0.0 < $1.0 }.map(\.1)
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
            let fieldsRaw = columnText(statement, 3) ?? ""

            let tags = tagsRaw
                .split(separator: " ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let fields = fieldsRaw.components(separatedBy: "\u{1f}")
            notes.append(RawNote(id: id, modelID: mid, tags: tags, fields: fields))
        }
        return notes
    }

    // MARK: - SQLite helpers

    private static func scalarText(db: OpaquePointer, sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DeckImportError.parsingFailed("SQL prepare failed.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DeckImportError.parsingFailed("SQL returned no rows.")
        }
        return columnText(statement, 0) ?? ""
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func tableExists(db: OpaquePointer, name: String) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT copies the string — SQLITE_STATIC (nil) was a dangling-pointer bug
        // that made `notetypes` look missing, so AnKing imports fell through to stub `col.models`.
        name.withCString { cString in
            _ = sqlite3_bind_text(statement, 1, cString, -1, sqliteTransient)
        }
        return sqlite3_step(statement) == SQLITE_ROW
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
