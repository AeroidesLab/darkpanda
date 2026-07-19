<p align="center">
  <img src="assets/darkpanda-icon.png" alt="DarkPanda icon" width="190">
</p>

<h1 align="center">DarkPanda</h1>

<p align="center">
  面向浏览器自动化与嵌入式 Python 的轻量浏览器运行时<br>
  A lightweight browser runtime for automation and in-process Python embedding
</p>

## 项目简介 / Overview

DarkPanda 基于 Lightpanda 的 Zig 浏览器代码演进，集成了固定版本的 V8、
Zig DOM/Web API、标准 CDP、进程内 C/Python FFI、Rust `wreq` HTTP/TLS 传输层，
以及真实的 CPU rust-skia Canvas 后端。

DarkPanda is derived from the Lightpanda Zig browser codebase. It combines a
pinned V8 runtime, a Zig DOM/Web API layer, standard CDP, an in-process C/Python
FFI, the Rust `wreq` HTTP/TLS stack, and a real CPU rust-skia Canvas backend.

项目目标是补齐自动化和当前挑战验收所需的浏览器行为，而不是实现完整渲染引擎，
也不声称等价于 Chromium 的 Blink、GPU、多进程隔离或全部 Web Platform Tests。
Chrome 149 是一套统一的兼容性配置和实测边界，不是“完整 Chrome 替代品”的宣传。

The goal is the browser behavior required by automation and the current
acceptance contract, not a complete rendering engine or a drop-in Chromium
replacement. Chrome 149 compatibility is a coherent, measured profile rather
than a claim of full Blink, GPU, process-isolation, or WPT parity.

## 核心特性 / Features

- Windows x64、Linux x64、macOS x64 与 macOS arm64 原生预构建；Windows
  构建不经过 WSL。
- V8 `14.9.207.35`，对应项目的 Chrome 149 兼容性配置。
- 标准 CDP 服务与不启动子进程的进程内 Python API。
- `wreq` 是唯一 HTTP/TLS 后端；运行时不包含 libcurl。
- `wreq.dll` / `libwreq.so` 使用 wreq、wreq-util 与 btls/BoringSSL。
- CPU rust-skia Canvas 动态后端，软件 fallback 默认关闭。
- HTTP 响应缓存、Cookie、IndexedDB 和页面状态均为内存型；不写磁盘浏览器缓存。
- 每次正式构建使用唯一目录，并记录源码、工具、输入和运行时文件的 SHA-256。
- 正式构建在离线模式下进行，不复用旧对象、旧安装目录或旧 `zig-out`。

## Runtime artifact set

一次构建只有在下面的文件来自同一个 manifest 且相邻部署时才有效：

| Role | Windows | Linux | macOS |
| --- | --- | --- | --- |
| Browser / CDP | `darkpanda.exe` | `darkpanda` | `darkpanda` |
| C/Python FFI | `darkpanda.dll` | `libdarkpanda.so` | `libdarkpanda.dylib` |
| HTTP/TLS | `wreq.dll` | `libwreq.so` | `libwreq.dylib` |
| CPU Canvas | `darkpanda_canvas_backend.dll` | `libdarkpanda_canvas_backend.so` | `libdarkpanda_canvas_backend.dylib` |
| HTML parser | `darkpanda_html5ever.dll` | `libdarkpanda_html5ever.so` | `libdarkpanda_html5ever.dylib` |

主库相对自己的模块目录加载 wreq、Canvas 和 HTML parser，而不是相对
`python.exe` 或宿主程序目录加载。部署或打包时不要单独复制其中一个文件。

## GitHub Actions 预构建 / Prebuilt releases

[`prebuilt-binaries.yml`](.github/workflows/prebuilt-binaries.yml) 在四个原生 runner
上构建可移植运行时：

