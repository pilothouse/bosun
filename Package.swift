// swift-tools-version: 5.9
import PackageDescription

// Clean Architecture as a compiler-enforced target graph (see CLAUDE.md).
// Dependency direction is all inward:  Bosun → Infrastructure → Application → Domain.
// `Domain` has `dependencies: []`, so it physically cannot import another layer — the
// compiler rejects it before SwiftLint ever runs. SwiftLint is left with the two jobs the
// compiler genuinely can't do: banning always-importable system frameworks (AppKit, Metal,
// Network, …) in the inner layers, and catching transitive skip-imports.
let package = Package(
    name: "Bosun",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Bosun", targets: ["Bosun"]),
    ],
    dependencies: [
        // Dedicated plugins repo: avoids pulling SwiftLint's full dependency tree into the
        // build graph. Functionally identical rules to realm/SwiftLint.
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.57.0"),
        // GitHub-flavored Markdown parser (Swift `Markdown` over C `cmark-gfm`). Source-only —
        // no linker settings of its own — so it's added to the Bosun target alone and leaves
        // the vendored libghostty link flags untouched. Renders issue/PR/comment bodies (issue #27).
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.6.0"),
        // In-app auto-update via a signed appcast (issue #57). Distributed as a binary xcframework,
        // so the linker references `@rpath/Sparkle.framework`; scripts/package-app.sh copies the
        // framework into Bosun.app/Contents/Frameworks and the rpath below resolves it at runtime.
        // App-layer only — Sparkle is confined to Sources/Bosun/UpdaterController.swift.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // C shim exposing libghostty's embedding header to Swift. (App-layer detail.)
        .target(name: "CGhostty"),

        // ── Domain: center. Knows nothing about UI, transport, or storage. ──
        .target(
            name: "Domain",
            dependencies: [],                       // ← the rule, as code
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin",
                              package: "SwiftLintPlugins")]
        ),

        // ── Application: use cases. Orchestrates Domain; defines ports. ──
        .target(
            name: "Application",
            dependencies: ["Domain"],               // ← inward only
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin",
                              package: "SwiftLintPlugins")]
        ),

        // ── Infrastructure: adapters. Implements Application's ports. ──
        .target(
            name: "Infrastructure",
            dependencies: ["Application", "Domain"],
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin",
                              package: "SwiftLintPlugins")]
        ),

        // ── App (composition root) + AppKit/Metal/libghostty views. Sees everything. ──
        // Links the prebuilt libghostty static archive staged by scripts/build-libghostty.sh
        // into Vendor/libghostty.a. The SwiftLint plugin is intentionally NOT attached here:
        // the App layer is the unconstrained composition layer, and running the linter over the
        // dense AppKit views would only police style, not architecture. Inner-layer purity (the
        // part the compiler can't see) is enforced on Domain/Application above.
        .executableTarget(
            name: "Bosun",
            dependencies: ["CGhostty", "Application", "Infrastructure", "Domain",
                           .product(name: "Markdown", package: "swift-markdown"),
                           .product(name: "Sparkle", package: "Sparkle")],
            // The app icon (a copy of Assets/AppIcon/bosun-pipe.png). Bare SwiftPM executables have no
            // .app bundle/Info.plist, so the dock icon is set at runtime from this bundled resource
            // via NSApp.applicationIconImage (see AppDelegate).
            resources: [.process("Resources")],
            linkerSettings: [
                // The `-rpath @executable_path/../Frameworks` lets the packaged app find the embedded
                // Sparkle.framework (copied there by package-app.sh). It must go through `-Xlinker` —
                // the Swift driver forwards `-L`/`-l` itself but not a bare `-rpath`. A `swift run` dev
                // build resolves the framework through SPM's own build-dir rpath, so both paths work.
                .unsafeFlags(["-L", "Vendor", "-lghostty",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
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

        // ── Contract tests on public APIs (a human writes/reviews these). ──
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "ApplicationTests", dependencies: ["Application"]),
        // Infrastructure adapters are exercised through their ports against a stubbed
        // URLSession + JSON fixtures — no live network. Drives `GitHubAPIClient`'s REST/GraphQL
        // decoding, pagination, and status→error mapping.
        .testTarget(
            name: "InfrastructureTests",
            dependencies: ["Infrastructure", "Application", "Domain"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
