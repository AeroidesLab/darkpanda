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
Zig DOM/Web API、标准 CDP、进程内 C ABI、PyO3 Python 扩展、Rust `wreq`
HTTP/TLS 传输层，以及真实的 CPU Chrome-Skia Canvas 后端。

DarkPanda is derived from the Lightpanda Zig browser codebase. It combines a
pinned V8 runtime, a Zig DOM/Web API layer, standard CDP, an in-process C ABI,
the PyO3 Python extension, the Rust `wreq` HTTP/TLS stack, and a real CPU
Chrome-Skia Canvas backend.

项目目标是补齐自动化和当前挑战验收所需的浏览器行为，而不是实现完整渲染引擎，
也不声称等价于 Chromium 的 Blink、GPU、多进程隔离或全部 Web Platform Tests。
Chrome 149 是一套统一的兼容性配置和实测边界，不是“完整 Chrome 替代品”的宣传。

The goal is the browser behavior required by automation and the current
acceptance contract, not a complete rendering engine or a drop-in Chromium
replacement. Chrome 149 compatibility is a coherent, measured profile rather
than a claim of full Blink, GPU, process-isolation, or WPT parity.

## 核心特性 / Features

- Windows x64、Linux x64、macOS Intel 与 macOS Apple Silicon 原生预构建。
  Windows 构建不经过 WSL。
- V8 `14.9.207.35`，对应项目的 Chrome 149 兼容性配置。
- 标准 CDP 服务与不启动子进程的进程内 Python API。
- `wreq` 是唯一 HTTP/TLS 后端；运行时不包含 libcurl。
- `wreq.dll` / `libwreq.so` 使用 wreq、wreq-util 与 btls/BoringSSL。
- CPU Chrome-Skia Canvas ABI v5 动态后端，软件 fallback 默认关闭。
- HTTP 响应缓存、Cookie、IndexedDB 和页面状态均为内存型；不写磁盘浏览器缓存。
- 主仓库 Actions 固定四个组件提交，并验证每个标准 dist 的构建、测试和 SHA-256
  元数据。

## Runtime artifact set

一次构建只有在下面的文件来自同一个 manifest 且相邻部署时才有效：

| Role | Windows | Linux | macOS |
| --- | --- | --- | --- |
| Browser / CDP | `darkpanda.exe` | `darkpanda` | `darkpanda` |
| C ABI | `darkpanda.dll` | `libdarkpanda.so` | `libdarkpanda.dylib` |
| HTTP/TLS | `wreq.dll` | `libwreq.so` | `libwreq.dylib` |
| CPU Canvas | `canvas.dll` | `libcanvas.so` | `libcanvas.dylib` |
| HTML parser | `html5ever.dll` | `libhtml5ever.so` | `libhtml5ever.dylib` |

主库相对自己的模块目录加载 wreq、Canvas 和 HTML parser，而不是相对
`python.exe` 或宿主程序目录加载。部署或打包时不要单独复制其中一个文件。

## GitHub Actions 预构建 / Prebuilt releases

[`prebuilt-binaries.yml`](.github/workflows/prebuilt-binaries.yml) 是主仓库当前的
Windows/Linux/macOS 验收入口。阶段 1–4 在四个原生 runner 上构建可移植运行时：

- `windows-2022`：`x86_64-windows-msvc`
- `ubuntu-22.04`：`x86_64-linux-gnu`（降低 Rust/系统库所需的最低 glibc 版本）
- `macos-15-intel`：`x86_64-macos.12.0`
- `macos-15`：`aarch64-macos.12.0`

正式稳定版仍是后续验收阶段。手动运行默认只上传临时 artifact；
显式设置 `publish_release=true` 时，四平台聚合门通过后会创建或更新对应
`v1.0.0-ci.<run-number>` 预发行版。