- `windows-2022`：`x86_64-windows-msvc`
- `ubuntu-22.04`：`x86_64-linux-gnu`（降低 Rust/系统库所需的最低 glibc 版本）
- `macos-15-intel`：`x86_64-macos`
- `macos-15`：`aarch64-macos`

工作流只在 `v*` tag 或手动 `workflow_dispatch` 时运行，避免每次提交都重新编译
V8。tag 自动发布 GitHub Release；手动运行默认只生成 Actions artifact，只有同时
启用 `publish_release` 并填写 `release_tag` 才会发布 Release。

组织策略禁用了跨仓库 deploy key，因此工作流不使用个人的广域 `repo` token。
两个小型 Zig build wrapper 按固定提交导出为源码 archive，存放在本仓库的
`build-dependencies-v1` GitHub Release；workflow 使用本次运行自己的
`GITHUB_TOKEN` 下载。archive 文件名、源码提交和 SHA-256 都固定在 workflow 中，
解压前会校验哈希并拒绝绝对路径、`..`、链接和设备文件。该依赖 Release 不包含
DarkPanda 浏览器二进制。

V8 是唯一允许跨运行缓存的编译产物。缓存 manifest 固定平台、target、V8 版本、
V8 revision、zig-v8 源码提交、Zig 版本、archive 大小与 SHA-256；缓存中不包含
DarkPanda EXE/DLL/SO/dylib。更改手动输入 `dependency_cache_generation` 可以显式
废弃整组 V8 缓存。

每轮 DarkPanda 构建都使用包含 run ID/attempt 的空 install、Zig cache 和 Cargo
target 目录。发布配置为 Zig `ReleaseFast`，Rust `opt-level=3`、fat LTO、单
codegen unit、无增量编译，同时保留 `panic=unwind`，因为三个 Rust FFI 边界都用
`catch_unwind` 隔离 panic。公共 x64 包使用可移植 CPU baseline，不使用 runner
专属的 `native` 指令集；macOS 构建固定 deployment target 12.0，与 Chromium/V8
的链接目标保持一致，并避免无意绑定
runner 当前的 macOS 15。

每个平台在上传前都会运行 CLI version、Python FFI 和真实 rust-skia 像素 smoke。
归档中包含浏览器、FFI、wreq、Canvas、html5ever 全部运行时库；Windows 包还包含
VS runner 官方 Redistributable 目录中的 `msvcp140.dll`、`vcruntime140.dll` 和
`vcruntime140_1.dll`。同时包含 C headers、Python 包装层、README、许可证、三个
Cargo lockfile、动态依赖报告、`BUILD-INFO.json` 和包内 `SHA256SUMS`。外层另附
`<archive>.sha256`；聚合 job 再验证四个平台并生成
总 `SHA256SUMS`。Unix 使用 `.tar.gz` 以保留执行位，Windows 使用 `.zip`。

## Python API

设置 `DARKPANDA_BIN_DIR` 为某个已验证 artifact set 的 `bin` 目录：

```python
import os
from pathlib import Path

from darkpanda import CanvasDriver, ClientProfile, Runtime

bin_dir = Path(os.environ["DARKPANDA_BIN_DIR"]).resolve()
windows = os.name == "nt"

with Runtime(
    library_path=bin_dir / ("darkpanda.dll" if windows else "libdarkpanda.so"),
    wreq_library_path=bin_dir / ("wreq.dll" if windows else "libwreq.so"),
    canvas_library_path=bin_dir / (
        "darkpanda_canvas_backend.dll"
        if windows
        else "libdarkpanda_canvas_backend.so"
    ),
    canvas_driver=CanvasDriver.DYNAMIC,
    profile=ClientProfile.CHROME149,
    locale="en-US",
    timezone="UTC",
) as runtime:
    with runtime.new_page() as page:
        page.navigate("https://example.com/")
        print(page.evaluate("({ title: document.title, url: location.href })"))
```

