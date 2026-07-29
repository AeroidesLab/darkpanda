# DarkPanda 构建与 Actions 执行规范

## 1. 唯一版本规则

- 浏览器版本固定为 Chrome for Testing `149.0.7827.203`。
- Chromium、Skia、LLVM、Chromium Rust、GN、Ninja、Linux sysroot、Zig、V8 和
  zig-v8 fork 的精确版本由 DarkPanda 主仓库的
  `tools/ci/chromium-profile.json` 与根目录 `DEPS` 管理。
- `canvas`、`html5ever`、`wreq`、`boringssl` 每次构建读取各自 `main` 的最新提交。
- `prepare` 在运行开始时把四个最新提交解析成精确 SHA；同一次运行内不再漂移。
- 组件仓库不能选择、更新或覆盖浏览器版本。

固定浏览器必须记录精确 revision；“组件用最新”不代表后续 job 反复读取
`main`。实际规则是：

```text
固定 browser M149 profile
  + 本次开始时四个组件 main 的最新 SHA
  -> 本次不可变的 resolved-inputs.json
```

## 2. 仓库边界

只有 `AeroidesLab/darkpanda` 运行 GitHub Actions、编译、集成测试、打包和发布。
以下短仓库只提供源码、构建入口和组件测试，不保存 Actions workflow 或预编译文件：

| 仓库 | 产物 |
|---|---|
| `AeroidesLab/canvas` | `canvas.dll` / `libcanvas.so` / `libcanvas.dylib` |
| `AeroidesLab/html5ever` | `html5ever.dll` / `libhtml5ever.so` / `libhtml5ever.dylib` |
| `AeroidesLab/wreq` | `wreq.dll` / `libwreq.so` / `libwreq.dylib` |
| `AeroidesLab/boringssl` | `crypto.lib` / `libcrypto.a` |

BoringSSL M149 上游 CMake 的 `crypto` 已包含 `fipsmodule` object，不再生成或同时链接
旧 `fipsmodule.lib`，否则会产生重复符号。

私有源码统一用一个只读 secret：`SOURCE_READ_TOKEN`。迁移期间允许回退读取现有
`CANVAS_READ_TOKEN`，但 token 本身必须对四个组件仓库及固定 V8 绑定仓库
`AeroidesLab/zig-v8-fork`（共五个仓库）具有 Contents: Read 权限。

V8 的获取按平台分化：上游 `lightpanda-io/zig-v8-fork` 的 release 只发布
Linux/macOS/iOS 预编译静态库，没有 Windows 资产。Linux 构建改为消费上游预编译产物：
`prepare` 在运行开始时解析 `releases/latest`，把 release tag 与
`libc_v8_<v8-version>_linux_x86_64.a` 的 SHA-256 固化进 `resolved-inputs.json`，
下载后逐项校验摘要；预编译策略由 `chromium-profile.json` 的
`darkpanda_build.v8.zig_v8_prebuilt` 声明。Windows 继续从
`AeroidesLab/zig-v8-fork` 固定 revision 源码构建 V8。

## 3. 统一组件契约

四个仓库提供相同入口：

```text
tools/build.py|build.ps1|build.sh
  --target <target>
  --profile release
  --out <absolute-dist>
  --jobs <count>
  --toolchain chromium
  --toolchain-dir <absolute-bundle>
```

统一输出：

```text
dist/<target>/
  bin/                         # 动态库
  lib/                         # 静态库、必要 import library
  include/
  metadata/build-info.json
  metadata/test-results.json
  metadata/SHA256SUMS
```

组件脚本必须：

- 只使用 bundle 内的 Clang/clang-cl、LLD、LLVM binutils、Rust/Cargo、GN、Ninja；
- 记录所有实际工具的绝对路径和版本；
- 运行单元测试和纯 C ABI consumer；
- 发现宿主 Clang、rustup Rust 或系统 Ninja 回退时立即失败；
- 失败时仍留下机器可读报告。

DarkPanda `build.zig` 不再进入组件目录构建源码，只接受：

```text
-Dcanvas_dist=<path>
-Dhtml5ever_dist=<path>
-Dwreq_dist=<path>
-Dboringssl_dist=<path>
```

Canvas 使用 ABI v5 的 `cs_canvas_*` 符号；此次只统一文件名和头文件名，不再次改 ABI。

## 4. Chromium 工具链

根目录 `DEPS` 是固定 M149 工具链的权威下载图，保留官方 Chromium `DEPS` 中对应的：

- Skia Git revision；
- LLVM 与 llvm-objdump GCS 对象及 SHA-256；
- Chromium Rust GCS 对象及其配套 LLVM revision；
- GN、Ninja CIPD package/version；
- Linux x64 sysroot GCS 对象及 SHA-256。

Skia 只同步 Canvas CPU-only Ninja 图实际需要的固定源码依赖
（buildtools、FreeType、HarfBuzz、ICU、JPEG、PNG、WebP、Wuffs、zlib）。
禁止运行 standalone Skia 的全量 `git-sync-deps`；它会额外下载未启用的
ANGLE、Dawn、SwiftShader、Vulkan 和 Emscripten 开发树。

