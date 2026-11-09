// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Mitate",
  platforms: [.macOS(.v15)],
  products: [.executable(name: "Mitate", targets: ["Mitate"])],
  dependencies: [
    .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
  ],
  targets: [
    .target(
      name: "MitateCore",
      dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")],
      // cblas_sgemv を非推奨でない新しい CBLAS の宣言で読む。
      swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .executableTarget(
      name: "Mitate",
      dependencies: ["MitateCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "MitateCoreTests",
      dependencies: ["MitateCore"],
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
