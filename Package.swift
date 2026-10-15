// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InterviewCopilot",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "InterviewCopilot", targets: ["InterviewCopilot"]),
        .executable(name: "HireImportCheck", targets: ["HireImportCheck"])
    ],
    dependencies: [.package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.8")],
    targets: [
        .target(name: "CopilotCore"),
        .target(name: "LocalASR", dependencies: [.product(name: "sherpa-onnx", package: "sherpa-onnx")], resources: [.copy("model-manifest.json")]),
        .executableTarget(name: "ASRCheck", dependencies: ["LocalASR"]),
        .testTarget(name: "LocalASRTests", dependencies: ["LocalASR"]),
        .target(name: "CodexIntegration"),
        .executableTarget(name: "CodexConnectionCheck", dependencies: ["CodexIntegration", "CopilotCore"]),
        .testTarget(name: "CodexIntegrationTests", dependencies: ["CodexIntegration"]),
        .target(name: "HireIntegration", dependencies: ["CopilotCore"]),
        .executableTarget(name: "InterviewCopilot", dependencies: ["CopilotCore", "HireIntegration", "CodexIntegration", "LocalASR"]),
        .testTarget(name: "InterviewCopilotTests", dependencies: ["InterviewCopilot"]),
        .executableTarget(name: "HireImportCheck", dependencies: ["CopilotCore", "HireIntegration"]),
        .testTarget(name: "CopilotCoreTests", dependencies: ["CopilotCore"]),
        .testTarget(name: "HireIntegrationTests", dependencies: ["HireIntegration"])
    ],
    swiftLanguageModes: [.v5]
)
