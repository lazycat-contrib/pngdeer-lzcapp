# pngdeer-lzcapp

[heydeer/pngdeer](https://github.com/heydeer/pngdeer) 的懒猫微服打包。

有损 PNG 压缩：逐张图片挑选合适的质量（SSIMULACRA2 评分），效果接近 TinyPNG。
命令行与网页版跑的是同一份 Rust 代码、产出同样的字节。

**压缩全程在浏览器本地用 WebAssembly 完成，图片不会上传到任何服务器。**

## 交付方式（静态站，无容器镜像）

上游的 Web 版是纯前端 + WebAssembly，仓库里不含编译产物（`web/pkg/`、`web/pkg-mt/`
被 gitignore），所以需要在 CI 里现场构建：

1. [`build.sh`](build.sh)（`lzc-build.yml` 的 buildscript）克隆上游对应 tag →
   安装 clang / rustup（stable + nightly）/ wasm-bindgen-cli → 运行上游的
   `web/build.sh` 产出 **单线程**（`web/pkg`）与 **多线程**（`web/pkg-mt`）两套 WASM
   → 组装 `site/`
2. `contentdir: ./site` 把静态站打包进 LPK
3. [`lzc-manifest.yml`](lzc-manifest.yml) 用平台内置文件服务
   （`backend: file:///lzcapp/pkg/content/`）提供页面

### 关于多线程

多线程构建（rayon 线程池）需要页面处于**跨源隔离**状态（`SharedArrayBuffer`）。
本应用通过 response 阶段的 inject 为所有响应补上：

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

若这些头未生效，上游会自动降级为单线程构建——功能完整，只是大图压缩更慢。

## 版本与发布

- 版本对应上游 tag：`package.yml` 的 `0.1.1` ↔ 上游 `v0.1.1`
- 每日定时任务比对上游最新 tag，自动 bump 并发布到**喵喵（私有）商店**
- 手动触发时可填 `version` 指定版本

## 版权

上游 [heydeer/pngdeer](https://github.com/heydeer/pngdeer)（MIT；第三方依赖各自许可见
`web/THIRD_PARTY_LICENSES.txt`）；本仓库仅为打包，不修改上游内容。
