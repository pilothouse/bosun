// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Workbench",
    platforms: [.macOS(.v13)],
    targets: [
        // C shim exposing libghostty's embedding header to Swift.
        .target(name: "CGhostty"),

        // The AppKit demo app. Links the prebuilt libghostty static archive
        // staged by scripts/build-libghostty.sh into Vendor/libghostty.a.
        .executableTarget(
            name: "Workbench",
            dependencies: ["CGhostty"],
            linkerSettings: [
                .unsafeFlags(["-L", "Vendor", "-lghostty"]),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedLibrary("objc"),
            ]
        ),
    ]
)
