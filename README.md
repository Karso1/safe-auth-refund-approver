# Safe Auth 四方退款自动审批 / Four-Party Refund Approver

这个 macOS 工具在 Safe Auth 的“当前任务”页面查找“汇信 - 总后台 - 金融卡四方退款”，核对任务详情，然后对符合条件的任务依次点击“通过”和“同意”。**它会执行真实审批操作；首次使用请先运行不提交审批的预览，并在测试环境验证。当前代码尚未经过生产审批流程实测。**

This macOS tool finds "汇信 - 总后台 - 金融卡四方退款" on Safe Auth's Current Tasks page, checks the task details, then clicks Pass and Agree for qualifying tasks. **It performs real approvals. Run the non-approving inspection mode first and validate it in a test environment. The approval path has not been tested in production.**

## 中文

### 运行条件

- macOS、Xcode Command Line Tools（提供 `clang`），以及正在运行的 Safe Auth。
- 在 Safe Auth 中打开“当前任务”页面；电脑保持开机、已登录、应用界面可用。
- 给运行程序的 Terminal 授予 macOS“辅助功能”权限。程序只通过本机界面操作，不连接 Safe Auth 的 API。

### 先预览，再运行

在仓库目录中执行：

```sh
clang -fobjc-arc -fno-modules -Wall -framework AppKit -framework ApplicationServices \
  safe_auth_refund_approver.m -o safe_auth_refund_approver
./safe_auth_refund_approver --inspect-first
```

`--inspect-first` 会列出当前可见的匹配任务，打开第一笔核对详情，再返回列表；不会点击“通过”或“同意”。确认界面和金额解析仍然正确后，双击 `start_safe_auth_refund_approver.command` 启动持续审批。启动器会编译到 `outputs/`，执行 `--approve --watch`；没有任务时每 10 秒检查一次。关闭终端或按 Control-C 停止。

如果启动时报找不到“当前任务”，先运行 `./safe_auth_refund_approver --diagnose`。它只打印候选进程、辅助功能窗口数量，以及是否识别到“当前任务”，不会打开或审批任务。普通启动会最多等待约 10 秒，供 Safe Auth 的辅助功能窗口准备就绪。

也可以限定本次最多同意的笔数：

```sh
./safe_auth_refund_approver --approve --max 1
```

不带 `--approve` 时不会提交审批；`--watch` 只控制无任务时是否继续轮询。

### 它检查什么

1. 从可见任务中筛选指定任务名称，并从列表文本提取任务 ID。
2. 打开详情，要求类型是 `金融卡四方退款(44)`、详情中出现同一任务 ID，且存在至少 12 位数字的订单号。
3. 从详情中识别形如 `11.84 USDT` 的金额文本，取最后两个匹配项作为“卡商退款金额”和“人工操作退款金额”。只有金额字符串（含币种）完全一致才继续；不一致则记录并跳过。
4. 点击“通过”，等待“是否同意”弹窗，先写入 `attempted` 日志，再点击“同意”。只有任务从当前列表消失后，才追加 `approved` 日志。

日志位于 `outputs/safe_auth_refund_approvals.jsonl`，每行一条 JSON，包含时间、任务 ID、结果和金额。启动时会读取其中的 `attempted` / `approved` 任务 ID，避免自动重试结果不明确的任务。`skipped_mismatch` 只在当前运行中跳过；下一次启动仍可能再次检查。

### 用到的知识点

| 知识点 | 在本项目中的作用 |
| --- | --- |
| Objective-C 与 Foundation | 处理字符串、集合、正则、JSON、文件和命令行参数。 |
| macOS Accessibility API (`AXUIElement`) | 读取 Safe Auth 窗口的辅助功能树，查找任务、按钮和弹窗。 |
| AppKit (`NSWorkspace`) | 按 bundle ID 找到运行中的 Safe Auth，并在点击前激活应用。 |
| UI 自动化的两级点击 | 优先调用控件的 Accessibility `Press` 动作；失败时尝试按控件坐标发送鼠标事件。 |
| 正则表达式 | 从任务行提取 ID，识别订单号和“数字 + 币种”的金额文本。 |
| 状态校验与超时 | 每次关键点击后等待预期页面或弹窗；超时或状态不明时停止。 |
| JSON Lines 审计日志与幂等保护 | 记录尝试/成功，并防止同一任务在结果不明确时被脚本自动重复提交。 |
| 轮询 | `--watch` 模式下，无任务时每 10 秒重新读取当前可见任务。 |

