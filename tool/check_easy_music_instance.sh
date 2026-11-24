#!/bin/sh
# 检查 Easy Music 是否已有实例在运行（D-Bus 单实例锁）
#
# 为什么要单独检查：应用的 GTK 单实例机制会让第二个实例安静退出（退出码 0、
# 无任何输出），只看“程序跑没跑起来”无法区分，因此先查锁再启动。
set -u

APP_ID="dev.easymusic.easy_music"

pid=$(gdbus call --session \
  --dest org.freedesktop.DBus \
  --object-path /org/freedesktop/DBus \
  --method org.freedesktop.DBus.GetConnectionUnixProcessID "$APP_ID" 2>/dev/null \
  | sed 's/uint32//g' | grep -oE '[0-9]+' | head -1)

if [ -z "${pid:-}" ]; then
  echo "没有实例在运行，可以正常启动。"
  exit 0
fi

echo "已有实例在运行（PID $pid），应用会直接退出而不新开窗口。"
echo
echo "如果那个窗口看不见，先结束它再启动："
echo "  kill $pid"
echo
echo "如果它不在当前会话/命名空间（比如由其他容器启动），请在本机终端执行上面的命令。"
exit 1