该 API 直接在 Python 进程中加载 DarkPanda，不绑定 CDP 端口，也不启动浏览器
子进程。ABI 生命周期和 Windows 加载细节见 [WINDOWS_NATIVE.md](WINDOWS_NATIVE.md)。

## 构建模型 / Build model

构建分为两个严格分离的阶段：

1. **Dependency provisioning（允许联网）**：准备 V8、Cargo vendor、Skia、
   Zig package source cache 和固定工具。
2. **Formal build（禁止联网）**：将源码型依赖复制到新的唯一构建目录，编译全部
   运行时文件，执行 FFI/Canvas smoke，复核输入未变化，最后生成 manifest。

正式构建不接受“某个看起来能用的旧 DLL/SO”。Linux 必须传入完整 V8 bundle
manifest，而不是松散的 `libc_v8.a`；Windows 只有在 manifest 内容和 ACTIVE 指针
完成双重验证后才激活产物。

### Repository layout

仓库必须保持以下兄弟目录关系：

```text
workspace/
├── browser/                 # this repository
├── zig-v8-fork/
└── boringssl-zig-fork/
```

另外准备一个不依赖具体盘符的依赖根目录，并通过环境变量指定：

```text
$DARKPANDA_DEPS_ROOT/
├── cargo-vendor/
├── skia-0.99.0/
├── zig-package-cache/
│   ├── windows/
│   └── linux/
├── windows/
│   ├── v8/c_v8_standalone.lib
│   └── boringssl-prefix/lib/
│       ├── crypto.lib
│       └── fipsmodule.lib
└── linux-tools/
    ├── gn
    ├── ninja
    └── cmake/
```

`cargo-vendor` 必须覆盖以下三个锁文件：

- `src/wreq_transport/Cargo.lock`
- `src/html5ever/Cargo.lock`
- `src/canvas_backend/Cargo.lock`

可在允许联网的 provisioning 阶段生成：

```bash
cargo vendor --locked \
  --manifest-path src/wreq_transport/Cargo.toml \
  --sync src/html5ever/Cargo.toml \
  --sync src/canvas_backend/Cargo.toml \
  "$DARKPANDA_DEPS_ROOT/cargo-vendor"
```

正式脚本会运行 `tools/prepare_cargo_vendor.py`，只在唯一构建副本中应用可复现的
平台补丁，不修改作为输入的 vendor 目录。

## Windows x64 formal build

### Prerequisites

- Windows x64。
- Visual Studio 2022 C++ Build Tools 与 Windows 10/11 SDK。
- Zig `0.15.2`。
- Rust `1.88+` / Cargo，并安装 `x86_64-pc-windows-msvc` target。
- Python 3、CMake、Ninja、LLVM `clang-cl`，且均可从 `PATH` 找到。
- `$DARKPANDA_DEPS_ROOT`、仓库、Cargo vendor、Skia 和 Zig package cache 位于
  同一个卷。Skia 根目录应保持较短，避免 Windows/rust-skia 长路径限制。

在 Visual Studio Developer PowerShell 中运行：

```powershell
$DepsRoot = (Resolve-Path $env:DARKPANDA_DEPS_ROOT).Path

$V8Archive = if ($env:DARKPANDA_V8_ARCHIVE) {
    (Resolve-Path $env:DARKPANDA_V8_ARCHIVE).Path
} else {
    Join-Path $DepsRoot 'windows\v8\c_v8_standalone.lib'
}

$BoringSslDirectory = if ($env:DARKPANDA_BORINGSSL_DIRECTORY) {
    (Resolve-Path $env:DARKPANDA_BORINGSSL_DIRECTORY).Path
} else {
    Join-Path $DepsRoot 'windows\boringssl-prefix\lib'
}

.\tools\Build-AcceptanceArtifactSet.ps1 `
  -V8Archive $V8Archive `
  -V8Version '14.9.207.35' `
  -BoringSslDirectory $BoringSslDirectory `
  -CargoVendorDirectory (Join-Path $DepsRoot 'cargo-vendor') `
  -SkiaSourceDirectory (Join-Path $DepsRoot 'skia-0.99.0') `
  -ZigPackageSourceCache (Join-Path $DepsRoot 'zig-package-cache\windows') `
  -Zig (Get-Command zig).Source `
  -Python (Get-Command python).Source `
  -CMake (Get-Command cmake).Source `
  -Ninja (Get-Command ninja).Source `
  -ClangCl (Get-Command clang-cl).Source `
  -Optimize ReleaseFast `
  -Jobs 2
