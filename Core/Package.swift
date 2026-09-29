// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DraftZeroCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DraftZeroCore", targets: ["DraftZeroCore"])
    ],
    dependencies: [
        // 发布版精确锁定（配合提交的 Package.resolved，保证干净 clone 可复现）。
        // 2026-09-29：上游 0.1.14/1.4.0 的 tag 曾被本机伪造缓存污染，
        // 已清除并重新对齐真实上游（swift-transformers 0.1.24 搭配主线 Jinja）。
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        // 本机语义向量的分词器（T-004 / R-004）；推理用系统 CoreML，模型随包分发
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "0.1.24"),
    ],
    targets: [
        .target(name: "DraftZeroCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Transformers", package: "swift-transformers"),
        ], resources: [
            .copy("Resources/e5-small-onnx")
        ]),
        // R-004 质量关口评估器（收尾方案 P0）：走生产导入/引擎/队列，非 Python spike。
        .executableTarget(name: "dz-eval", dependencies: ["DraftZeroCore"]),
        .testTarget(name: "DraftZeroCoreTests", dependencies: ["DraftZeroCore"], resources: [
            .copy("Fixtures")
        ])
    ]
)
