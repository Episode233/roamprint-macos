#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin || "$EUID" -eq 0 ]]; then
    echo "请由当前登录的 macOS 用户运行，不要使用 sudo 启动整个脚本。" >&2
    exit 1
fi
if printer_details=$(/usr/bin/lpstat -v ZGCAxZGCIprinter 2>/dev/null); then
    if [[ "$printer_details" != *": ipp://127.0.0.1:19963/ipp/print" ]]; then
        echo "ZGCAxZGCI printer 队列当前使用不同地址，请手动检查后处理。" >&2
        exit 1
    fi
fi
/bin/launchctl bootout "gui/$UID/org.local.roamprint.capture" >/dev/null 2>&1 || true
agent_path="$HOME/Library/LaunchAgents/org.local.roamprint.capture.plist"
if [[ -f "$agent_path" ]]; then /bin/rm "$agent_path"; fi
echo "移除 macOS 打印队列需要管理员权限。"
if /usr/bin/lpstat -p ZGCAxZGCIprinter >/dev/null 2>&1; then
    /usr/bin/sudo /usr/sbin/lpadmin -x ZGCAxZGCIprinter
fi
echo "已关闭本地收集服务和打印菜单队列。本地文档和平台上的作业保留。"
