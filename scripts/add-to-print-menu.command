#!/bin/bash
set -u
script_dir=$(cd "$(dirname "$0")" && pwd)
if /bin/bash "$script_dir/install-local-printer.sh"; then
    echo "打印菜单已添加，可以关闭此窗口。"
    status=0
else
    status=$?
    echo "打印菜单添加失败，请查看上面的错误。" >&2
fi
read -r -p "按回车结束。" _ || true
exit "$status"
