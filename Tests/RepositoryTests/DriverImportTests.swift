// The MCP servers are drivers: they reach adapters through App's composition and
// never name one. VGraph's ArchitectureTest held this while they lived there.

import Foundation
import Testing

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // RepositoryTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root

private func swiftFiles(under path: String) throws -> [URL] {
    let root = repoRoot.appendingPathComponent(path)
    let files = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
        .filter { $0.hasSuffix(".swift") }
        .map { root.appendingPathComponent($0) }
    try #require(!files.isEmpty, "no Swift files under \(path) — did the folder move?")
    return files
}

private func importedModules(in source: String) -> [String] {
    source.split(separator: "\n").compactMap { line in
        let words = line.split(separator: " ").drop { $0.hasPrefix("@") || $0 == "public" }
        guard words.first == "import", let module = words.dropFirst().first else { return nil }
        return String(module.prefix { $0 != "." })
    }
}

@Test func driversImportNoAdapterModules() throws {
    let adapters: Set<String> = ["VGraphSVG", "VGLanguage", "VGraphvizLib"]
    let drivers = ["Sources/VGraphMCP", "Sources/VGraphMCPHTTP", "Sources/VGraphMCPHTTPKit", "Sources/VGraphMCPTools"]
    let violations = try drivers.flatMap { try swiftFiles(under: $0) }.flatMap { file in
        importedModules(in: try String(contentsOf: file, encoding: .utf8))
            .filter { adapters.contains($0) }
            .map { "\(file.lastPathComponent): import \($0)" }
    }
    #expect(violations.isEmpty, "adapter imports in a driver: \(violations)")
}