```

脚本会依次完成：

1. 撤销旧 ACTIVE，停止当前仓库内的旧 DarkPanda 进程。
2. 固定源码、V8、BoringSSL、Cargo vendor、Skia 和工具 SHA-256。
3. 创建唯一的 Zig/Cargo/TEMP/HOME/运行时目录。
4. 离线编译 wreq、html5ever、rust-skia、EXE 和 FFI DLL。
5. 运行 CLI version、Python FFI、V8 identity 和 Canvas pixel smoke。
6. 再次验证源码、依赖和候选文件没有变化。
7. 原子发布 `artifacts/builds/ACTIVE.json`。

验证 ACTIVE 指针与 manifest：

```powershell
$Active = Get-Content '.\artifacts\builds\ACTIVE.json' -Raw | ConvertFrom-Json
$ActualManifestHash = (Get-FileHash -Algorithm SHA256 $Active.manifestPath).Hash

if ($ActualManifestHash -ne $Active.manifestSha256) {
    throw 'ACTIVE manifest SHA-256 mismatch'
}

$Active
```

### Provision Windows native archives from source

如果没有依赖包，可在允许联网阶段从兄弟仓库生成 WebCrypto BoringSSL：

```powershell
Push-Location '..\boringssl-zig-fork'
$BoringPrefix = Join-Path $env:DARKPANDA_DEPS_ROOT 'windows\boringssl-prefix'
zig build `
  -Dtarget=x86_64-windows-msvc `
  -Doptimize=ReleaseFast `
  -p $BoringPrefix
$env:DARKPANDA_BORINGSSL_DIRECTORY = Join-Path $BoringPrefix 'lib'
Pop-Location
```

生成固定 V8 archive：

```powershell
Push-Location '..\zig-v8-fork'
zig build `
  -Dtarget=x86_64-windows-msvc `
  -Doptimize=ReleaseFast `
  build-v8
Pop-Location
```

V8 输出目录由 GN 参数哈希决定。将生成的 `c_v8_standalone.lib` 的绝对路径写入
`DARKPANDA_V8_ARCHIVE`，不要通过文件时间自动选择“最新 archive”。

## Linux x64 / WSL formal build

### Prerequisites

- x86_64 glibc Linux，或 WSL2 中的 glibc 发行版。
- Zig `0.15.2`、Rust/Cargo、Python 3、Git、Bash、CMake、GN 和 Ninja。
- 完整 Cargo vendor、Skia `0.99.0` 源树与 Zig package source cache。
- WSL 下构建目录可以放在挂载盘；Zig native cache 必须位于 Linux 原生文件系统，
  因为 DrvFS/9p 会锁定正在执行的 Zig build runner。

先设置可移植变量：

```bash
export DARKPANDA_REPO_ROOT="$(pwd -P)"
export DARKPANDA_DEPS_ROOT="$(realpath "${DARKPANDA_DEPS_ROOT:?set DARKPANDA_DEPS_ROOT}")"
export DARKPANDA_CACHE_ROOT="${DARKPANDA_CACHE_ROOT:-$(dirname "$DARKPANDA_REPO_ROOT")/.cache}"
export DARKPANDA_NATIVE_CACHE_ROOT="${DARKPANDA_NATIVE_CACHE_ROOT:-$HOME/.cache/darkpanda/native-zig}"
```

### 1. Provision the Linux V8 bundle

该步骤允许联网，只在 V8 或工具链版本变化时运行：

```bash
bash tools/Acquire-LinuxV8Bundle.sh \
  --zig "$(command -v zig)" \
  --zig-package-cache "$DARKPANDA_DEPS_ROOT/zig-package-cache/linux" \
  --native-cache-root "$DARKPANDA_NATIVE_CACHE_ROOT" \
  --output-root "$DARKPANDA_CACHE_ROOT/v8-linux" \
  --jobs 2
