#!/usr/bin/env bash

# Build the Rust core as the Apple binary artifact consumed by the Swift package.
# The archive and its checksum are deliberately versioned with the Rust crate: the
# C ABI belongs to that crate, and a later Swift release can pin this immutable asset.

set -euo pipefail

usage() {
    echo "usage: $0 <rust-version> <output-directory>" >&2
    exit 2
}

[[ $# -eq 2 ]] || usage

version=$1
output_argument=$2
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$script_directory/.." && pwd)
manifest="$repository_root/rust/fourdgs/Cargo.toml"
header="$repository_root/rust/fourdgs/include/fourdgs.h"
zlib_header="$repository_root/swift/Sources/CFourDGS/zlib_shim.h"

manifest_version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$manifest" | head -1)
if [[ "$version" != "$manifest_version" ]]; then
    echo "error: requested Rust core $version, but Cargo.toml declares $manifest_version" >&2
    exit 1
fi

for command in cargo rustup lipo xcodebuild swift ditto; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "error: $command is required to build the Apple Rust core" >&2
        exit 1
    }
done

mkdir -p -- "$output_argument"
output_directory=$(cd -- "$output_argument" && pwd)
archive_name="fourdgs-core-apple-$version.xcframework.zip"
archive="$output_directory/$archive_name"
checksum_file="$archive.sha256"
if [[ -e "$archive" || -e "$checksum_file" ]]; then
    echo "error: refusing to overwrite an existing release artifact in $output_directory" >&2
    exit 1
fi

working_directory=$(mktemp -d "${TMPDIR:-/tmp}/fourdgs-xcframework.XXXXXX")
cleanup() {
    rm -rf -- "$working_directory"
}
trap cleanup EXIT

target_directory=${CARGO_TARGET_DIR:-"$repository_root/target"}
targets=(
    x86_64-apple-darwin
    aarch64-apple-darwin
    aarch64-apple-ios
    x86_64-apple-ios
    aarch64-apple-ios-sim
    aarch64-apple-visionos
    aarch64-apple-visionos-sim
)

rustup target add "${targets[@]}"
for target in "${targets[@]}"; do
    cargo rustc \
        --manifest-path "$manifest" \
        --lib \
        --release \
        --target "$target" \
        -- \
        --crate-type staticlib
done

mkdir -p "$working_directory/headers"
cp "$header" "$working_directory/headers/fourdgs.h"
cp "$zlib_header" "$working_directory/headers/zlib_shim.h"
cat > "$working_directory/headers/module.modulemap" <<'EOF'
module CFourDGS {
    header "fourdgs.h"
    header "zlib_shim.h"
    link "z"
    export *
}
EOF

lipo -create \
    "$target_directory/x86_64-apple-darwin/release/libfourdgs.a" \
    "$target_directory/aarch64-apple-darwin/release/libfourdgs.a" \
    -output "$working_directory/libfourdgs-macos.a"
lipo -create \
    "$target_directory/x86_64-apple-ios/release/libfourdgs.a" \
    "$target_directory/aarch64-apple-ios-sim/release/libfourdgs.a" \
    -output "$working_directory/libfourdgs-ios-simulator.a"

xcframework="$working_directory/CFourDGS.xcframework"
xcodebuild -create-xcframework \
    -library "$working_directory/libfourdgs-macos.a" \
    -headers "$working_directory/headers" \
    -library "$target_directory/aarch64-apple-ios/release/libfourdgs.a" \
    -headers "$working_directory/headers" \
    -library "$working_directory/libfourdgs-ios-simulator.a" \
    -headers "$working_directory/headers" \
    -library "$target_directory/aarch64-apple-visionos/release/libfourdgs.a" \
    -headers "$working_directory/headers" \
    -library "$target_directory/aarch64-apple-visionos-sim/release/libfourdgs.a" \
    -headers "$working_directory/headers" \
    -output "$xcframework"

# Prove that this is a SwiftPM binary, not merely a directory xcodebuild accepted.
consumer="$working_directory/consumer"
mkdir -p "$consumer/Sources/ArtifactConsumer" "$consumer/Sources/SmokeTest"
cp -R "$xcframework" "$consumer/CFourDGS.xcframework"
cat > "$consumer/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoreArtifactSmokeTest",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ArtifactConsumer", targets: ["ArtifactConsumer"])],
    targets: [
        .binaryTarget(name: "CFourDGS", path: "CFourDGS.xcframework"),
        .target(name: "ArtifactConsumer", dependencies: ["CFourDGS"]),
        .executableTarget(name: "SmokeTest", dependencies: ["ArtifactConsumer"]),
    ]
)
EOF
cat > "$consumer/Sources/ArtifactConsumer/Core.swift" <<'EOF'
import CFourDGS

public func artifactFormatVersion() -> UInt32 {
    _ = zlibVersion()
    return fourdgs_format_version()
}
EOF
cat > "$consumer/Sources/SmokeTest/main.swift" <<'EOF'
import ArtifactConsumer

precondition(artifactFormatVersion() == 1)
EOF
swift run --package-path "$consumer" SmokeTest

for platform in "iOS" "iOS Simulator" "visionOS" "visionOS Simulator"; do
    (
        cd "$consumer"
        xcodebuild \
            -scheme ArtifactConsumer \
            -destination "generic/platform=$platform" \
            -skipPackagePluginValidation \
            CODE_SIGNING_ALLOWED=NO \
            build | tail -5
    )
done

ditto -c -k --sequesterRsrc --keepParent "$xcframework" "$archive"
checksum=$(swift package compute-checksum "$archive")
printf '%s  %s\n' "$checksum" "$archive_name" > "$checksum_file"

echo "archive=$archive"
echo "swiftpm-checksum=$checksum"