每次运行开始时，工作流固定 `canvas`、`html5ever`、`wreq` 和 `boringssl` 的
精确提交。各组件以同一套 Chromium M149 profile 和 DarkPanda 根目录固定的 `DEPS`
工具链构建，并输出标准 `dist/<target>/`；浏览器仓库只消费这些 dist，不进入组件
源码目录编译 Cargo/CMake 项目。

Actions 在组装浏览器前验证每个 dist 的 `metadata/build-info.json`、
`metadata/test-results.json` 和 `metadata/SHA256SUMS`。原生归档包含相邻的全部
运行时库、`darkpanda.h`、`canvas.h`、组件证明和运行时依赖报告；Python API
只由 [`AeroidesLab/py-darkpanda`](https://github.com/AeroidesLab/py-darkpanda)
的 PyO3 wheel 提供，不再发布主仓库的 ctypes 包装层。
发布硬门会启动 CLI，并在安装目录和重新解压后的干净环境中加载
`darkpanda`、`wreq`、Canvas ABI v5 和 HTML5ever 四个动态库。完整 Canvas 像素与
software fallback 测试仍会运行并保留报告，但暂不阻断四平台预发行版。

## Python API

安装主仓库发布的 `py-darkpanda` wheel。wheel 自带同次构建的四个原生库，
正常使用不需要手工拼接 DLL/SO 路径；开发时也可设置 `DARKPANDA_BIN_DIR`
指向某个已验证原生归档的 `bin` 目录：

```python
from darkpanda import Browser, CanvasDriver, ClientProfile

with Browser(
    canvas_driver=CanvasDriver.DYNAMIC,
    profile=ClientProfile.CHROME149,
    locale="en-US",
    timezone="UTC",
) as browser:
    with browser.new_page() as page:
        page.navigate("https://example.com/")
        print(page.evaluate("({ title: document.title, url: location.href })"))
```

该 PyO3 API 直接在 Python 进程中加载 DarkPanda，不绑定 CDP 端口，也不启动浏览器
子进程。ABI 生命周期和 Windows 加载细节见 [WINDOWS_NATIVE.md](WINDOWS_NATIVE.md)。

## 构建模型 / Build model

`canvas`、`html5ever`、`wreq` 和 `boringssl` 各自在独立仓库提供源码和统一构建
入口，实际构建只由 DarkPanda 主仓库 Actions 发起。四个组件共享 DarkPanda 根目录
固定的 Chromium M149 profile、`DEPS` 工具链和统一接口：

```text
tools/build.ps1|sh
  --target <target>
  --profile release
  --out <absolute-dist-path>
  --jobs <count>
  --toolchain chromium
  --toolchain-dir <absolute-path>
```

每个输出必须遵守同一契约：

```text
dist/<target>/
  bin/
  lib/
  include/
  metadata/build-info.json
  metadata/test-results.json
  metadata/SHA256SUMS
```

浏览器构建只接受四个绝对 dist 路径，不再拥有或调用组件 Cargo/CMake 构建：

```bash
zig build install \
  -Dcanvas_dist=/absolute/dist/target \
  -Dhtml5ever_dist=/absolute/dist/target \
  -Dwreq_dist=/absolute/dist/target \
  -Dboringssl_dist=/absolute/dist/target \
  -Dprebuilt_v8_path=/absolute/path/to/v8/archive
```

安装结果将 Canvas、HTML5ever 和 wreq 动态库放在 DarkPanda 模块相邻的 `bin/`
目录；Canvas 的公共头是 `include/canvas.h`。BoringSSL M149 的 `crypto` 静态库
已包含 fipsmodule objects，因此浏览器只链接 `crypto.lib` 或 `libcrypto.a`。

本地可用 `make fmt`、`make check`、`make test`、`make install` 和
`make test-runner-report`。除格式与独立 test-runner 检查外，目标都要求设置
`CANVAS_DIST`、`HTML5EVER_DIST`、`WREQ_DIST` 和 `BORINGSSL_DIST`；正式产物以主
仓库 Actions 的固定提交、元数据校验和跨平台测试结果为准。

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
