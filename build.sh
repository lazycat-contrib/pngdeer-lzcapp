#!/usr/bin/env bash
# pngdeer 静态站构建：克隆上游源码 → 构建 WebAssembly（单线程 + 多线程）→ 组装 site/
# 由 LazyCat GitHub Action 的 buildscript 在每次构建时执行
set -euo pipefail

VERSION="${LAZYCAT_VERSION:-${VERSION:-}}"
echo "==> building pngdeer version: ${VERSION:-<default branch>}"

# 上游没有 release 资产可用（只有 tag），因此按版本号取 tag，缺省则用默认分支
UPSTREAM_TAG=""
if [ -n "$VERSION" ]; then
  UPSTREAM_TAG="v${VERSION}"
fi

rm -rf upstream site
CLONE_OK=0
if [ -n "$UPSTREAM_TAG" ]; then
  echo "==> cloning upstream tag ${UPSTREAM_TAG}"
  if git clone --depth 1 --branch "$UPSTREAM_TAG" https://github.com/heydeer/pngdeer.git upstream 2>/dev/null; then
    CLONE_OK=1
  fi
fi
if [ "$CLONE_OK" != "1" ]; then
  echo "==> cloning upstream default branch"
  git clone --depth 1 https://github.com/heydeer/pngdeer.git upstream
fi
cd upstream

# ---- 构建 WebAssembly ----
# web/vercel-build.sh 是上游自带的 Linux 构建脚本（装 clang/rustup/nightly/wasm-bindgen，
# 产出 web/pkg 单线程与 web/pkg-mt 多线程两个 WASM 包），但它面向 Vercel：会额外
# 把站点拷进 dist/。这里直接调用 web/build.sh 产出 pkg/ 与 pkg-mt/，再自己组装。

echo "==> installing build toolchain"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends clang llvm curl ca-certificates >/dev/null

if ! command -v rustup >/dev/null 2>&1; then
  echo "==> installing rustup"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal
  export PATH="$HOME/.cargo/bin:$PATH"
fi
export PATH="$HOME/.cargo/bin:$PATH"
rustup toolchain install stable --profile minimal --target wasm32-unknown-unknown
rustup default stable
rustup toolchain install nightly --profile minimal --component rust-src --target wasm32-unknown-unknown

# wasm-bindgen-cli 必须与 web/wasm/Cargo.toml 里固定的版本一致
echo "==> installing wasm-bindgen-cli"
WASM_BINDGEN_VERSION="$(sed -n 's/^wasm-bindgen = "=\(.*\)"$/\1/p' web/wasm/Cargo.toml)"
if [ -z "$WASM_BINDGEN_VERSION" ]; then
  echo "ERROR: cannot resolve the wasm-bindgen version from web/wasm/Cargo.toml" >&2
  exit 1
fi
echo "    wasm-bindgen version: ${WASM_BINDGEN_VERSION}"
TMP_DIR="$(mktemp -d)"
curl --proto '=https' -sSfL "https://github.com/wasm-bindgen/wasm-bindgen/releases/download/${WASM_BINDGEN_VERSION}/wasm-bindgen-${WASM_BINDGEN_VERSION}-x86_64-unknown-linux-musl.tar.gz" | tar -xz -C "$TMP_DIR"
cp "$TMP_DIR"/*/wasm-bindgen "$(dirname "$(command -v cargo)")/"
rm -rf "$TMP_DIR"

echo "==> building WebAssembly packages"
LLVM_BIN=/usr/bin sh web/build.sh

# ---- 组装静态站 ----
echo "==> assembling the static site"
mkdir -p ../site
cp -RL web/index.html web/worker.js web/THIRD_PARTY_LICENSES.txt web/brand web/samples web/pkg web/pkg-mt ../site/
cd ..

# 完整性校验：WASM 产物与入口页必须存在，否则 fail（避免发布坏包）
for required in site/index.html site/worker.js site/pkg/pngdeer_wasm.js site/pkg/pngdeer_wasm.wasm; do
  if [ ! -f "$required" ]; then
    echo "ERROR: missing build output: ${required}" >&2
    ls -R site 2>&1 | head -30 >&2
    exit 1
  fi
done
FILE_COUNT="$(find site -type f | wc -l)"
echo "==> site built: $(du -sh site | cut -f1), ${FILE_COUNT} files"
