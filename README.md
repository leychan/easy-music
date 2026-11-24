# Easy Music

支持 Linux 桌面和 Android 的音乐播放器。可以搜索和播放酷狗曲库，查看每日推荐、私人 FM、推荐歌单与自己的歌单，也能添加本地文件或 HTTPS 音频直链。重新打开应用会恢复队列、歌词和上次保存的进度。

Easy Music 出于个人学习与技术研究目的开发，项目源码按 [MIT 许可证](LICENSE) 发布。项目与酷狗音乐及其关联方无官方关联。第三方服务及音乐、歌词、封面和商标的相关权利归各权利人所有，请在获得授权的范围内使用相应服务和内容。移植代码的原始许可见 [第三方许可声明](THIRD_PARTY_NOTICES)。

## 功能

| 入口 | 内容 |
| --- | --- |
| 发现 | 私人 FM、每日推荐、推荐歌单，支持横向滑动展开堆叠卡片 |
| 搜索 | 关键词联想，搜索歌曲、歌手、专辑、歌单、歌词和 MV |
| 我的 | 酷狗登录、歌单、已购音乐、音乐云盘、最近播放与听歌统计、设置 |
| 队列 | 当前播放队列，可切歌、移除、拖动排序或一键清空 |
| 播放条 | 循环与随机、音质、音量、倍速、定时暂停或退出、逐字歌词 |

发现页优先展示上次成功加载的内容。冷启动后首次打开时会刷新推荐歌单，已登录时也会刷新私人 FM。切回发现标签或手动刷新时只更新每日推荐，从后台返回前台会保留现有列表。桌面端会按发现页的可用宽度调整平铺的卡片数量。横向滑动时，堆叠卡片会逐步展开。区块标题右侧的箭头可打开完整列表，推荐歌单的完整列表纵向排列。

点播单首歌曲时，歌曲会加入当前队列并开始播放，已在队列中的歌曲会直接切过去。点击私人 FM、每日推荐或歌单的「播放全部」，会用列表中的可播放歌曲替换当前队列，退出随机模式并按页面顺序播放。私人 FM 滑到列表末尾会继续加载推荐，播放到队尾时也会自动接上下一批。

在歌曲操作菜单可以切换「我喜欢」、添加到歌单或分享。打开自己创建的歌单后可移除曲目，「我的」提供新建、编辑和导入。公开链接导入支持酷狗、网易云、QQ 音乐、酷我和 Spotify，会先在酷狗匹配曲目，再写入选定歌单。

歌词可选择在线版本，也可以导入 LRC、KRC 或 YRC。KRC 有附带翻译时会显示在对应歌词下方。全屏歌词页支持歌手写真。Linux 的「桌面播放」菜单提供迷你播放器和桌面歌词。支持 StatusNotifierItem 的 Linux 桌面会显示系统托盘图标，右键可查看当前歌曲、播放或暂停、切歌。关闭窗口后仍可在托盘控制，左键可重新打开窗口，彻底关闭请在托盘菜单选择「退出」。

在「我的 → 设置」可以调整首选音质、播放淡入淡出、音频缓存、自动签到和外观。淡入淡出默认关闭，可选 0.25 秒、0.5 秒或 1 秒，适用于开始播放、暂停和手动切歌。自动签到默认开启，概念版账号按北京时间每天领取一次。Linux 上可在「外观」中开启「登录桌面时启动」。

在线音频可边播边缓存，已完整缓存的音频重播时可以复用本地文件。「我的 → 设置 → 音频缓存」可查看占用空间和文件数、调整上限或清空缓存。默认上限为 512 MB，也可以选择「关闭并清空缓存」。

「音乐云盘」支持浏览、重播、上传本地音频和确认后移除文件。「已购音乐」可查看酷狗账号的已购单曲和专辑。

Linux 桌面窗口使用左侧导航、顶部搜索和底部播放器，播放队列从右下角展开。Android 窄屏使用底部导航，队列作为第四个 tab。点击底部播放条的封面会打开独立播放页，封面下方显示可滚动的同步歌词。点击歌词按钮可直接展开歌词，用系统返回键回到原页面。

## 开发和运行

