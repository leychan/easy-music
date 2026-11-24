#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=$(awk '/^version: / { split($2, version, "+"); print version[1]; exit }' "$project_dir/pubspec.yaml")
bundle_dir="$project_dir/build/linux/x64/release/bundle"
archive_dir="$project_dir/build/release"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    printf 'pubspec.yaml 中缺少可用的发布版本号。\n' >&2
    exit 1
fi
if [[ ! -x "$bundle_dir/easy_music" || ! -d "$bundle_dir/data" || ! -d "$bundle_dir/lib" ]]; then
    printf 'Linux bundle 不完整，请先运行 flutter build linux --release。\n' >&2
    exit 1
fi

mkdir -p -- "$archive_dir"
archive="$archive_dir/easy-music-$version-linux-x86_64.tar.gz"
temporary_archive=$(mktemp "$archive.tmp.XXXXXX")
trap 'rm -f -- "$temporary_archive"' EXIT

# 把程序和运行资源保持在同一个 bundle 中，并在压缩包根目录提供许可文件。
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -cf - -C "$(dirname -- "$bundle_dir")" bundle \
    -C "$project_dir" LICENSE THIRD_PARTY_NOTICES | gzip -n > "$temporary_archive"
chmod 644 "$temporary_archive"
mv -f -- "$temporary_archive" "$archive"
printf '%s\n' "$archive"
