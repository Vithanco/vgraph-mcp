import Foundation
import Testing

@Suite
struct LogPolicyDocsTests {
    private func read(_ path: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("The Dockerfile sets VGRAPH_LOG_LEVEL to warn")
    func dockerfileSetsLevel() throws {
        #expect(try read("Dockerfile").contains("ENV VGRAPH_LOG_LEVEL=warn"))
    }

    @Test("The README points to the privacy note in VGraph's SECURITY.md")
    func nodeReadmePoints() throws {
        #expect(try read("README.md").contains("https://github.com/Vithanco/VGraph/blob/main/SECURITY.md"))
    }
}
