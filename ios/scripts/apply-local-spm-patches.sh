#!/bin/bash
# Apply KoKo offline/local-path SPM manifest patches after cloning Packages/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export KOOK_PACKAGES="$ROOT/Packages"
P="$KOOK_PACKAGES"

patch_citadel() {
  cat > "$P/Citadel/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Citadel",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Citadel",
            targets: ["Citadel"]
        ),
    ],
    dependencies: [
        .package(path: "../swift-nio-ssh"),
        .package(path: "../swift-nio"),
        .package(path: "../swift-log"),
        .package(path: "../BigInt"),
        .package(path: "../swift-crypto"),
        .package(path: "../ColorizeSwift"),
    ],
    targets: [
        .target(name: "CCitadelBcrypt"),
        .target(
            name: "Citadel",
            dependencies: [
                .target(name: "CCitadelBcrypt"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "CitadelServerExample",
            dependencies: [
                "Citadel",
                .product(name: "ColorizeSwift", package: "ColorizeSwift")
            ]),
        .testTarget(
            name: "CitadelTests",
            dependencies: [
                "Citadel",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
EOF
}

patch_swiftterm() {
  cat > "$P/SwiftTerm/Package.swift" <<'EOF'
// swift-tools-version:6.2
// KoKo offline-friendly manifest: library product only (no tooling deps).

import PackageDescription
import Foundation

let environment = ProcessInfo.processInfo.environment
let excludeAppleSources = environment["SWIFTTERM_EXCLUDE_APPLE"] == "1"
#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = excludeAppleSources ? ["Apple", "Mac", "iOS"] : []
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SwiftTermBuildInfoGenerator",
            path: "Sources/SwiftTermBuildInfoGenerator"
        ),
        .plugin(
            name: "SwiftTermBuildInfoPlugin",
            capability: .buildTool(),
            dependencies: ["SwiftTermBuildInfoGenerator"]
        ),
        .target(
            name: "SwiftTerm",
            dependencies: [],
            path: "Sources/SwiftTerm",
            exclude: platformExcludes + [
                "Mac/README.md",
                "Apple/Metal/Shaders.metal",
            ],
            plugins: [
                .plugin(name: "SwiftTermBuildInfoPlugin")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
EOF
}

patch_nio_ssh() {
  python3 - <<'PY'
import os, re
from pathlib import Path
p = Path(os.environ["KOOK_PACKAGES"]) / "swift-nio-ssh" / "Package.swift"
text = p.read_text()
if 'path: "../swift-nio"' in text:
    print("swift-nio-ssh already local")
else:
    new_deps = '''    dependencies: [
        .package(path: "../swift-nio"),
        .package(path: "../swift-crypto"),
        .package(path: "../swift-atomics"),
    ],'''
    text2, n = re.subn(
        r"    dependencies: \[[\s\S]*?\n    \],\n    targets:",
        new_deps + "\n    targets:",
        text,
        count=1,
    )
    if n != 1:
        raise SystemExit("failed to patch swift-nio-ssh dependencies")
    p.write_text(text2)
    print("patched swift-nio-ssh")
PY
}

patch_nio() {
  python3 - <<'PY'
import os
from pathlib import Path
p = Path(os.environ["KOOK_PACKAGES"]) / "swift-nio" / "Package.swift"
text = p.read_text()
local = '''package.dependencies += [
    .package(path: "../swift-atomics"),
    .package(path: "../swift-collections"),
    .package(path: "../swift-system"),
]

'''
marker = 'if Context.environment["SWIFTCI_USE_LOCAL_DEPS"] == nil'
if 'path: "../swift-collections"' in text and marker not in text:
    print("swift-nio already local")
elif marker in text:
    start = text.find(marker)
    end = text.find("// ---    STANDARD CROSS-REPO", start)
    if end < 0:
        raise SystemExit("nio anchor missing")
    p.write_text(text[:start] + local + text[end:])
    print("patched swift-nio")
else:
    raise SystemExit("unexpected swift-nio Package.swift")
PY
}

patch_crypto() {
  python3 - <<'PY'
import os
from pathlib import Path
p = Path(os.environ["KOOK_PACKAGES"]) / "swift-crypto" / "Package.swift"
text = p.read_text()
local = '''package.dependencies += [
    .package(path: "../swift-asn1")
]

'''
marker = 'if ProcessInfo.processInfo.environment["SWIFTCI_USE_LOCAL_DEPS"] == nil'
if 'path: "../swift-asn1"' in text and marker not in text:
    print("swift-crypto already local")
elif marker in text:
    start = text.find("// Switch between local and remote")
    if start < 0:
        start = text.find(marker)
    end = text.find("// ---    STANDARD CROSS-REPO", start)
    if end < 0:
        raise SystemExit("crypto anchor missing")
    p.write_text(text[:start] + local + text[end:])
    print("patched swift-crypto")
else:
    raise SystemExit("unexpected swift-crypto Package.swift")
PY
}

patch_citadel
patch_swiftterm
patch_nio_ssh
patch_nio
patch_crypto
echo "Applied KoKo local SPM patches."
