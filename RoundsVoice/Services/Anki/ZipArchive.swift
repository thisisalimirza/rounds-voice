import Foundation
import zlib

/// ZIP reader for Anki `.apkg` / `.colpkg` packages.
/// Supports stored + deflate, and ZIP64 (required for large AnKing exports).
enum ZipArchive {
    /// Extracts entries whose last path component is in `fileNames` (e.g. collection files only).
    /// Skipping media keeps AnKing imports fast and avoids truncating the DB under memory pressure.
    static func extract(
        archiveURL: URL,
        to destination: URL,
        onlyFileNames: Set<String>? = nil
    ) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Memory-map when possible — full AnKing packages can be multi‑GB.
        let data = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        let entries = try readEntries(from: data)
        var extracted = 0
        for entry in entries {
            if entry.name.hasSuffix("/") { continue }
            let base = (entry.name as NSString).lastPathComponent
            if let onlyFileNames, !onlyFileNames.contains(base) {
                continue
            }
            let outURL = destination.appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = try decompress(entry: entry, archive: data)
            try payload.write(to: outURL, options: .atomic)
            extracted += 1
        }
        if let onlyFileNames, extracted == 0 {
            throw DeckImportError.parsingFailed(
                "ZIP contained none of: \(onlyFileNames.sorted().joined(separator: ", "))."
            )
        }
    }

    static func data(named fileName: String, from archiveURL: URL) throws -> Data? {
        let data = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        let entries = try readEntries(from: data)
        guard let entry = entries.first(where: {
            $0.name == fileName || $0.name.hasSuffix("/\(fileName)")
        }) else {
            return nil
        }
        return try decompress(entry: entry, archive: data)
    }

    private struct Entry {
        var name: String
        var compressionMethod: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var dataOffset: UInt64
    }

    private static let zip64ExtraID: UInt16 = 0x0001
    private static let sentinel32 = UInt32.max

    private static func readEntries(from data: Data) throws -> [Entry] {
        guard data.count >= 22 else {
            throw DeckImportError.parsingFailed("ZIP archive too small.")
        }

        let eocd = try findEndOfCentralDirectory(in: data)
        var totalEntries = UInt64(readUInt16(data, eocd + 10))
        var centralDirectoryOffset = UInt64(readUInt32(data, eocd + 16))

        // ZIP64: classic EOCD fields are 0xFFFF / 0xFFFFFFFF when real values live in ZIP64 EOCD.
        if totalEntries == 0xFFFF || readUInt32(data, eocd + 16) == sentinel32
            || readUInt32(data, eocd + 12) == sentinel32
        {
            if let zip64 = try findZip64EOCD(in: data, classicEOCD: eocd) {
                totalEntries = zip64.totalEntries
                centralDirectoryOffset = zip64.centralDirectoryOffset
            }
        }

        var entries: [Entry] = []
        var cursor = Int(centralDirectoryOffset)
        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count,
                  data[cursor] == 0x50, data[cursor + 1] == 0x4B,
                  data[cursor + 2] == 0x01, data[cursor + 3] == 0x02
            else {
                throw DeckImportError.parsingFailed("Corrupt ZIP central directory.")
            }

            let compressionMethod = readUInt16(data, cursor + 10)
            var compressedSize = UInt64(readUInt32(data, cursor + 20))
            var uncompressedSize = UInt64(readUInt32(data, cursor + 24))
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            var localHeaderOffset = UInt64(readUInt32(data, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                throw DeckImportError.parsingFailed("ZIP entry name out of range.")
            }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? ""

            let extraStart = nameStart + nameLength
            let extraEnd = extraStart + extraLength
            guard extraEnd <= data.count else {
                throw DeckImportError.parsingFailed("ZIP extra field out of range.")
            }
            let needsZip64 =
                readUInt32(data, cursor + 20) == sentinel32
                || readUInt32(data, cursor + 24) == sentinel32
                || readUInt32(data, cursor + 42) == sentinel32
            if needsZip64 {
                let zip64 = parseZip64Extra(
                    data.subdata(in: extraStart..<extraEnd),
                    needUncompressed: readUInt32(data, cursor + 24) == sentinel32,
                    needCompressed: readUInt32(data, cursor + 20) == sentinel32,
                    needOffset: readUInt32(data, cursor + 42) == sentinel32
                )
                if let v = zip64.uncompressedSize { uncompressedSize = v }
                if let v = zip64.compressedSize { compressedSize = v }
                if let v = zip64.localHeaderOffset { localHeaderOffset = v }
            }

            let local = Int(localHeaderOffset)
            guard local + 30 <= data.count else {
                throw DeckImportError.parsingFailed("ZIP local header out of range for \(name).")
            }
            let localNameLength = Int(readUInt16(data, local + 26))
            let localExtraLength = Int(readUInt16(data, local + 28))
            let dataOffset = UInt64(local + 30 + localNameLength + localExtraLength)

            // If CD sizes are zero, fall back to local header (some exporters do this).
            if compressedSize == 0, uncompressedSize == 0 {
                let localComp = readUInt32(data, local + 18)
                let localUncomp = readUInt32(data, local + 22)
                if localComp != sentinel32 { compressedSize = UInt64(localComp) }
                if localUncomp != sentinel32 { uncompressedSize = UInt64(localUncomp) }
                if localComp == sentinel32 || localUncomp == sentinel32 {
                    let localExtraStart = local + 30 + localNameLength
                    let localExtraEnd = localExtraStart + localExtraLength
                    if localExtraEnd <= data.count {
                        let zip64 = parseZip64Extra(
                            data.subdata(in: localExtraStart..<localExtraEnd),
                            needUncompressed: localUncomp == sentinel32,
                            needCompressed: localComp == sentinel32,
                            needOffset: false
                        )
                        if let v = zip64.uncompressedSize { uncompressedSize = v }
                        if let v = zip64.compressedSize { compressedSize = v }
                    }
                }
            }

            entries.append(
                Entry(
                    name: name,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    dataOffset: dataOffset
                )
            )

            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private struct Zip64EOCD {
        var totalEntries: UInt64
        var centralDirectoryOffset: UInt64
    }

    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        let start = max(0, data.count - 65_535 - 22)
        for i in stride(from: data.count - 22, through: start, by: -1) {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                return i
            }
        }
        throw DeckImportError.parsingFailed("Invalid ZIP (missing EOCD).")
    }

    private static func findZip64EOCD(in data: Data, classicEOCD: Int) throws -> Zip64EOCD? {
        // ZIP64 EOCD locator sits immediately before classic EOCD (20 bytes).
        let locator = classicEOCD - 20
        guard locator >= 0,
              data[locator] == 0x50, data[locator + 1] == 0x4B,
              data[locator + 2] == 0x06, data[locator + 3] == 0x07
        else {
            return nil
        }

        let zip64Offset = Int(readUInt64(data, locator + 8))
        guard zip64Offset + 56 <= data.count,
              data[zip64Offset] == 0x50, data[zip64Offset + 1] == 0x4B,
              data[zip64Offset + 2] == 0x06, data[zip64Offset + 3] == 0x06
        else {
            throw DeckImportError.parsingFailed("Invalid ZIP64 end of central directory.")
        }

        return Zip64EOCD(
            totalEntries: readUInt64(data, zip64Offset + 32),
            centralDirectoryOffset: readUInt64(data, zip64Offset + 48)
        )
    }

    private struct Zip64Sizes {
        var uncompressedSize: UInt64?
        var compressedSize: UInt64?
        var localHeaderOffset: UInt64?
    }

    /// ZIP64 extra field (0x0001) values appear in a fixed order for each present sentinel.
    private static func parseZip64Extra(
        _ extra: Data,
        needUncompressed: Bool,
        needCompressed: Bool,
        needOffset: Bool
    ) -> Zip64Sizes {
        var result = Zip64Sizes()
        var i = 0
        while i + 4 <= extra.count {
            let headerID = readUInt16(extra, i)
            let size = Int(readUInt16(extra, i + 2))
            let dataStart = i + 4
            let dataEnd = dataStart + size
            guard dataEnd <= extra.count else { break }

            if headerID == zip64ExtraID {
                var o = dataStart
                if needUncompressed, o + 8 <= dataEnd {
                    result.uncompressedSize = readUInt64(extra, o)
                    o += 8
                }
                if needCompressed, o + 8 <= dataEnd {
                    result.compressedSize = readUInt64(extra, o)
                    o += 8
                }
                if needOffset, o + 8 <= dataEnd {
                    result.localHeaderOffset = readUInt64(extra, o)
                }
                return result
            }
            i = dataEnd
        }
        return result
    }

    private static func decompress(entry: Entry, archive: Data) throws -> Data {
        let start = Int(entry.dataOffset)
        let size = Int(entry.compressedSize)
        guard start >= 0, size >= 0, start <= archive.count, start + size <= archive.count else {
            throw DeckImportError.parsingFailed(
                "ZIP entry data out of range: \(entry.name) (offset \(entry.dataOffset), size \(entry.compressedSize), archive \(archive.count))."
            )
        }
        if size == 0, entry.name.contains("collection") {
            throw DeckImportError.parsingFailed(
                "ZIP entry \(entry.name) has zero size — package may need ZIP64 support or a re-export."
            )
        }
        let compressed = archive.subdata(in: start..<(start + size))

        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try inflateRaw(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            throw DeckImportError.parsingFailed(
                "Unsupported ZIP compression (\(entry.compressionMethod)) for \(entry.name)."
            )
        }
    }

    private static func inflateRaw(_ input: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw DeckImportError.parsingFailed("zlib init failed (\(initStatus)).")
        }
        defer { inflateEnd(&stream) }

        let initial = expectedSize > 0 && expectedSize < 500_000_000
            ? expectedSize
            : max(input.count * 2, 65_536)
        var output = [UInt8](repeating: 0, count: initial)
        var outputCount = 0

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let inBase = raw.bindMemory(to: Bytef.self).baseAddress else {
                throw DeckImportError.parsingFailed("zlib input buffer unavailable.")
            }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(input.count)

            while true {
                if outputCount >= output.count {
                    output.append(contentsOf: [UInt8](repeating: 0, count: max(65_536, output.count)))
                }

                let status: Int32 = output.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress?.advanced(by: outputCount)
                    stream.avail_out = uInt(buffer.count - outputCount)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                outputCount = Int(stream.total_out)

                if status == Z_STREAM_END {
                    break
                }
                if status != Z_OK {
                    throw DeckImportError.parsingFailed("zlib inflate failed (\(status)).")
                }
            }
        }

        return Data(output.prefix(outputCount))
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(readUInt32(data, offset)) | (UInt64(readUInt32(data, offset + 4)) << 32)
    }
}
