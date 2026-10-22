// swift-tools-version:5.10
import PackageDescription
import Foundation

// The Info.plist is embedded in the binary so TCC can show the System Audio
// Recording prompt without wrapping the executable in an .app bundle.
let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/EQMenuBar/Info.plist")
    .path

let package = Package(
    name: "EQMenuBar",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "EQMenuBar",
            path: "Sources/EQMenuBar",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist,
                ])
            ]
        )
    ]
)
