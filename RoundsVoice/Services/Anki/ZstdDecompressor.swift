import Foundation

/// Decompresses zstd payloads used by modern Anki packages (`collection.anki21b`).
/// Uses the official Facebook zstd single-file decoder (BSD / GPLv2 dual license).
enum ZstdDecompressor {
    private static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    static func isZstd(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return Array(data.prefix(4)) == zstdMagic
    }

    static func decompress(_ data: Data) throws -> Data {
        guard isZstd(data) else { return data }

        let bound = data.withUnsafeBytes { raw -> UInt64 in
            ZSTD_getFrameContentSize(raw.baseAddress, data.count)
        }

        if bound == ZSTD_CONTENTSIZE_ERROR {
            throw DeckImportError.parsingFailed("Invalid zstd frame in Anki package.")
        }

        var capacity: Int
        if bound == ZSTD_CONTENTSIZE_UNKNOWN {
            // AnKing packages typically expand ~8–10×.
            capacity = max(data.count * 12, 8_000_000)
        } else {
            capacity = Int(bound)
        }

        for _ in 0..<6 {
            var output = Data(count: capacity)
            let decoded: Int = output.withUnsafeMutableBytes { outBuf in
                data.withUnsafeBytes { inBuf in
                    Int(
                        ZSTD_decompress(
                            outBuf.baseAddress,
                            capacity,
                            inBuf.baseAddress,
                            data.count
                        )
                    )
                }
            }

            if ZSTD_isError(decoded) == 0 {
                output.count = decoded
                return output
            }

            let name = String(cString: ZSTD_getErrorName(decoded))
            if name.contains("dstSize") || name.contains("Destination buffer is too small") {
                capacity *= 2
                continue
            }
            throw DeckImportError.parsingFailed("zstd decompress failed: \(name)")
        }

        throw DeckImportError.parsingFailed("zstd decompress ran out of buffer space.")
    }
}
