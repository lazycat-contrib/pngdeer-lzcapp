#!/usr/bin/env bash
# pngdeer 静态站构建：克隆上游源码 → 构建 WebAssembly（单线程 + 多线程）→ 组装 site/
#
# 运行环境：GitHub Actions 的 ubuntu runner（自带 rustup + clang/llvm-ar，无需 root）。
# 懒猫官方 action 的构建环境没有 root 权限，所以这里只用 runner 已有的工具链，
# 不调用 apt/apk。缺工具时给出明确报错。
set -euo pipefail

VERSION="${LAZYCAT_VERSION:-${VERSION:-}}"
echo "==> building pngdeer version: ${VERSION:-<default branch>}"

# 上游没有 release 资产（只有 tag），因此按版本号取 tag，缺省则用默认分支
UPSTREAM_TAG=""
if [ -n "$VERSION" ]; then
  UPSTREAM_TAG="v${VERSION}"
fi

rm -rf upstream
rm -rf site

# 克隆上游：优先指定 tag，失败则回退到默认分支。
# GitHub Actions runner 直连 GitHub 即可；本地若需要代理，可用
# HTTPS_PROXY/HTTP_PROXY 环境变量（git 原生支持）。
clone_upstream() {
  local ref_args=()
  if [ -n "$1" ]; then
    ref_args=(--branch "$1")
  fi
  git clone --depth 1 "${ref_args[@]}" \
    https://github.com/heydeer/pngdeer.git upstream
}

CLONE_OK=0
if [ -n "$UPSTREAM_TAG" ]; then
  echo "==> cloning upstream tag ${UPSTREAM_TAG}"
  if clone_upstream "$UPSTREAM_TAG" 2>&1 | sed 's/^/    /'; then
    CLONE_OK=1
  else
    echo "    tag ${UPSTREAM_TAG} unavailable, falling back to the default branch"
    rm -rf upstream
  fi
fi
if [ "$CLONE_OK" != "1" ]; then
  echo "==> cloning upstream default branch"
  clone_upstream ""
fi
cd upstream

# ---- 工具链 ----
export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v rustup >/dev/null 2>&1; then
  echo "ERROR: rustup is required but not installed" >&2
  exit 1
fi

# wasm32 需要 clang/llvm-ar：oxipng 的 libdeflate 是 C，要能编到 wasm32。
# CI 镜像里只有带版本后缀的 clang-18 / llvm-ar-18，没有无后缀的 llvm-ar，
# 所以先按同版本号找 llvm-ar，找不到再退回通用候选。
CC_WASM=""
for candidate in /usr/bin/clang-18 /usr/bin/clang-17 /usr/bin/clang-16 /usr/bin/clang /usr/local/swift/usr/bin/clang; do
  if [ -x "$candidate" ] && "$candidate" -print-targets 2>/dev/null | grep -q "wasm32"; then
    CC_WASM="$candidate"
    break
  fi
done
if [ -z "$CC_WASM" ]; then
  echo "ERROR: no clang with the wasm32 target found (need clang 16+)" >&2
  exit 1
fi
CC_DIR="$(dirname "$CC_WASM")"
CC_SUFFIX="${CC_WASM##*/clang}"   # "-18" 或 ""（无后缀）
AR_WASM=""
for candidate in "${CC_DIR}/llvm-ar${CC_SUFFIX}" "${CC_DIR}/llvm-ar" \
                 /usr/bin/llvm-ar-18 /usr/bin/llvm-ar-17 /usr/bin/llvm-ar-16 /usr/bin/llvm-ar; do
  if [ -x "$candidate" ]; then
    AR_WASM="$candidate"
    break
  fi
done
if [ -z "$AR_WASM" ]; then
  echo "ERROR: llvm-ar is required to build the wasm32 libdeflate" >&2
  exit 1
fi
echo "==> using clang ${CC_WASM} and llvm-ar ${AR_WASM}"

echo "==> installing Rust targets"
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
# 装到用户可写目录并前置 PATH：CI 里 cargo 可能在 /usr/local/cargo 等 root 目录，
# 写不进去。$HOME/.cargo/bin 是 rustup 的默认位置，runner 用户可写。
WASM_BINDGEN_DIR="$HOME/.cargo/bin"
mkdir -p "$WASM_BINDGEN_DIR"
export PATH="$WASM_BINDGEN_DIR:$PATH"
if [ -x "${WASM_BINDGEN_DIR}/wasm-bindgen" ] && \
   "${WASM_BINDGEN_DIR}/wasm-bindgen" --version 2>/dev/null | grep -q "^${WASM_BINDGEN_VERSION}$"; then
  echo "    already installed"
else
  TMP_DIR="$(mktemp -d)"
  curl --proto '=https' -sSfL "https://github.com/wasm-bindgen/wasm-bindgen/releases/download/${WASM_BINDGEN_VERSION}/wasm-bindgen-${WASM_BINDGEN_VERSION}-x86_64-unknown-linux-musl.tar.gz" | tar -xz -C "$TMP_DIR"
  cp "$TMP_DIR"/*/wasm-bindgen "${WASM_BINDGEN_DIR}/"
  rm -rf "$TMP_DIR"
fi
wasm-bindgen --version

echo "==> building WebAssembly packages"
# 上游 web/build.sh 从 LLVM_BIN 目录里拼出无后缀的 clang/llvm-ar，而 CI 镜像里
# 只有带版本后缀的 clang-18/llvm-ar-18。这里做一个临时目录，用软链补上无后缀的名字。
TOOLCHAIN_DIR="$(mktemp -d)"
ln -sf "$CC_WASM" "${TOOLCHAIN_DIR}/clang"
ln -sf "$AR_WASM" "${TOOLCHAIN_DIR}/llvm-ar"
LLVM_BIN="$TOOLCHAIN_DIR" sh web/build.sh
rm -rf "$TOOLCHAIN_DIR"

# ---- 组装静态站 ----
echo "==> assembling the static site"
mkdir -p ../site
cp -RL web/index.html web/worker.js web/THIRD_PARTY_LICENSES.txt web/brand web/samples web/pkg web/pkg-mt ../site/
cd ..

# 完整性校验：WASM 产物与入口页必须存在，否则 fail（避免发布坏包）
# wasm-bindgen 产出的文件名是 <crate>_bg.wasm（--target web 模式）
for required in site/index.html site/worker.js site/pkg/pngdeer_wasm.js site/pkg/pngdeer_wasm_bg.wasm site/pkg-mt/pngdeer_wasm_bg.wasm; do
  if [ ! -f "$required" ]; then
    echo "ERROR: missing build output: ${required}" >&2
    ls -R site 2>&1 | head -30 >&2
    exit 1
  fi
done
FILE_COUNT="$(find site -type f | wc -l)"
echo "==> site built: $(du -sh site | cut -f1), ${FILE_COUNT} files"
