import Foundation

/// Decompresses zstd payloads used by modern Anki packages (`collection.anki21b`).
enum ZstdDecompressor {
    private static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    static func isZstd(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return Array(data.prefix(4)) == zstdMagic
    }

    /// Stream-decompress to disk so large AnKing collections don't jetsam the app.
    static func decompressToFile(_ data: Data, destination: URL) throws {
        guard isZstd(data) else {
            try data.write(to: destination, options: .atomic)
            return
        }

        let dctx = ZSTD_createDCtx()
        guard let dctx else {
            throw DeckImportError.parsingFailed("Couldn't create zstd decoder.")
        }
        defer { ZSTD_freeDCtx(dctx) }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let inChunk = 256 * 1024
        var outBuffer = [UInt8](repeating: 0, count: 512 * 1024)
        var inputOffset = 0
        var totalWritten = 0

        while inputOffset < data.count {
            let sliceLen = min(inChunk, data.count - inputOffset)
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    throw DeckImportError.parsingFailed("Invalid zstd input buffer.")
                }
                var input = ZSTD_inBuffer(
                    src: base.advanced(by: inputOffset),
                    size: sliceLen,
                    pos: 0
                )

                while input.pos < input.size {
                    var outputPos = 0
                    let code: Int = outBuffer.withUnsafeMutableBytes { outRaw in
                        var output = ZSTD_outBuffer(
                            dst: outRaw.baseAddress!,
                            size: outRaw.count,
                            pos: 0
                        )
                        let result = ZSTD_decompressStream(dctx, &output, &input)
                        outputPos = output.pos
                        return Int(result)
                    }

                    if ZSTD_isError(code) != 0 {
                        let name = String(cString: ZSTD_getErrorName(code))
                        throw DeckImportError.parsingFailed("zstd decompress failed: \(name)")
                    }

                    if outputPos > 0 {
                        try handle.write(contentsOf: Data(outBuffer.prefix(outputPos)))
                        totalWritten += outputPos
                    }
                }
            }
            inputOffset += sliceLen
        }

        guard totalWritten > 0 else {
            throw DeckImportError.parsingFailed("zstd decompress produced empty output.")
        }
    }

    static func decompress(_ data: Data) throws -> Data {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zstd-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: temp) }
        try decompressToFile(data, destination: temp)
        return try Data(contentsOf: temp, options: [.mappedIfSafe])
    }
}
