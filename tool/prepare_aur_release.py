import argparse
import hashlib
import re
import shutil
from pathlib import Path


def sha256(path: Path) -> str:
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description="Update AUR packaging from a Linux release archive.")
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    version = re.fullmatch(r"easy-music-(\d+\.\d+\.\d+)-linux-x86_64\.tar\.gz", args.archive.name)
    if not version:
        parser.error(f"Unexpected Linux release archive name: {args.archive.name}")

    source = Path(__file__).resolve().parents[1] / "packaging" / "aur"
    desktop_file = source / "dev.easymusic.easy_music.desktop"
    recipe = (source / "PKGBUILD").read_text(encoding="utf-8")
    recipe = re.sub(r"^pkgver=.*$", f"pkgver={version[1]}", recipe, flags=re.MULTILINE)
    checksums = f"sha256sums=('{sha256(args.archive)}'\n            '{sha256(desktop_file)}')"
    # 当前下载的发布包与桌面文件都要校验，不能沿用仓库里上一版的哈希。
    recipe, count = re.subn(r"^sha256sums=\([^)]*\)", checksums, recipe, flags=re.MULTILINE)
    if count != 1:
        raise ValueError("Expected a single sha256sums array in PKGBUILD.")

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "PKGBUILD").write_text(recipe, encoding="utf-8")
    destination = args.output / desktop_file.name
    if destination.resolve() != desktop_file:
        shutil.copyfile(desktop_file, destination)


if __name__ == "__main__":
    main()
