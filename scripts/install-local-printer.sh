#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin || "$EUID" -eq 0 ]]; then
    echo "请由当前登录的 macOS 用户运行，不要使用 sudo 启动整个脚本。" >&2
    exit 1
fi
script_dir=$(cd "$(dirname "$0")" && pwd)
app_path=${1:-/Applications/RoamPrint.app}
if [[ "$script_dir" == */Contents/Resources ]]; then app_path=${1:-${script_dir%/Contents/Resources}}; fi
service_path="$app_path/Contents/Resources/bin/roamprint-service"
ppd_path="$app_path/Contents/Resources/RoamPrint.ppd"
if [[ ! -x "$service_path" || ! -f "$ppd_path" ]]; then
    echo "找不到完整的 RoamPrint.app：$app_path" >&2
    exit 1
fi
/usr/bin/lipo -verify_arch arm64 "$service_path"
printer_exists=false
if printer_details=$(/usr/bin/lpstat -v ZGCAxZGCIprinter 2>/dev/null); then
    if [[ "$printer_details" != *": ipp://127.0.0.1:19963/ipp/print" ]]; then
        echo "同名 ZGCAxZGCIprinter 队列已存在且使用不同地址，请先处理该队列。" >&2
        exit 1
    fi
    printer_exists=true
fi
agent_dir="$HOME/Library/LaunchAgents"
log_dir="$HOME/Library/Logs/RoamPrint"
agent_path="$agent_dir/org.local.roamprint.capture.plist"
mkdir -p "$agent_dir" "$log_dir"
chmod 700 "$log_dir"
backup_path=$(mktemp "${TMPDIR:-/tmp}/roamprint-agent.XXXXXX")
had_agent=false
was_running=false
printer_created=false
agent_changed=false
if [[ -f "$agent_path" ]]; then
    /bin/cp -p "$agent_path" "$backup_path"
    had_agent=true
fi
if /bin/launchctl print "gui/$UID/org.local.roamprint.capture" >/dev/null 2>&1; then was_running=true; fi
rollback() {
    rollback_status=$?
    trap - EXIT
    if [[ "$rollback_status" -ne 0 ]]; then
        if [[ "$printer_created" == true ]]; then
            /usr/bin/sudo -n /usr/sbin/lpadmin -x ZGCAxZGCIprinter >/dev/null 2>&1 || \
                echo "新打印队列回滚失败，可运行 remove-local-printer.sh 移除。" >&2
        fi
        if [[ "$agent_changed" == true ]]; then
            /bin/launchctl bootout "gui/$UID/org.local.roamprint.capture" >/dev/null 2>&1 || true
            if [[ "$had_agent" == true ]]; then
                /bin/cp -p "$backup_path" "$agent_path"
                if [[ "$was_running" == true ]]; then
                    /bin/launchctl bootstrap "gui/$UID" "$agent_path" >/dev/null 2>&1 || \
                        echo "旧本地服务恢复失败，请重新登录后检查。" >&2
                fi
            else
                /bin/rm -f "$agent_path"
            fi
        fi
    fi
    /bin/rm -f "$backup_path"
    exit "$rollback_status"
}
trap rollback EXIT
agent_changed=true
export ROAMPRINT_SERVICE_PATH="$service_path" ROAMPRINT_LOG_DIR="$log_dir" ROAMPRINT_AGENT_PATH="$agent_path"
# JXA Foundation creates a plist without interpolating user paths into XML.
/usr/bin/osascript -l JavaScript <<'JXA'
ObjC.import('Foundation');
var env = $.NSProcessInfo.processInfo.environment;
var service = ObjC.unwrap(env.objectForKey('ROAMPRINT_SERVICE_PATH'));
var logs = ObjC.unwrap(env.objectForKey('ROAMPRINT_LOG_DIR'));
var target = ObjC.unwrap(env.objectForKey('ROAMPRINT_AGENT_PATH'));
var object = $({Label: 'org.local.roamprint.capture', ProgramArguments: [service],
    RunAtLoad: true, KeepAlive: true, ProcessType: 'Background',
    StandardOutPath: logs + '/capture.log', StandardErrorPath: logs + '/capture-error.log'});
if (!object.writeToFileAtomically($(target), true)) throw new Error('无法写入 LaunchAgent');
JXA
chmod 600 "$agent_path"
/bin/launchctl bootout "gui/$UID/org.local.roamprint.capture" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/$UID" "$agent_path"
/bin/launchctl kickstart "gui/$UID/org.local.roamprint.capture"

ready=false
for attempt in {1..20}; do
    capture_pid=$(/bin/launchctl print "gui/$UID/org.local.roamprint.capture" 2>/dev/null | \
        /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }')
    if [[ "$capture_pid" =~ ^[0-9]+$ ]] && \
        /usr/sbin/lsof -n -P -a -p "$capture_pid" -iTCP@127.0.0.1:19963 -sTCP:LISTEN >/dev/null 2>&1; then
        ready=true
        break
    fi
    /bin/sleep 0.25
done
if [[ "$ready" != true ]]; then
    echo "本地收集服务尚未监听 19963（可能端口被占用），查看 $log_dir/capture-error.log。" >&2
    exit 1
fi
if [[ "$printer_exists" != true ]]; then
    echo "添加 macOS 打印队列需要管理员权限。"
    # Mark before invoking lpadmin, so a partially created queue is also rolled back.
    printer_created=true
    /usr/bin/sudo /usr/sbin/lpadmin -p ZGCAxZGCIprinter -E \
        -D "ZGCAxZGCIprinter" -L "提交到平台后刷卡取件" \
        -v ipp://127.0.0.1:19963/ipp/print -P "$ppd_path" -o printer-is-shared=false
    /usr/bin/lpoptions -p ZGCAxZGCIprinter -o media=A4 -o ColorModel=Gray -o Duplex=None
fi
echo "已启用“ZGCAxZGCIprinter”。从系统打印菜单发送后，在 RoamPrint 中确认并提交。"
