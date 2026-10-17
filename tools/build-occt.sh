#!/bin/zsh
# Builds Open CASCADE (OCCT) as static libraries for iPad, the iPad simulator and the Mac,
# then merges each platform's libraries into one libOCCT.a and wraps them in OCCT.xcframework.
#
#   tools/build-occt.sh            build every platform that isn't built yet
#   tools/build-occt.sh macos      build only one platform (ios | sim | macos)
#
# Static linking is fine for the LGPL because Formwerk's own source is public (MPL-2.0),
# so anyone can relink the app against a modified OCCT. OCCT is built unmodified.
set -euo pipefail

ROOT="${0:A:h:h}"
SRC="$ROOT/Vendor/OCCT/src"
OUT="$ROOT/Vendor/OCCT"
TAG="V7_9_3"
CMAKE="$ROOT/tools/.venv/bin/cmake"
NINJA="$ROOT/tools/.venv/bin/ninja"
JOBS=$(sysctl -n hw.ncpu)

if [[ ! -x "$CMAKE" ]]; then
  python3 -m venv "$ROOT/tools/.venv"
  "$ROOT/tools/.venv/bin/pip" install -q cmake ninja
fi
if [[ ! -d "$SRC" ]]; then
  git clone -q --depth 1 --branch "$TAG" https://github.com/Open-Cascade-SAS/OCCT.git "$SRC"
fi

# Only geometry and STEP exchange: no OCCT viewer (we draw with Metal), no Tcl/Draw, no FreeType.
COMMON=(
  -G Ninja -D CMAKE_MAKE_PROGRAM="$NINJA"
  -D CMAKE_BUILD_TYPE=Release
  -D BUILD_LIBRARY_TYPE=Static
  -D BUILD_MODULE_FoundationClasses=ON
  -D BUILD_MODULE_ModelingData=ON
  -D BUILD_MODULE_ModelingAlgorithms=ON
  -D BUILD_MODULE_Visualization=OFF
  -D BUILD_MODULE_ApplicationFramework=OFF
  -D BUILD_MODULE_DataExchange=OFF
  -D BUILD_MODULE_DETools=OFF
  -D BUILD_MODULE_Draw=OFF
  -D BUILD_ADDITIONAL_TOOLKITS="TKDE;TKXSBase;TKDESTEP"
  -D BUILD_DOC_Overview=OFF
  -D BUILD_SAMPLES_QT=OFF
  -D USE_FREETYPE=OFF -D USE_FREEIMAGE=OFF -D USE_RAPIDJSON=OFF -D USE_DRACO=OFF
  -D USE_TK=OFF -D USE_TBB=OFF -D USE_VTK=OFF -D USE_OPENGL=OFF -D USE_GLES2=OFF
  -D USE_XLIB=OFF -D USE_FFMPEG=OFF -D USE_OPENVR=OFF -D USE_D3D=OFF
  -D CMAKE_C_FLAGS="-fvisibility=hidden"
  -D CMAKE_CXX_FLAGS="-fvisibility=hidden -fvisibility-inlines-hidden"
  -D INSTALL_DIR_INCLUDE=inc -D INSTALL_DIR_LIB=lib -D INSTALL_DIR_RESOURCE=res
)

build_platform() {
  local name=$1 system=$2 sdk=$3 target=$4
  local build="$OUT/build-$name" install="$OUT/install-$name"
  if [[ -f "$install/lib/libOCCT.a" ]]; then echo "✓ $name already built"; return; fi
  echo "▶ Configuring OCCT for $name…"
  "$CMAKE" -S "$SRC" -B "$build" "${COMMON[@]}" \
    -D CMAKE_SYSTEM_NAME="$system" \
    -D CMAKE_OSX_SYSROOT="$(xcrun --sdk $sdk --show-sdk-path)" \
    -D CMAKE_OSX_ARCHITECTURES=arm64 \
    -D CMAKE_OSX_DEPLOYMENT_TARGET="$target" \
    -D INSTALL_DIR="$install" > "$OUT/configure-$name.log"
  echo "▶ Building OCCT for $name ($JOBS jobs)…"
  "$CMAKE" --build "$build" --parallel "$JOBS" > "$OUT/build-$name.log"
  "$CMAKE" --install "$build" > /dev/null
  # One merged archive per platform keeps the Xcode setup to a single library.
  libtool -static -o "$install/lib/libOCCT.a" "$install"/lib/libTK*.a 2> /dev/null
  rm -rf "$build"   # the build tree is several GB, and disk space is tight
  echo "✓ $name done"
}

want=${1:-all}
[[ $want == all || $want == ios ]]   && build_platform ios   iOS    iphoneos         17.0
[[ $want == all || $want == sim ]]   && build_platform sim   iOS    iphonesimulator  17.0
[[ $want == all || $want == macos ]] && build_platform macos Darwin macosx           14.0

if [[ -f "$OUT/install-ios/lib/libOCCT.a" && -f "$OUT/install-sim/lib/libOCCT.a" && -f "$OUT/install-macos/lib/libOCCT.a" ]]; then
  rm -rf "$OUT/OCCT.xcframework"
  xcodebuild -create-xcframework \
    -library "$OUT/install-ios/lib/libOCCT.a" \
    -library "$OUT/install-sim/lib/libOCCT.a" \
    -library "$OUT/install-macos/lib/libOCCT.a" \
    -output "$OUT/OCCT.xcframework" > /dev/null
  # The headers are the same on every platform, so one copy is used for all of them.
  rm -rf "$OUT/include" && cp -R "$OUT/install-macos/inc" "$OUT/include"
  echo "✓ OCCT.xcframework ready"
fi
