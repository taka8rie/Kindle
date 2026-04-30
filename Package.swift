// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Kindle",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Kindle", targets: ["Kindle"])
    ],
    targets: [
        .executableTarget(
            name: "Kindle"
        ),
    ]
)
