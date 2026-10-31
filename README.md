# Slurm 集群监控

面向 Android 的多集群 Slurm 监控应用，使用 **Flutter / Dart** 开发，原生桌面组件与小米卡片由 **Kotlin** 实现。当前版本：**1.9.0 (16)**。

通过 SSH 查看当前账号的作业、资源与完成历史，支持 SFTP 文件浏览、VASP/Gaussian 优化分析，以及用户主动触发的目录命令和任务提交。

## 界面预览

以下均为应用使用**合成演示数据**的截图；示例账号、域名、作业和节点不对应真实集群。

| 我的作业 | 节点空闲 | 连接管理 |
| --- | --- | --- |
| <img src="docs/images/dashboard.png" width="250" alt="作业总览演示" /> | <img src="docs/images/resources.png" width="250" alt="节点与分区资源演示" /> | <img src="docs/images/connections.png" width="250" alt="连接管理演示" /> |

[深色界面](docs/images/dashboard-dark.png) · [普通桌面组件](docs/images/desktop-widget.png) · [小米原生卡片](docs/images/xiaomi-card.png)

组件图片为 Android RemoteViews 渲染示例，不代表已经通过小米平台审核或在小米负一屏宿主验收。

## 主要功能

- 多服务器独立刷新、密码/私钥认证、SSH 主机指纹核验、失败退避和缓存提示。
- 作业状态与最近 7 天确认结束的历史；本地搜索、异常结束筛选、任务通知。
- 分区空闲节点统计、作业平均 CPU 和 RSS 占节点 Slurm 总内存的比例。
- 暂停时仅采集一次，配置变更后拒绝旧连接身份的迟到数据；队列不完整时保留上次完整结果并说明。
- SFTP 文件浏览、文本查找、结构预览；VASP OUTCAR 与 Gaussian 优化曲线、按需震荡趋势检查。
- 当前目录终端、明确确认后的 `sbatch` 提交、响应不确定时防止自动重复提交。
- 普通桌面小部件、小米卡片适配、明暗主题、宽屏与大字号布局。

## 开始使用

Android 最低版本为 Android 7 / API 24。可从维护者发布的 GitHub **Releases** 获取 APK，或自行构建；源码仓库不存放安装包和签名私钥。

首次启动后，在连接页添加服务器地址、SSH 用户和认证信息，核验主机指纹，再启动监控。内网服务器需先连接对应网络/VPN。没有作业时，也可通过连接页“文件与提交”浏览主目录。

仅适配 Slurm；连接配置不能直接切换为 PBS/Torque 或 LSF。Python 只用于可选的本机 SSH 测试工具，Android 应用不需要安装 Python。

详细步骤与统计口径见 [使用说明](docs/USAGE.md)。

## 本地构建

本次核验使用 **Flutter 3.47.8 stable / Dart 3.13.7 / JDK 17**。依赖下限以 [pubspec.yaml](pubspec.yaml) 为准（Flutter ≥3.44.0，Dart ≥3.12.0 且 <4.0.0）；Android SDK/NDK 版本由 Flutter/Gradle 配置决定。

```sh
flutter doctor
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

APK 输出：`build/app/outputs/flutter-apk/app-release.apk`。默认构建在没有本地发布密钥时使用开发测试签名；对外分发前配置自己的签名，并按 [测试与构建](docs/TESTING.md) 使用中性路径构建、保留私有符号和检查二进制元数据。

演示模式不连接真实集群：

```sh
flutter run --dart-define=DEMO=true
```

Web 目标用于演示界面，不提供浏览器直接连接真实 SSH 的能力。

## 目录结构

```text
lib/                  Flutter 页面、监控、SSH/SFTP、解析与数据模型
android/              Android 集成、原生组件与 Gradle Wrapper
web/                  Web 演示入口
test/                 单元、界面与可选协议测试
tool/                 仅监听本机的 SSH 测试服务
scripts/              Windows 检查与打包脚本
docs/                 使用、测试、上传和脱敏说明
docs/images/          合成数据示例图片
```

## 文档与边界

- [GitHub 上传说明](docs/GITHUB_UPLOAD.md)：新建仓库、首次提交、图片显示和发布 APK。
- [公开副本脱敏记录](docs/PRIVACY_REVIEW.md)：排除项、占位符和验证范围。
- [测试与构建](docs/TESTING.md)：本机 fixture、截图字体和设备验收。
- [版本记录](CHANGELOG.md)。

Android 后台监控受系统服务预算和设备省电策略约束。真实 VPN、集群插件差异、手机 GPU/耗电与小米宿主需另行验证。性能变化依赖具体场景，不承诺更换语言或使用本应用能提高 Slurm 作业计算速度。

许可证由维护者在发布前选择；本副本未代填作者身份或授权条款。
