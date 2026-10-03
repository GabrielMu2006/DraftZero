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
        // ORT C 桥（纯 C 宿主跑推理；Swift 宿主进程的 ORT 每节点派发放大 ~700x，
        // 见 Windows/evidence/ENGINE-PERF-BASELINE-2026-10-03.md 附录）。
        .target(name: "OrtBridge", publicHeadersPath: "include"),
        .target(name: "DraftZeroCore", dependencies: [
            "OrtBridge",
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Transformers", package: "swift-transformers"),
        ], resources: [
            .copy("Resources/e5-small-onnx")
        ]),
        // R-004 质量关口评估器（收尾方案 P0）：走生产导入/引擎/队列，非 Python spike。
        .executableTarget(name: "dz-eval", dependencies: ["DraftZeroCore"]),
        // 引擎性能基准（2026-10-03）：生产推理微基准 + 规模曲线；只读生产 API，不改引擎。
        .executableTarget(name: "dz-bench", dependencies: ["DraftZeroCore"]),
        .testTarget(name: "DraftZeroCoreTests", dependencies: ["DraftZeroCore"], resources: [
            .copy("Fixtures")
        ])
    ]
)
