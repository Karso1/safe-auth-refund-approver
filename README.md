# Safe Auth 金融卡四方退款自动同意

双击 `start_safe_auth_refund_approver.command` 启动。启动前在 Safe Auth 打开“当前任务”页面，并允许 Terminal 使用 macOS“辅助功能”。启动脚本会在本机编译程序。终端窗口保持运行时，程序每 10 秒检查当前可见的任务；关闭终端或按 Control-C 即停止。

脚本仅处理“汇信 - 总后台 - 金融卡四方退款”，并要求详情中的类型为“金融卡四方退款(44)”、任务 ID 与列表一致、订单号存在、卡商退款金额与人工操作退款金额及币种完全一致。金额不一致的任务会跳过。审批结果记录在 `outputs/safe_auth_refund_approvals.jsonl`；结果不明确时脚本停止，同一任务不会自动重试。

只读预览命令：

```sh
clang -fobjc-arc -fno-modules -Wall -framework AppKit -framework ApplicationServices safe_auth_refund_approver.m -o safe_auth_refund_approver
./safe_auth_refund_approver --inspect-first
```

此方案操作的是桌面界面，电脑需要保持开机、已登录，Safe Auth 需要保持可用。应用界面改变后应先重新运行只读预览。真实审批流程尚未在生产环境中试跑。
