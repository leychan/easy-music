# Easy Music 协作说明

## 开发约定

- 处理代码项目任务时，优先使用已配置的 CodeGraph MCP。项目缺少索引时，先询问用户，得到确认后再执行 `codegraph init`。
- 修改已有代码或 SQL 时，尽量保留原有格式。新增代码时，为需要解释的逻辑写清楚注释。
- 得到用户确认后再提交代码，提交信息使用中文。
- 本项目不使用 no-mistakes。直接运行项目的检查、测试和发布构建。
- 默认用简单易懂的方式说明改动，用户要求时再深入讲解。

## 每次修改后自动打包

完成一轮项目文件修改后，交付前主动在项目根目录依次执行以下发布构建。每次构建结束后检查对应产物，并在回复中说明打包结果和产物路径。某个平台构建失败时，检查原因并尝试修复，继续构建另一平台，最后说明仍存在的阻碍。

| 平台 | 打包命令 | 产物 |
| --- | --- | --- |
| Linux x86_64 | `flutter build linux --release` | `build/linux/x64/release/bundle/` |
| Android ARM64 | `flutter build apk --release --target-platform android-arm64` | `build/app/outputs/flutter-apk/app-release.apk` |

如果 Flutter 找不到 Android SDK，或系统默认 JDK 与 Gradle 不兼容，为本次打包命令指定 `ANDROID_HOME` 和 `JAVA_HOME`。当前开发机可使用 `$HOME/Android/Sdk` 和 `/usr/lib/jvm/java-20-jdk`。

## 安卓打包后覆盖安装

Android APK 构建成功并核对产物后，运行 `adb devices -l` 检查手机是否已连接。发现状态为 `device` 的目标手机时，直接运行 `adb -s <设备序列号> install -r build/app/outputs/flutter-apk/app-release.apk`，保留应用数据。没有可用手机时跳过安装。回复中说明安装是否成功，或说明手机拒绝安装等阻碍。
