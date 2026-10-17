# 知账 · Smart Ledger

离线优先的智能记账 App，支持手动记账、自动记账、OCR 和本地语音识别。账本、识别、解析、学习与统计默认在设备内完成，不依赖账号或云端服务。

当前稳定版本：`0.29.8`。

## 下载

- [Android ARM64 APK](https://github.com/wannenqingnian/KnowAccounts/releases/download/v0.29.8/smart-ledger-0.29.8-arm64.apk)
- [SHA-256 校验文件](https://github.com/wannenqingnian/KnowAccounts/releases/download/v0.29.8/smart-ledger-0.29.8-arm64.apk.sha256)
- [全部版本](https://github.com/wannenqingnian/KnowAccounts/releases)

当前发布包支持 Android 7.0 及以上，仅提供 `arm64-v8a` APK。iOS 和 Linux 项目源码保留在仓库中，但暂未提供安装包。

## 核心功能

### 记账

- 收入、支出、转账、退款、报销、分期、标签与图片附件。
- 多账本、多账户、多币种、两级分类和账单模板。
- 账单编辑、软删除、撤销、回收站、拆分、AA 与分组。
- 新建手动账单和自动记账核对弹窗均可切换目标账本。

### 智能输入

- 一句话记账和 SenseVoiceSmall 本地语音识别。
- PP-OCRv6 本地截图/图片识别，模型由用户按需下载。
- Android 通知、无障碍页面和快捷磁贴入口。
- 微信、支付宝、云闪付及 Excel/CSV 账单导入。
- 重复候选、置信度、待确认草稿和人工修正规则。

### 财务与分析

- 月度、季度、年度和分类预算。
- 月/年/自定义周期分析、分类与标签排行、日历热力和余额趋势。
- 信用卡账期、房贷、分期、借出/收回、股票、基金和定期存款。
- 周期收支、周期转账、周期投资、提醒和失败重试。

### 数据与外观

- AES-256-GCM 加密备份及 WebDAV 加密整库上传/恢复。
- 浅色/深色模式、主题色、背景、字体、字号和图标风格。
- 金额隐私模式、日志中心和本地安全存储。

## 隐私与权限

- OCR、语音、通知解析和账单学习默认在本机执行。
- 原始录音默认不落盘、不上传；OCR 模型不会自动下载。
- 通知读取、无障碍、悬浮窗和通知权限均由用户主动开启。
- WebDAV 凭据、备份密码和完整卡号保存在系统安全存储中。
- 本地 SQLite 尚未整体加密；导出的 `.slbackup` 备份使用用户密码加密。

## 运行与构建

需要 Flutter `3.47.6`、Dart `3.13.5` 和 Android SDK：

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

验证 APK 中的本地 OCR/自动记账组件：

```bash
python3 tool/verify_ocr_jni_apk.py build/app/outputs/flutter-apk/app-release.apk
python3 tool/verify_automation_apk.py build/app/outputs/flutter-apk/app-release.apk --aapt "$ANDROID_HOME/build-tools/36.0.0/aapt"
```

GitHub Actions 会在 `main` 更新时构建 Android ARM64 产物。推送与 `pubspec.yaml` 一致的版本标签（例如 `v0.29.8`）后，会使用 GitHub Actions Secrets 中保存的固定签名构建 APK、生成 SHA-256 文件并发布 GitHub Release。签名私钥不会提交到源码。

## 项目结构

```text
lib/
  core/database/       SQLite 数据库与迁移
  domain/              核心模型与金额规则
  data/                Repository、交易校验与查询
  features/            总览、流水、账户、分析与管理界面
  automation/          Android 自动记账与快捷入口
  speech/              本地语音模型与识别
  import/              账单导入、映射与退款关联
  backup/              加密备份与恢复
android/               Android 原生服务与构建配置
test/                  Flutter 自动测试
tool/                  APK 校验与预览工具
docs/                  功能、设计与开发文档
```

## 文档

- [开发计划与功能边界](docs/DEVELOPMENT.md)
- [Android 构建说明](docs/ANDROID_BUILD.md)
- [自动记账说明](docs/AUTOMATION.md)
- [OCR 模型与识别](docs/OCR.md)
- [本地语音记账](docs/SPEECH.md)
- [统一置信度引擎](docs/CONFIDENCE.md)
- [备份、账户与维护说明](docs/MAINTENANCE.md)

首次启动只创建空账本、默认账户和分类，不插入演示交易。自动记账在字段缺失、冲突、低置信或疑似重复时进入人工核对，不会为了提高自动入账率而静默保存不确定账单。
