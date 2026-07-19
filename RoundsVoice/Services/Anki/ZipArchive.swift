import Foundation
import zlib

/// Minimal ZIP reader for Anki `.apkg` / `.colpkg` packages.
/// Supports stored and deflated entries (what Anki exports use).
enum ZipArchive {
    static func extract(archiveURL: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let data = try Data(contentsOf: archiveURL)
        let entries = try readEntries(from: data)
        for entry in entries {
            if entry.name.hasSuffix("/") { continue }
            let outURL = destination.appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = try decompress(entry: entry, archive: data)
            try payload.write(to: outURL, options: .atomic)
        }
    }

    static func data(named fileName: String, from archiveURL: URL) throws -> Data? {
        let data = try Data(contentsOf: archiveURL)
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
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var dataOffset: Int
    }

    private static func readEntries(from data: Data) throws -> [Entry] {
        guard data.count >= 22 else {
            throw DeckImportError.parsingFailed("ZIP archive too small.")
        }

        var eocdOffset: Int?
        let start = max(0, data.count - 65_535 - 22)
        for i in stride(from: data.count - 22, through: start, by: -1) {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
        }
        guard let eocd = eocdOffset else {
            throw DeckImportError.parsingFailed("Invalid ZIP (missing EOCD).")
        }

        let totalEntries = Int(readUInt16(data, eocd + 10))
        let centralDirectoryOffset = Int(readUInt32(data, eocd + 16))

        var entries: [Entry] = []
        var cursor = centralDirectoryOffset
        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count,
                  data[cursor] == 0x50, data[cursor + 1] == 0x4B,
                  data[cursor + 2] == 0x01, data[cursor + 3] == 0x02
            else {
                throw DeckImportError.parsingFailed("Corrupt ZIP central directory.")
            }

            let compressionMethod = readUInt16(data, cursor + 10)
            let compressedSize = readUInt32(data, cursor + 20)
            let uncompressedSize = readUInt32(data, cursor + 24)
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            let localHeaderOffset = Int(readUInt32(data, cursor + 42))

            let nameStart = cursor + 46
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? ""

            guard localHeaderOffset + 30 <= data.count else {
                throw DeckImportError.parsingFailed("ZIP local header out of range.")
            }
            let localNameLength = Int(readUInt16(data, localHeaderOffset + 26))
            let localExtraLength = Int(readUInt16(data, localHeaderOffset + 28))
            let dataOffset = localHeaderOffset + 30 + localNameLength + localExtraLength

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

    private static func decompress(entry: Entry, archive: Data) throws -> Data {
        let end = entry.dataOffset + Int(entry.compressedSize)
        guard entry.dataOffset >= 0, end <= archive.count else {
            throw DeckImportError.parsingFailed("ZIP entry data out of range: \(entry.name)")
        }
        let compressed = archive.subdata(in: entry.dataOffset..<end)

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

        var output = [UInt8](repeating: 0, count: max(expectedSize, 4096))
        var outputCount = 0

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let inBase = raw.bindMemory(to: Bytef.self).baseAddress else {
                throw DeckImportError.parsingFailed("zlib input buffer unavailable.")
            }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(input.count)

            while true {
                if outputCount >= output.count {
                    output.append(contentsOf: [UInt8](repeating: 0, count: max(32_768, expectedSize / 2)))
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
}
