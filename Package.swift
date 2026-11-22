// swift-tools-version: 6.1

import PackageDescription

// Built against the VGraph checkout this repository is cloned into, as the
// plugins are: a release ships the engine from that one commit (VGraph ADR 0040).
// The package is known by that folder's name, so it must be called VGraph.
let vgraph = "VGraph"

let package = Package(
    name: "vgraph-mcp",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "vgraph-mcp", targets: ["vgraph-mcp"]),
        .executable(name: "vgraph-mcp-http", targets: ["vgraph-mcp-http"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        // Shared MCP tool definitions (used by both stdio and HTTP servers)
        .target(
            name: "VGraphMCPTools",
            dependencies: [
                .product(name: "App", package: vgraph),
                .product(name: "VGraph", package: vgraph),  // RenderResult, alongside the ports that return it
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.enableExperimentalFeature("Extern")]
        ),

        // MCP server executable (stdio transport — local CLI)
        .executableTarget(
            name: "vgraph-mcp",
            dependencies: [
                "VGraphMCPTools",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/VGraphMCP",
            swiftSettings: [.enableExperimentalFeature("Extern")]
        ),

        // The HTTP layer of the hosted server, a library so it can be tested.
        .target(
            name: "VGraphMCPHTTPKit",
            dependencies: [
                "VGraphMCPTools",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.enableExperimentalFeature("Extern")]
        ),

        // MCP server executable (HTTP transport — Cloud Run)
        .executableTarget(
            name: "vgraph-mcp-http",
            dependencies: [
                "VGraphMCPTools",
                "VGraphMCPHTTPKit",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/VGraphMCPHTTP",
            swiftSettings: [.enableExperimentalFeature("Extern")]
        ),

        .testTarget(
            name: "VGraphMCPTests",
            dependencies: [
                "vgraph-mcp", "VGraphMCPTools",
                .product(name: "VGraph", package: vgraph),
                .product(name: "VGraphSVG", package: vgraph),
                .product(name: "VGraphTestSupport", package: vgraph),
            ],
            swiftSettings: [.enableExperimentalFeature("Extern")]
        ),
        .testTarget(
            name: "VGraphMCPHTTPTests",
            dependencies: [
                "VGraphMCPHTTPKit", "VGraphMCPTools",
                .product(name: "VGraphTestSupport", package: vgraph),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            swiftSettings: [.enableExperimentalFeature("Extern")]
        ),
        // The repository's own files: the image, the justfile, the docs.
        .testTarget(
            name: "RepositoryTests",
            swiftSettings: [.enableExperimentalFeature("Extern")]
        ),
    ]
)
