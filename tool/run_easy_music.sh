#!/usr/bin/env bash
# 启动 easy_music（release 包）。
#
# 两个必须处理的坑：
# 1. 本机是 Wayland 会话，GTK 默认走 XWayland，而 XWayland 下的 GL 上下文
#    拿不到 framebuffer（日志是 "Timed out waiting for OpenGL frame ...
#    (have 0x0)"），窗口永远出不了第一帧。所以强制 GDK_BACKEND=wayland。
# 2. 单实例锁按 D-Bus 名字注册，若上一个实例还在（或残留名字未回收），
#    新进程会直接静默退出。这里先查一次并清掉。
set -euo pipefail

APP_ID="dev.easymusic.easy_music"
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/linux/x64/release/bundle"

if [ ! -x "$BUNDLE_DIR/easy_music" ]; then
  echo "找不到可执行文件：$BUNDLE_DIR/easy_music" >&2
  echo "先运行：flutter build linux --release" >&2
  exit 1
fi

# 查当前持有单实例锁的 PID。注意 D-Bus 返回的 PID 是「持有者所在命名空间」的
# PID，本沙箱里通常看不到对应 /proc 条目，所以它只能当参考、不能直接 kill。
holder_of() {
  gdbus call --session --dest org.freedesktop.DBus \
    --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.GetConnectionUnixProcessID "$APP_ID" 2>/dev/null \
    | grep -oE '[0-9]+' | head -1 || true
}

holder="$(holder_of)"

# 先按名字 kill 本命名空间内可见的实例（正常退出路径）
for pid in $(pgrep -x easy_music 2>/dev/null || true); do
  echo "结束已有实例 PID $pid"
  kill "$pid" 2>/dev/null || true
done

# 提示锁的持有者仍不可见时的处理办法，而不是让新进程静默退出
if [ -n "${holder:-}" ] && [ ! -d "/proc/$holder" ]; then
  echo "警告：单实例锁仍由 PID $holder 持有，而该进程不在当前 PID 命名空间内，" >&2
  echo "      无法从本 shell 终止它。若界面没有出现，请在持有它的终端里关闭旧窗口。" >&2
fi

cd "$BUNDLE_DIR"
echo "启动 easy_music（Wayland 后端）..."

# 不用 exec：启动后要回读一次持锁者，确认新实例真的接管了单实例锁，
# 而不是因为抢不到名字而静默退出。
env GDK_BACKEND=wayland ./easy_music "$@" &
app_pid=$!
sleep 3

if ! kill -0 "$app_pid" 2>/dev/null; then
  echo "启动失败：进程已退出（exit=$?），通常是单实例锁被占用或 GL 上下文创建失败。" >&2
  exit 1
fi

new_holder="$(holder_of)"
if [ "${new_holder:-}" = "$holder" ] && [ -n "${holder:-}" ]; then
  echo "注意：单实例锁仍由旧持有者 PID $holder 把持，当前进程 $app_pid 可能要等它退出才显示界面。" >&2
else
  echo "已启动，PID $app_pid，单实例锁持有者 ${new_holder:-未知}"
fi

wait "$app_pid"
