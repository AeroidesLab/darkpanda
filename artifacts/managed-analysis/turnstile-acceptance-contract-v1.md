# Turnstile 客户端验收契约 v1

机器版本：`turnstile-client-acceptance-v1`

本文件与 `tests/ffi_turnstile.py` 中的 `FIXTURES`、
`INSTALL_ACCEPTANCE_MONITOR` 和 `validate_fixture_result()` 共同构成不可变的
v1 验收契约。除非显式发布新的契约版本，否则不得根据某次运行结果临时改变
解释、删减条件或加入宽松 fallback。

## 范围与结论等级

- `peet.ws` 只作为最终验收门，禁止用它定位根因。
- fixture 没有可用的服务端 Siteverify 结果。因此本契约最多证明
  `client_completed`，绝不声称服务端验证成功、人类验证通过或整体产品通过。
- `CLIENT_FIXTURE_COMPLETE` 只表示一个 fixture 满足下述全部客户端条件。
- `CLIENT_MATRIX_COMPLETE` 只允许在同一次 `--only all` 运行中，三个 fixture
  全部产生 `CLIENT_FIXTURE_COMPLETE` 后输出。
- 单独运行任一 fixture 时，最终输出必须是
  `CLIENT_FIXTURE_RUN_COMPLETE`、`matrixComplete: false`；不得输出
  `CLIENT_MATRIX_COMPLETE`。
- 单个 token、单个响应面非空、Invisible 完成、Managed iframe 出现、发生过
  点击，均不等于 fixture 完成，更不等于矩阵完成。

正式运行还受唯一新产物门禁约束：如果运行前不能用构建 manifest 证明 EXE、
DLL、wreq transport 和 V8 archive 的绝对路径、版本与 SHA-256，或不能排除旧
进程和旧缓存，则整次结果无效，不得引用本契约的完成结论。

## 三个 fixture 的固定输入策略

| Fixture | 输入策略 | 客户端完成的额外前提 |
| --- | --- | --- |
| Non-Interactive | `forbidden` | 测试框架发出的原生输入次数必须严格等于 0 |
| Invisible | `forbidden` | 测试框架发出的原生输入次数必须严格等于 0 |
| Managed | `required_before_complete` | 在观察到 complete 之前，至少一次针对 `https://challenges.cloudflare.com` 直属 iframe 的原生 `page.click` 已实际返回，并记录 frame、target 与 dispatch path |

Managed 在原生输入记录之前就出现 complete 时立即失败；不能在 complete 之后补
一次点击来满足条件。原生点击记录本身也不构成完成，最终 complete 消息仍必须是
浏览器可信消息。

## 每个 fixture 的全部硬条件

以下条件必须同时成立，不存在 fixture 特例：

1. 接受的 `MessageEvent` 必须满足 `event.isTrusted === true`。
2. `event.origin` 必须严格等于
   `https://challenges.cloudflare.com`。
3. 协议字段 `event.data.source` 必须严格等于
   `cloudflare-challenge`；`event.source` 必须非空且不得是顶层页面自身。
4. 消息事件必须包含 `complete`，且最终观察序列中不得出现 `fail` 或
   `unsupported`；专门记录的 `forbiddenEvents` 必须为空。
5. 四个响应面必须分别非空：complete 消息 token、
   `cf-turnstile-response`、`g-recaptcha-response`、
   `turnstile.getResponse()`。
6. 四个响应值必须逐字相等。机器输出只记录长度与相等性，不泄露 token。
7. `turnstile.isExpired()` 必须严格为 `false`。
8. 监听 complete 之前必须先执行 `turnstile.reset()`。reset 返回后，消息面必须
   尚未出现 complete，两个隐藏输入与 API 响应必须全部为空；五个 reset evidence
   布尔值必须全部为 `true`。
9. 页面必须处于 secure context，并且公开的 UA、UA-CH brand、platform 必须
   满足当前 Chrome 149 / Windows profile 契约。
10. 必须满足本 fixture 在上一节规定的原生输入策略。

complete 后测试额外泵送一个固定终止窗口，再重新读取 `error`、事件序列和
`forbiddenEvents`。窗口内出现 `fail` 或 `unsupported` 会使该 fixture 失败，
不能保留先前的 complete 结论。

## 机器可读结果

每个 fixture 的 JSON 至少包含：

- `contractVersion: "turnstile-client-acceptance-v1"`
- `resultType: "fixture"`
- `result: "CLIENT_FIXTURE_COMPLETE"`
- `validationLevel: "client_completed"`
- `siteverify: false`
- `matrixComplete: false`
- `fixture`、`url`、`nativeInputPolicy`、`nativeInputAttempts`
- origin/source、reset、响应面、过期状态和禁用事件证据

完整矩阵的最后一条 JSON 必须包含：

- `resultType: "matrix"`
- `result: "CLIENT_MATRIX_COMPLETE"`
- `validationLevel: "client_completed"`
- `siteverify: false`
- `matrixComplete: true`
- 三个且仅三个 fixture 的 `CLIENT_FIXTURE_COMPLETE` 映射

没有真实 Siteverify 响应时，任何输出都不得升级为 server-validated。
