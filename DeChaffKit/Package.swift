// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Embedded into the dechaff-mcp binary so macOS has a bundle identifier and a
// speech-recognition usage description to show when it asks for permission.
let mcpInfoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/dechaff-mcp/Info.plist").path

let package = Package(
    name: "DeChaffKit",
    platforms: [.macOS("26.0")],
    products: [
        // Audio processing, transcription, cut-point refinement and episode tagging — no UI.
        .library(name: "DeChaffCore", targets: ["DeChaffCore"]),
        // Model Context Protocol server exposing DeChaff to AI assistants.
        .executable(name: "dechaff-mcp", targets: ["dechaff-mcp"]),
    ],
    targets: [
        .target(name: "DeChaffCore"),
        .target(name: "MCPServer"),
        .executableTarget(
            name: "dechaff-mcp",
            dependencies: ["DeChaffCore", "MCPServer"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", mcpInfoPlist]),
            ]
        ),
        .testTarget(name: "DeChaffCoreTests", dependencies: ["DeChaffCore"]),
        .testTarget(name: "MCPServerTests", dependencies: ["MCPServer"]),
    ],
    swiftLanguageModes: [.v5]
)