每个平台的 `toolchain` job：

```text
checkout darkpanda@本次提交到 gclient/browser
clone 最新 depot_tools
gclient config --name browser --unmanaged <darkpanda-url>
gclient sync --no-history --revision browser@<本次提交>
同步 DEPS 中固定的 Skia CPU 源码依赖
验证版本、目标架构、文件路径和哈希
上传本次内部 chromium-toolchain-<target> artifact
```

标准 bundle：

```text
chromium-toolchain/
  llvm/
  rust/
  buildtools/
  sysroot/       # Linux
  skia/
  metadata/toolchain.json
```

边界说明：

- C/C++ 与 Rust native 组件使用 Chromium 工具链。
- Zig 仍由 Zig 编译器构建；Chromium 不提供 Zig。
- Windows 的 SDK、UCRT、MSVC STL、必要汇编器来自 Visual Studio。
- macOS 的 SDK、framework、签名与 Apple 平台链接工具来自 Xcode。
- CMake 仅作为 BoringSSL 生成器，不允许它选择系统编译器或 Ninja。

## 5. Canvas 专项门禁

Canvas 使用固定 M149 的 CPU-only Skia 配置，并强制：

- 普通 C/C++ 对象含 `-ffp-contract=off`；
- 显式 `_mm256_fmadd_ps` probe 必须反汇编出 `vfmadd`；
- 普通 `a*b+c` probe 不得被收缩为 FMA；
- 不允许全局 `-march=native`、`-mavx2`、`/arch:AVX2` 或 AVX512；
- ML3、ML4、skcms 的 SIMD flag 只能存在于运行时分派目标；
- Ninja 实际编译器必须来自本次 bundle；
- 运行全部 Canvas Rust/backend baseline、编码与 ABI consumer 测试。

Windows 已验证 `clang-cl` + MSVC ABI。Linux 必须实际使用 Chromium sysroot 后才算
通过，不能用“编译成功但读取 runner 系统头文件”代替。

## 6. Actions 流程

```text
prepare
  -> toolchain[platform]
  -> component[canvas/html5ever/wreq/boringssl, platform]
  -> darkpanda[platform]
  -> tests
  -> package
  -> aggregate
  -> release（仅 tag 或明确手动发布）
```

`prepare` 生成 `resolved-inputs.json`。后续 job 只消费其中的精确 SHA。

每个组件单独上传 dist、日志和测试报告。DarkPanda 下载四个 dist 后构建，不能再次
运行组件 Cargo/CMake/GN。

测试至少包含：

- `zig build fmt`、`check`；
- Debug 与 ReleaseFast 全量浏览器测试；
- 动态 Canvas 与 software fallback；
- 非字体 Canvas 像素、PNG/JPEG 字节、Chrome 149 特殊语义与完整错误消息；
- HTML5ever parser/ABI；
- wreq HTTP/TLS/WebSocket；
- BoringSSL WebCrypto；
- 运行时动态库加载、导出符号和依赖闭包；
- 零测试、内存泄漏和 fail-first 行为。

测试运行器同时输出控制台、JSON 和 JUnit；泄漏或零匹配返回失败，fail-first 仍记录
首个失败。

## 7. 报告与发布

所有关键 job 使用 `if: always()` 上传失败报告。报告至少包含：

- 四组件 SHA、DarkPanda SHA、固定 Chrome/Chromium/Skia；
- DEPS/profile hash、depot_tools SHA；
- 工具链观察版本、绝对路径与关键二进制 hash；
- 组件 build/test metadata；
- Zig JSON/JUnit；
- Canvas GN args、Ninja 审计、FMA 反汇编、像素差异；
- 最终包文件与 `SHA256SUMS`。

未通过的平台不得进入 release。普通手动运行、PR 或分支 push 只产生临时 artifact；
tag 或明确勾选发布才允许创建 Release。

## 8. 验收顺序

1. Windows/Linux gclient 工具链同步和预检。
2. 四组件 Windows/Linux 统一构建与测试。
3. DarkPanda Windows/Linux 消费四个 dist，跑全量语义与像素测试。
4. Windows/Linux 打包及失败报告审计。
5. macOS x64/arm64 按相同契约接入 Chromium LLVM/Rust + Xcode SDK。
6. 四平台全部通过后恢复正式聚合发布。

每一阶段都必须由真实 Actions 日志证明，不能只以本地 Windows 编译成功作为跨平台结论。

当前 `prebuilt-binaries.yml` 实现第 1–4 阶段。手动触发默认上传临时
Windows/Linux artifact；显式设置 `publish_release=true` 时可发布已经通过编译、
安装、CLI 启动、四个动态库加载和归档后复验的 Windows/Linux 预发行版。完整浏览器
语义测试继续生成诊断报告，但暂不作为该预发行门。第 5–6 阶段的 macOS 与正式稳定版
仍需后续接入，不能描述为当前已经完成。
