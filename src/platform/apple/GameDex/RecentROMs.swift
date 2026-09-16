// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Paths to managed ROM copies, newest first. Kept beside Games so sandbox
/// container moves and test libraries do not share the user's recent history.
struct RecentROMs {
    let storage: URL
    private(set) var paths: [String]

    init(games: URL, legacyPath: String? = nil) {
        storage = games.appendingPathComponent("recent-roms.json")
        let saved = (try? Data(contentsOf: storage)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        var seen = Set<String>()
        paths = (saved ?? legacyPath.map { [$0] } ?? []).compactMap { path in
            var url = URL(fileURLWithPath: path).standardizedFileURL
            // iOS can relocate an app's data container during an update.
            let relocated = games.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: url.path), url.deletingLastPathComponent().lastPathComponent == "Games",
               FileManager.default.fileExists(atPath: relocated.path) { url = relocated }
            return seen.insert(url.path).inserted ? url.path : nil
        }.prefix(3).map { $0 }
    }

    mutating func remember(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        let next = Array(([path] + paths.filter { $0 != path }).prefix(3))
        try JSONEncoder().encode(next).write(to: storage, options: .atomic)
        paths = next
    }
}
