#!/bin/bash
# Regenerate docs/hover.gif on macOS with Xcode and ffmpeg.
# Usage: Scripts/render-hover-gif.sh [QA-directory]
# The demo-only hosted unit test renders SwiftUI and a vector cursor offscreen.
# The clean wallpaper plate was reconstructed once from the original GIF so the
# current GIF is never an input. The QA directory receives the contact sheet and
# per-frame pointer positions. It defaults to a temporary directory.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [[ $# -gt 0 ]]; then
    mkdir -p "$1"
    qa=$(cd "$1" && pwd)
else
    qa=$(mktemp -d)
fi
frames="$work/frames"

TEST_RUNNER_AGENTNOTCH_RENDER_HOVER_DIR="$frames" \
TEST_RUNNER_AGENTNOTCH_HEADLESS_TEST_HOST=1 \
xcodebuild -project AgentNotch.xcodeproj -scheme AgentNotch -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -parallel-testing-enabled NO \
    -derivedDataPath "${AGENTNOTCH_HOVER_DERIVED_DATA:-$work/build}" \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    PRODUCT_BUNDLE_IDENTIFIER=io.github.neeeeeeessa.AgentNotchHoverFixture \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG AGENTNOTCH_DEMO' \
    -only-testing:AgentNotchTests/HoverGIFRenderTests test

ffmpeg -v error -loop 1 -framerate 24 -i docs/hover-wallpaper.png \
    -framerate 24 -i "$frames/frame-%04d.png" \
    -filter_complex '[1:v]scale=640:870:flags=lanczos[notch];[0:v][notch]overlay=shortest=1:format=rgb,split[scene][colors];[colors]palettegen=stats_mode=diff[palette];[scene][palette]paletteuse=dither=sierra2_4a:diff_mode=rectangle' \
    -loop 0 "$work/hover.gif"

ffmpeg -y -v error -i "$work/hover.gif" \
    -vf "select='eq(n,0)+eq(n,16)+eq(n,36)+eq(n,66)+eq(n,130)+eq(n,198)+eq(n,270)+eq(n,344)',scale=320:435,tile=4x2" \
    -frames:v 1 -update 1 "$qa/hover-contact-sheet.png"
cp "$frames/pointer.csv" "$qa/hover-pointer.csv"
cp "$work/hover.gif" docs/hover.gif
printf 'Contact sheet: %s/hover-contact-sheet.png\n' "$qa"
