#!/bin/sh
# 清除 Easy Music 的 D-Bus 单实例锁（不需要注销）
# 原因：应用退出后 D-Bus 上可能残留 dev.easymusic.easy_music 注册，
#       新实例启动时会以为旧窗口还在，activate 后立刻退出（表现为秒退）。
set -u

APP_ID="dev.easymusic.easy_music"

# 返回 0 表示锁还在
lock_present() {
  gdbus call --session \
    --dest org.freedesktop.DBus \
    --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.GetConnectionUnixProcessID "$APP_ID" \
    >/dev/null 2>&1
}

# gdbus 输出形如 (uint32 549389,)：去掉类型名 uint32 后再取数字，
# 否则会误抓到 "uint32" 里的 32。
pid=$(gdbus call --session \
  --dest org.freedesktop.DBus \
  --object-path /org/freedesktop/DBus \
  --method org.freedesktop.DBus.GetConnectionUnixProcessID "$APP_ID" 2>/dev/null \
  | sed 's/uint32//g' | grep -oE '[0-9]+' | head -1)

if ! lock_present; then
  echo "没有残留锁，可以直接启动 Easy Music。"
  exit 0
fi

echo "发现残留锁，持有进程 PID = ${pid:-未知}"

# 注意：本脚本若在容器/PID 命名空间里运行，看不到宿主机进程，
# kill -0 会把活着的进程误判为“已不存在”，因此不能只靠 kill -0 分支。
# 统一先尝试 TERM，再按锁是否释放决定下一步。
if [ -n "${pid:-}" ] && kill -TERM "$pid" 2>/dev/null; then
  echo "已向该进程发送 TERM，等待它退出..."
else
  echo "无法直接向该进程发送信号（可能在其他命名空间），等待 D-Bus 自行回收..."
fi

for _ in 1 2 3 4 5 6; do
  sleep 1
  if ! lock_present; then
    echo "锁已释放。"
    exit 0
  fi
done

if [ -n "${pid:-}" ]; then
  kill -KILL "$pid" 2>/dev/null && echo "已强制结束该进程。"
  sleep 1
fi

if ! lock_present; then
  echo "锁已释放。"
  exit 0
fi

echo "锁仍被占用。请在能看见该进程的终端里执行：kill -9 $pid" >&2
echo "（如果在容器内看不到该 PID，需要在宿主机上执行。）" >&2
exit 1
