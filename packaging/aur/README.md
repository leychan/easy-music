# Easy Music 的 AUR 包

`easy-music-bin` 安装 GitHub Release 中的 Linux x86_64 预编译包。AUR 仓库只需要 `PKGBUILD`、`.SRCINFO` 和 `dev.easymusic.easy_music.desktop`。

## 验证打包

从 Easy Music 项目根目录运行以下命令。示例使用 `0.1.0`。发新版时，先同步 `PKGBUILD` 中的 `pkgver` 并把 `pkgrel` 设为 `1`。

```sh
flutter build linux --release
bash tool/package_linux_release.sh
cp build/release/easy-music-0.1.0-linux-x86_64.tar.gz packaging/aur/
cd packaging/aur
updpkgsums
makepkg --printsrcinfo > .SRCINFO
makepkg --verifysource
makepkg
```

## 首次发布

项目使用 MIT 许可证。打包时会一并安装项目许可证与第三方许可声明。

1. 为 AUR 发布准备专用 SSH 密钥，并将公钥添加到有权维护 `easy-music-bin` 的 AUR 账号。在 GitHub 的 `aur` 环境中，将私钥添加为 `AUR_SSH_PRIVATE_KEY` Secret，将核对过的 `aur.archlinux.org` 主机公钥行添加为 `AUR_SSH_KNOWN_HOSTS` Variable。
2. 推送与 `pubspec.yaml` 一致的版本标签，例如 `v0.1.0`。工作流会先创建 GitHub Release，再从公开下载地址取回并校验 Linux 包，更新 AUR 的版本号、SHA-256 和 `.SRCINFO`，最后推送打包文件。私有仓库可跑构建和 Release，AUR 同步会跳过。
