import Foundation

/// Two .hae layouts, both ultimately LZFSE:
///  A) HealthMetrics dailies: "HAE1" magic, then repeating [uint32 BE length][LZFSE block].
///  B) Workouts and Routes:   a bare LZFSE stream, possibly several concatenated.
/// An LZFSE stream ends with the 4-byte marker "bvx$", which is how B is split.
func lzfse(_ block: Data) throws -> Data { try (block as NSData).decompressed(using: .lzfse) as Data }

func decodeHAE(_ url: URL) throws -> (Data, String) {
    let blob = try Data(contentsOf: url)
    var out = Data()

    if blob.prefix(4) == Data("HAE1".utf8) {
        var offset = 4, chunks = 0
        while offset + 4 <= blob.count {
            let len = blob.subdata(in: offset..<(offset + 4)).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            offset += 4
            let end = offset + Int(len)
            guard len > 0, end <= blob.count else { break }
            out.append(try lzfse(blob.subdata(in: offset..<end)))
            offset = end; chunks += 1
        }
        return (out, "HAE1 container, \(chunks) chunk(s)")
    }

    guard blob.prefix(3) == Data("bvx".utf8) else {
        throw NSError(domain: "hae", code: 1, userInfo: [NSLocalizedDescriptionKey: "unrecognised header \(blob.prefix(8).map { String(format: "%02x", $0) }.joined())"])
    }
    let terminator = Data("bvx$".utf8)
    var start = 0, streams = 0
    while start < blob.count {
        guard let r = blob.range(of: terminator, in: start..<blob.count) else { break }
        out.append(try lzfse(blob.subdata(in: start..<r.upperBound)))
        start = r.upperBound; streams += 1
    }
    return (out, "bare LZFSE, \(streams) stream(s)")
}

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    print("\n=== \(url.lastPathComponent) ===")
    do {
        let (data, how) = try decodeHAE(url)
        let raw = try Data(contentsOf: url)
        print("  \(how): \(raw.count) -> \(data.count) bytes")
        let object = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        print(String(data: pretty, encoding: .utf8)!.split(separator: "\n").prefix(38).joined(separator: "\n"))
        try data.write(to: URL(fileURLWithPath: "/tmp/haedec/\(url.deletingPathExtension().lastPathComponent).json"))
    } catch {
        print("  FAILED: \(error.localizedDescription)")
    }
}
