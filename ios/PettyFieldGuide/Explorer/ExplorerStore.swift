import Foundation
import Combine
import Compression

/// Catalogue of optional park-wide GIS layers and their on-device state.
struct ExplorerLayer: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var description: String
    var color: String
    var publisher: String
    var sourceUrl: String
    var scope: String
    var updatePolicy: String
    var fetchedAt: String
    var sourceUpdatedAt: String
    var file: String
    var sha256: String
    var count: Int
    var compressedBytes: Int
    var unpackedBytes: Int
    var fields: [String: String]
}

struct ExplorerCatalog: Codable, Sendable {
    var schema: Int
    var generatedAt: String
    var layers: [ExplorerLayer]
}

@MainActor
final class ExplorerStore: ObservableObject {
    static let shared = ExplorerStore()

    enum LayerState: Equatable {
        case absent
        case downloading(Double)
        case ready(bytes: Int)
        case failed(String)
    }

    @Published private(set) var catalog: ExplorerCatalog?
    @Published private(set) var states: [String: LayerState] = [:]
    private let directory = AppDirectories.subdirectory("explorer")
    private var loaded: [String: GeoJSON.Document] = [:]

    private init() {
        catalog = try? JSONDecoder().decode(ExplorerCatalog.self, from: BundleContent.data("explorer-catalog.json", subdirectory: "Geo"))
        for layer in catalog?.layers ?? [] {
            let url = fileURL(layer)
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int { states[layer.id] = .ready(bytes: size) } else { states[layer.id] = .absent }
        }
    }

    func fileURL(_ layer: ExplorerLayer) -> URL { directory.appendingPathComponent("\(layer.id)-\(layer.sha256.prefix(16)).geojson.gz") }

    /// Replaces the bundled catalogue with the server's when one is configured, so regenerated packs resolve.
    func refreshCatalog() async {
        guard ServerConfig.shared.isConfigured else { return }
        let tmp = directory.appendingPathComponent(".catalog.partial")
        guard (try? await ConditionsClient.shared.download(path: "data/explorer/catalog.json", to: tmp, progress: { _ in })) != nil,
              let data = try? Data(contentsOf: tmp), let fetched = try? JSONDecoder().decode(ExplorerCatalog.self, from: data) else { return }
        try? FileManager.default.removeItem(at: tmp)
        catalog = fetched
        for layer in fetched.layers where states[layer.id] == nil {
            states[layer.id] = FileManager.default.fileExists(atPath: fileURL(layer).path) ? .ready(bytes: (try? FileManager.default.attributesOfItem(atPath: fileURL(layer).path)[.size] as? Int) ?? 0) : .absent
        }
        for layer in fetched.layers {
            if case .ready = states[layer.id] ?? .absent, !FileManager.default.fileExists(atPath: fileURL(layer).path) { states[layer.id] = .absent }
        }
    }

    func state(_ id: String) -> LayerState { states[id] ?? .absent }

    var downloadedBytes: Int { states.values.reduce(0) { if case .ready(let b) = $1 { return $0 + b }; return $0 } }

    /// Downloads to a temp file, verifies the SHA-256, then atomically replaces the previous copy.
    func download(_ layer: ExplorerLayer) async {
        states[layer.id] = .downloading(0)
        let tmp = directory.appendingPathComponent(".\(layer.id).partial")
        do {
            _ = try await ConditionsClient.shared.download(path: layer.file, to: tmp) { [weak self] p in Task { @MainActor in self?.states[layer.id] = .downloading(p) } }
            let data = try Data(contentsOf: tmp)
            guard SHA256Digest.hex(data) == layer.sha256 else {
                try? FileManager.default.removeItem(at: tmp)
                states[layer.id] = .failed("Checksum mismatch; the download was discarded and the previous copy kept.")
                return
            }
            try AtomicFile.replace(fileURL(layer), with: tmp)
            loaded[layer.id] = nil
            states[layer.id] = .ready(bytes: data.count)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            states[layer.id] = FileManager.default.fileExists(atPath: fileURL(layer).path) ? .ready(bytes: (try? FileManager.default.attributesOfItem(atPath: fileURL(layer).path)[.size] as? Int) ?? 0) : .failed(error.localizedDescription)
        }
    }

    func remove(_ layer: ExplorerLayer) {
        try? FileManager.default.removeItem(at: fileURL(layer))
        loaded[layer.id] = nil
        states[layer.id] = .absent
    }

    func document(for layer: ExplorerLayer) async -> GeoJSON.Document? {
        if let d = loaded[layer.id] { return d }
        let url = fileURL(layer)
        let doc = await Task.detached(priority: .userInitiated) { () -> GeoJSON.Document? in
            guard let gz = try? Data(contentsOf: url), let raw = Gzip.decompress(gz) else { return nil }
            return try? GeoJSON.parse(raw)
        }.value
        if let doc { loaded[layer.id] = doc }
        return doc
    }
}

enum Gzip {
    /// Minimal gzip reader: skips the header, inflates the raw deflate stream.
    static func decompress(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b, data[2] == 8 else { return nil }
        let flags = data[3]
        var index = 10
        if flags & 0x04 != 0 { let xlen = Int(data[index]) | Int(data[index + 1]) << 8; index += 2 + xlen }
        if flags & 0x08 != 0 { while index < data.count && data[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x10 != 0 { while index < data.count && data[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x02 != 0 { index += 2 }
        guard index < data.count - 8 else { return nil }
        let isize = Int(data[data.count - 4]) | Int(data[data.count - 3]) << 8 | Int(data[data.count - 2]) << 16 | Int(data[data.count - 1]) << 24
        let payload = data.subdata(in: index..<(data.count - 8))
        let capacity = max(isize, payload.count * 4)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outBuf -> Int in
            payload.withUnsafeBytes { inBuf -> Int in
                compression_decode_buffer(outBuf.bindMemory(to: UInt8.self).baseAddress!, capacity, inBuf.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }
}
