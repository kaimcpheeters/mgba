// SPDX-License-Identifier: MPL-2.0
// swiftc src/platform/apple/GameDex/RecentROMs.swift tools/gamedex/recent-roms-test.swift -o /tmp/gamedex-recent-test
import Foundation

@main struct RecentROMsTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let games = root.appendingPathComponent("Games")
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["A.gba", "B.zip", "C.gba", "D.gba"].map { games.appendingPathComponent($0) }
        for url in urls { try Data().write(to: url) }
        var store = RecentROMs(games: games, legacyPath: urls[0].path)
        assert(store.paths == [urls[0].path])
        for url in urls { try store.remember(url) }
        assert(store.paths == [urls[3].path, urls[2].path, urls[1].path])
        try store.remember(urls[2])
        assert(store.paths == [urls[2].path, urls[3].path, urls[1].path])
        assert(RecentROMs(games: games).paths == store.paths)
        let moved = root.appendingPathComponent("NewContainer/Games")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: games, to: moved)
        let relocated = RecentROMs(games: moved)
        assert(relocated.paths == ["C.gba", "D.gba", "B.zip"].map { moved.appendingPathComponent($0).path })
        try Data("broken".utf8).write(to: relocated.storage)
        assert(RecentROMs(games: moved).paths.isEmpty)
        print("PASS: three-ROM limit, deduplication, recency, persistence, legacy migration, container relocation, malformed history")
    }
}
