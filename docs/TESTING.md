# 测试与构建

## 快速检查

安装与 `pubspec.yaml` 兼容的 Flutter stable、JDK 17、Android SDK，先执行 `flutter doctor`。SDK 路径由本机生成的 `android/local.properties` 记录，不应提交。

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

默认没有本机 fixture 或真实服务器环境变量时，相应集成测试跳过。不要将“测试运行结束”解释为真实集群已经验收。真实服务器冒烟只在明确设置 `SLURM_TEST_*` 后运行，普通贡献者不需要提供这些变量。

Windows 可使用 PowerShell 7 运行 `scripts/check.ps1 -Build`；脚本优先使用本地 `.tooling`，否则使用 PATH 中的 Flutter 和系统工具链。`scripts/package.ps1` 生成本地交付产物，输出目录已被 Git 忽略。

## 完整本机 SSH/SFTP 检查

Python 仅用于此测试服务。准备 Python 3.10+，在独立虚拟环境安装 `paramiko`；运行目录用于一次性密钥和模拟连接参数，必须使用已被忽略的路径。

终端一：

```sh
python -m pip install paramiko
python tool/ssh_fixture_server.py .tooling/ssh-fixture
```

等待 `Loopback SSH fixture ready`，保持该终端运行。终端二在项目根目录执行：

```powershell
$env:SLURM_SSH_FIXTURE = (Resolve-Path '.tooling/ssh-fixture').Path
flutter test --concurrency=1
```

使用 Bash 时：

```sh
SLURM_SSH_FIXTURE="$PWD/.tooling/ssh-fixture" flutter test --concurrency=1
```

测试服务只监听 `127.0.0.1`，作业与提交编号为模拟值。脚本运行时生成临时密钥，不包含真实集群凭据。测试完成后在终端一按 Ctrl+C 停止；不要上传 fixture 目录或 `connection.json`。

运行前清除与本次测试无关的 `SLURM_TEST_*` 环境变量，以免误触发可选的真实服务器用例。检查计数不能代替真实网络/VPN与手机验证。

## 可选截图

`test/visual_review_test.dart` 覆盖手机、宽屏、大字号与明暗主题。默认不写图片；需要可读截图时，通过以下环境变量提供本机资源路径：

| 变量 | 用途 |
| --- | --- |
| `SLURM_SCREENSHOTS` | 图片输出目录，建议 `.tooling/screenshots` |
| `SLURM_TEST_FONT` | 有权使用的中文字体文件，随本机提供，不放进仓库 |
| `SLURM_TEST_MATERIAL_ICONS` | Flutter SDK 内的 `MaterialIcons-Regular.otf` |

只生成演示数据截图；发布前核对可见文本及图像元数据。仓库自带图片的来源见 [脱敏记录](PRIVACY_REVIEW.md)。

## 发布签名

`android/key.properties.example` 只有占位符。复制为本机 `android/key.properties`，改为自己持有的签名密钥信息；密钥应放在仓库之外，真实配置和私钥均已被忽略。

没有本地发布密钥时，现有 Gradle 配置回退到 debug 签名，适用于开发测试。向用户分发前检查签名；升级必须沿用同一应用身份与签名。

Android 原生检查可在模拟器中构建安装 debug 应用与 androidTest APK 后，通过 `adb shell am instrument -w com.example.slurm_cluster_monitor.test/com.example.slurm_cluster_monitor.XiaomiWidgetInstrumentation` 运行。普通 Android 模拟器不能替代小米宿主验收。

## 公开安装包的路径与符号

源码没有个人信息，也不代表编译产物一定没有。本次检查旧 APK 时，发现插件注册器的编译 URI 保留了构建机绝对路径。公开分发时不要直接复用旧 APK。

将源码放在不含姓名或个人目录的中性构建位置，例如 Windows 的 `C:/build/slurm-cluster-monitor`，或 Linux 的 `/tmp/slurm-build`，从该位置重新解析依赖并构建：

```sh
flutter pub get
flutter build apk --release --split-debug-info=.tooling/symbols/android
```

`.tooling/symbols/android` 用于保存匹配版本的调试符号，应单独备份以便诊断，不提交到 Git 或附在公开 Release 中。分离符号本身不保证消除所有路径；发布前仍要扫描 APK 解包内容、核对证书身份，并检查是否残留个人路径或凭据。有关构建和符号选项见 [Flutter 官方说明](https://docs.flutter.dev/deployment/obfuscate)。本流程没有启用代码混淆，也不把混淆作为保护凭据的方法。

## 已有验证与本次范围

1.9.0 原交付记录为静态分析通过、193 项 Flutter 回归通过 / 1 项真实集群跳过、11 项原生组件检查通过。本公开副本没有修改 `lib/` 或 Android 应用功能代码，仅调整发布文档、忽略/打包规则、测试数据/字体路径及 Web 图标元数据。本次另行运行静态分析与相关 7 项测试，均通过；没有重复运行整套历史测试。完整核验范围见 [脱敏记录](PRIVACY_REVIEW.md)。

真实 VPN、Android 后台预算、手机 GPU/耗电、Slurm 插件差异与小米卡片宿主仍需实际设备验证。