### 边界与风险

- 金额比对依赖当前界面的文本顺序：代码**不是**按字段名定位金额，也不核对后台真实账务。若 UI 顺序或文案变化，先停止并重新测试。
- 任务成功的判断是“从当前列表消失”，不是服务端最终入账或退款成功的证明。异常时需人工到 Safe Auth 核查。
- 仅处理当前窗口中可见的任务，不负责翻页、登录、处理权限弹窗或电脑关机后的运行。
- 日志可能包含任务 ID 和金额，请控制本机 `outputs/` 目录访问权限；该目录已被 `.gitignore` 排除。
- 这个仓库没有附带开源许可证；公开可读不等于自动授予再分发或商用许可。

## English

### Requirements

- macOS, Xcode Command Line Tools (`clang`), and a running Safe Auth app.
- Open the Current Tasks page and keep the Mac awake, signed in, and the app available.
- Grant the terminal macOS Accessibility permission. This tool drives the local UI; it does not call a Safe Auth API.

### Inspect before approving

From the repository directory, compile and inspect:

```sh
clang -fobjc-arc -fno-modules -Wall -framework AppKit -framework ApplicationServices \
  safe_auth_refund_approver.m -o safe_auth_refund_approver
./safe_auth_refund_approver --inspect-first
```

Inspection lists visible matching tasks, opens the first task to validate its details, and returns to the list. It never clicks Pass or Agree. After verifying that the UI and amount parsing are still correct, double-click `start_safe_auth_refund_approver.command` to compile into `outputs/` and run `--approve --watch`. It checks again every 10 seconds when no task is visible. Close the terminal or press Control-C to stop.

If startup cannot find Current Tasks, run `./safe_auth_refund_approver --diagnose`. It only prints candidate processes, Accessibility window counts, and whether Current Tasks was detected; it never opens or approves a task. Normal startup waits up to about 10 seconds for Safe Auth's Accessibility window to become ready.

To limit a run to one approval:

```sh
./safe_auth_refund_approver --approve --max 1
```

Without `--approve`, the program does not submit approvals. `--watch` only controls whether it keeps polling when no task is found.

### Validation flow

1. Filter visible task rows by the configured task title and extract a task ID from the row text.
2. Open the details and require type `金融卡四方退款(44)`, the same task ID, and an order number of at least 12 digits.
3. Recognize amount strings such as `11.84 USDT`. Treat the last two matches as the merchant refund and manual refund. Continue only when both strings, including currency, are identical; otherwise log and skip.
4. Click Pass, wait for the Agree dialog, write an `attempted` log entry, then click Agree. Append `approved` only after the task disappears from the current list.

The append-only `outputs/safe_auth_refund_approvals.jsonl` log contains time, task ID, outcome, and amounts. On startup, `attempted` and `approved` IDs are loaded to avoid automatically retrying an uncertain outcome. `skipped_mismatch` is skipped only for the current process; it may be inspected again after restarting.

### Concepts used

| Concept | Role here |
| --- | --- |
| Objective-C and Foundation | Strings, collections, regex, JSON, files, and CLI arguments. |
| macOS Accessibility API (`AXUIElement`) | Reads the Safe Auth accessibility tree and locates tasks, buttons, and dialogs. |
| AppKit (`NSWorkspace`) | Finds the running app by bundle ID and activates it before clicking. |
| Two-stage UI clicking | Tries the Accessibility Press action first, then a coordinate-based mouse event as fallback. |
| Regular expressions | Extract task IDs and recognize order numbers and currency amounts. |
| State checks and timeouts | Wait for expected screens after actions; stop when the state is unclear. |
| JSON Lines audit log and idempotency guard | Record attempts/results and avoid automatic resubmission of uncertain tasks. |
| Polling | Re-scan currently visible tasks every 10 seconds in watch mode. |

### Limitations and risks

- Amount matching depends on the current UI text order. It does **not** locate amounts by field name or verify backend ledger data. Re-test whenever the UI changes.
- A task disappearing from the current list is only a UI-level success signal, not proof of a completed refund. Check Safe Auth manually after any ambiguous result.
- It processes only tasks visible in the current window. It does not paginate, sign in, handle permission prompts, or run while the Mac is off.
- The log can contain task IDs and amounts. Protect local access to `outputs/`; the directory is excluded by `.gitignore`.
- No open-source license is included. Public visibility does not itself grant redistribution or commercial-use rights.