需要 Flutter 3.50 和 Dart 3.14 或以上版本。Linux 需要 Flutter 桌面工具链、GTK 3、libmpv、桌面 D-Bus 会话和提供文件选择器的 XDG Desktop Portal。Arch Linux 通常通过 `mpv` 安装 libmpv，Debian / Ubuntu 可安装 `libmpv-dev`。构建托盘菜单需要 Arch 的 `libdbusmenu-glib` 或 Debian / Ubuntu 的 `libdbusmenu-glib-dev`。Android 需要 Android SDK 和 NDK，使用 `flutter doctor` 检查开发环境。

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d linux
```

连接 Android 设备后运行 `flutter devices`，然后用 `flutter run -d <设备 ID>` 启动。构建调试 APK 可用 `flutter build apk --debug`。

当前 Android 调试构建已用 JDK 20 验证。如果系统默认的 Java 版本与 Gradle 不兼容，可以通过 `JAVA_HOME` 指定 JDK。

### 构建发布版

在 Linux x86_64 上，从项目根目录构建并运行可执行文件。

```sh
flutter build linux --release
./build/linux/x64/release/bundle/easy_music
```

可执行文件位于 `build/linux/x64/release/bundle/`。运行或移动时，请将 `easy_music` 与同目录下的 `data/`、`lib/` 一起保留。

Linux 发布压缩包可用 `bash tool/package_linux_release.sh` 生成，产物在 `build/release/`。Arch Linux 的包文件及验证步骤见 [AUR 打包说明](packaging/aur/README.md)。

Android Release 使用正式密钥签名。签名配置可以放在 `android/key.properties`，也可以放在 `~/.local/share/easy-music/signing/key.properties`。构建机可用 `EASY_MUSIC_ANDROID_KEY_PROPERTIES` 指定临时配置文件。配置需要 `storeFile`、`storePassword`、`keyAlias` 和 `keyPassword`，相对的密钥路径以配置文件所在目录为基准。签名文件和密码应保存在本机或 CI 的 Secrets 中。

GitHub Actions 的 `release` 环境可把 `ANDROID_KEYSTORE_BASE64` 解码成临时密钥文件，并用 `ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS` 和 `ANDROID_KEY_PASSWORD` 填写临时签名配置。

```sh
flutter build apk --release --target-platform android-arm64
```

APK 位于 `build/app/outputs/flutter-apk/app-release.apk`。从同包名的旧调试版切换到正式版时，需要先备份所需数据并卸载旧版。

两种构建均可用 `--build-number` 指定内部版本号。

### GitHub Actions

推送分支后，Actions 会生成 Linux 发布压缩包和 Android ARM64 调试 APK，可以在该次运行的 Artifacts 中下载。推送与 `pubspec.yaml` 版本一致的稳定标签（例如 `v0.1.0`）后，会构建正式签名的 APK，并把它和 Linux 包、`SHA256SUMS` 一起发布到 GitHub Release。公开仓库的 Release 成功后，工作流会继续更新 AUR。

## 手动验证

1. 打开「发现」，确认每日推荐有内容，点封面后歌曲会进入队列并开始播放。滑动堆叠卡片，点击区块标题右侧的箭头，确认能打开完整列表。登录后滑到私人 FM 末尾，检查加载图标是否与封面中心对齐。
2. 切到「搜索」，输入「晴天」，确认联想词出现、搜索结果可点播。
3. 用手机号获取验证码并登录。有多个账号时选择其一，再在「我的」里确认歌单能打开并播放。
4. 点击底部歌词按钮，在正在播放面板获取在线歌词，确认歌词随进度滚动。重启后也可以给恢复的酷狗曲目重新获取歌词。
5. 添加两首本地歌曲并切歌、暂停和拖动进度。Android 通过系统文件选择器保留原文件的读取授权，移动或删除原文件后需要重新添加。
6. 添加一个可公开访问的 HTTPS 音频直链，播放后导入对应的 LRC 文件，检查歌词是否随进度更新。
7. Android 上切到后台并锁屏，检查是否继续播放，以及通知栏、锁屏或耳机上的播放和切歌操作。Linux 上测试桌面媒体键。
8. 在播放页切换列表循环、单曲循环或倍速，在 Linux 桌面播放页拖动音量滑块。完全退出后再打开，检查设置、队列、所选歌曲、进度和歌词能否恢复。
9. 播放中拖动队列里的拖动手柄，确认当前歌曲和进度保持。点「播放全部」，确认队列按页面顺序替换，再用队列右上角的「清空队列」清空。打开「我的 → 最近播放」，测试重播和移除记录。
10. 在「正在播放」里选择音质，检查酷狗歌曲能从原进度继续。设置定时暂停，确认可以取消或重新计时，到时暂停并保留进度。
11. 播完一首在线歌曲后，检查「音频缓存」的文件数和占用空间。在设置中开启淡入淡出，检查开始播放、暂停和手动切歌时的音量过渡。

播放和系统媒体命令由 `lib/player/playback.dart` 处理。Linux 使用 libmpv，Android 使用 just_audio 的 Android 后端。队列、播放设置、最近播放和发现页的上次结果保存在本地 SQLite 数据库，音频文件由 `lib/player/audio_cache.dart` 管理。「最近播放」最多保留 100 首，酷狗歌曲重播时会重新取播放地址。

## Linux 启动排查

如果在 Wayland 会话中启动后窗口没有出现，且日志包含 `Timed out waiting for OpenGL frame`，可从项目根目录指定 GTK 使用 Wayland 后端。

```sh
GDK_BACKEND=wayland ./build/linux/x64/release/bundle/easy_music
```

如果已有实例，先从系统托盘重新打开窗口或选择「退出」。可以用下面的命令查看持有 D-Bus 单实例名称的进程。

```sh
gdbus call --session --dest org.freedesktop.DBus \
  --object-path /org/freedesktop/DBus \
  --method org.freedesktop.DBus.GetConnectionUnixProcessID \
  dev.easymusic.easy_music
```

本机排查时也可运行 `tool/run_easy_music.sh`。脚本会结束当前环境中可见的旧实例，并使用 Wayland 后端启动发布版。