```

成功后，手动选择该次已完成 bundle 的精确 manifest，不要按修改时间猜测：

```bash
export DARKPANDA_V8_BUNDLE_MANIFEST='/absolute/path/to/completed/v8-bundle/manifest.json'
test -f "$DARKPANDA_V8_BUNDLE_MANIFEST"
```

manifest 会绑定 V8 revision、Chrome 149 版本、Chromium sysroot、PIC/TLS 模式、
archive 大小和 SHA-256，并包含 shared-library link smoke 证明。

### 2. Run the offline formal build

```bash
bash tools/Build-LinuxArtifactSet.sh \
  --zig "$(command -v zig)" \
  --cargo "$(command -v cargo)" \
  --rustc "$(command -v rustc)" \
  --v8-bundle-manifest "$DARKPANDA_V8_BUNDLE_MANIFEST" \
  --cargo-vendor "$DARKPANDA_DEPS_ROOT/cargo-vendor" \
  --skia-source "$DARKPANDA_DEPS_ROOT/skia-0.99.0" \
  --skia-gn "$DARKPANDA_DEPS_ROOT/linux-tools/gn" \
  --skia-ninja "$DARKPANDA_DEPS_ROOT/linux-tools/ninja" \
  --cmake-root "$DARKPANDA_DEPS_ROOT/linux-tools/cmake" \
  --zig-package-cache "$DARKPANDA_DEPS_ROOT/zig-package-cache/linux" \
  --native-cache-root "$DARKPANDA_NATIVE_CACHE_ROOT" \
  --output-root "$DARKPANDA_CACHE_ROOT/linux-builds" \
  --jobs 2
```

Linux 脚本会生成新的 `linux-x64-<UTC>-<nonce>` 目录，并在其中写入 manifest、
候选文件哈希、Python FFI attestation 和真实 Skia smoke。Linux 正式构建不会读取
Windows ACTIVE，也不会复用另一轮 Linux install 目录。

## 开发构建与正式构建 / Development vs formal builds

`zig build` 适合快速开发，但其输出不能作为正式验收产物。只有上述 formal build
脚本会执行唯一目录、输入证明、运行时 attestation、候选文件前后哈希和 manifest
发布协议。

如果只需验证 Linux Skia 组件，可运行：

```bash
bash tools/Build-LinuxCanvasSmoke.sh --help
```

## Acceptance boundary

固定验收合同位于
[`artifacts/managed-analysis/turnstile-acceptance-contract-v1.md`](artifacts/managed-analysis/turnstile-acceptance-contract-v1.md)。
Managed、Non-Interactive 和 Invisible 有独立的页面状态要求。没有 Siteverify
结果时只能称为客户端完成；token、Invisible callback 或 Managed iframe 出现都不
代表整体通过。

`https://peet.ws/turnstile-test/` 只作为最终验收门，不用于定位根因或编写站点特判。
编译成功、传输层 smoke 或 Canvas smoke 均不等于 Turnstile 验收成功。

## Upstream, trademark, and license

DarkPanda 保留 Lightpanda（Selecy SAS）的原始版权声明，并依照 GNU Affero
General Public License v3 分发，详见 [LICENSE](LICENSE)。

Lightpanda、Chrome、Chromium 及其标识归各自权利人所有。DarkPanda 图标中的
浏览器圆环用于表达兼容性目标，不表示 Google、Chromium 或 Lightpanda 对本项目的
认可、赞助或隶属关系。
