import Foundation

/// モデルのファイルが手元にあるか。worker が使う既定の type のファイルについて
struct ModelFile: Equatable {
    var fetched: Bool
    /// 途中まで取得したバイト数
    var partial: Int64
    var size: Int64

    var fraction: Double {
        guard size > 0 else { return 0 }
        return fetched ? 1 : min(1, Double(partial) / Double(size))
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }
}

/// `speech models --json` で、モデルのファイルを取得済みか、どこまで取得したかを調べる
enum ModelCatalog {
    /// モデル名 → ファイルの状態。speech が見つからないか失敗したら空
    @MainActor
    static func load() async -> [String: ModelFile] {
        guard let exe = SpeechWorker.resolveExecutable() else { return [:] }
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["models", "--json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return [:] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (try? parse(data)) ?? [:]
        }.value
    }

    static func parse(_ data: Data) throws -> [String: ModelFile] {
        struct Catalog: Decodable { var models: [Model] }
        struct Model: Decodable { var name: String; var type: String?; var files: [File]? }
        struct File: Decodable { var type: String?; var size: Int64; var fetched: Bool; var partial: Int64? }

        var result: [String: ModelFile] = [:]
        for m in try JSONDecoder().decode(Catalog.self, from: data).models {
            let files = m.files ?? []
            // 名前だけで指定したときに使われる type のファイル
            guard let f = files.first(where: { $0.type == m.type }) ?? files.first else { continue }
            result[m.name] = ModelFile(fetched: f.fetched, partial: f.partial ?? 0, size: f.size)
        }
        return result
    }
}
