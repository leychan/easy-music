#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
archive=${1:?请提供 Linux x86_64 发布压缩包的路径。}
archive_name=$(basename -- "$archive")
if [[ ! "$archive_name" =~ ^easy-music-([0-9]+\.[0-9]+\.[0-9]+)-linux-x86_64\.tar\.gz$ ]]; then
    printf '不支持的 Linux 发布压缩包文件名：%s\n' "$archive_name" >&2
    exit 1
fi
version=${BASH_REMATCH[1]}
output_dir=$(dirname -- "$archive")
package="easy-music_${version}_amd64.deb"

work_dir=$(mktemp -d "$output_dir/.debian.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
tar -xzf "$archive" -C "$work_dir"
if [[ ! -x "$work_dir/bundle/easy_music" || ! -d "$work_dir/bundle/data" || ! -d "$work_dir/bundle/lib" ]]; then
    printf 'Linux 发布压缩包中的 Flutter bundle 不完整。\n' >&2
    exit 1
fi

package_root="$work_dir/package"
install -d -m755 "$package_root"/{DEBIAN,usr/bin,usr/lib}
# Flutter 的 data/ 和 lib/ 必须和可执行文件一起安装。
mv -- "$work_dir/bundle" "$package_root/usr/lib/easy-music"
ln -s ../lib/easy-music/easy_music "$package_root/usr/bin/easy-music"
install -Dm644 "$project_dir/packaging/aur/dev.easymusic.easy_music.desktop" \
    "$package_root/usr/share/applications/dev.easymusic.easy_music.desktop"
install -Dm644 "$work_dir/LICENSE" "$package_root/usr/share/doc/easy-music/copyright"
install -Dm644 "$work_dir/THIRD_PARTY_NOTICES" "$package_root/usr/share/doc/easy-music/THIRD_PARTY_NOTICES"

# 依赖版本以 CI 的 Ubuntu 24.04 构建环境为基准。Portal 供应用打开文件选择器。
cat > "$package_root/DEBIAN/control" <<EOF
Package: easy-music
Version: $version
Section: sound
Priority: optional
Architecture: amd64
Maintainer: leychan <26612846+leychan@users.noreply.github.com>
Depends: libc6 (>= 2.39), libgtk-3-0t64, libdbusmenu-glib4, libsecret-1-0, libmpv2, libstdc++6, xdg-desktop-portal
Recommends: xdg-desktop-portal-gtk
Homepage: https://github.com/leychan/easy-music
Description: Music player for local files and HTTPS audio streams
 Easy Music plays local audio files and online music and supports playlists,
 synchronized lyrics, and desktop playback controls.
EOF

dpkg-deb --root-owner-group --build "$package_root" "$work_dir/$package"
mv -f -- "$work_dir/$package" "$output_dir/$package"
printf '%s\n' "$output_dir/$package"
