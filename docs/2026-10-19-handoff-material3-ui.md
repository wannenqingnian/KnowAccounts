# Handoff: Material 3 界面统一与发布前验收

> **Resumption instruction:** Review this document, then confirm your
> understanding in 2–3 sentences before proceeding with the next step.
> This document is self-contained — do not consult or load the handoff
> skill; it is for creating handoffs, not resuming from them.
> Items marked (user) are user-stated: decisions so marked are fixed and
> must not be revisited without asking; steps so marked must be prompted
> to the user, not attempted.

**Date:** 2026-10-19

**Work type:** Building / Problem-Solving

**Status:** Nearing Completion

---

## Objective

在不改变业务逻辑、状态管理、数据库和 API 的前提下，使用 Flutter 原生 Widget 与 Material 3 统一知账的视觉体系，重点改善首页、导航、账户卡片、按钮、表单、手动记账和自动记账弹窗，并补齐深色模式、小屏、大字体、安全区域与键盘弹出适配。

## Current State

- 当前稳定版本仍为 `0.29.10+76`，Git 基线标签为 `v0.29.10`。
- Material 3 UI 优化已实现，提交在包含本文档的 `main` 分支提交中；未创建新版本标签或 GitHub Release。
- 现有绿色品牌色和用户可配置主题能力保留。界面优先使用 `ColorScheme` 语义色，深色模式不再依赖主要页面中的固定白色背景。
- 手动记账、智能识别、OCR、账户、分析、回收站和语音等核心流程未改变。
- 仓库中的 `android/gradle - 副本.properties`、`smart_ledger_src_v0.29.6.zip` 和本机生成的 `.flutter-plugins-dependencies` 不属于本次交付，不应提交。

## Progress

- 扩充全局主题：文字层级、输入框、卡片、按钮、图标按钮、FAB、导航栏、侧栏、列表、分隔线、Chip、Dialog、BottomSheet、Menu 和 SnackBar。
- 系统文字缩放与应用字号设置改为叠加，并限制在可用范围内，不再覆盖 Android/iOS 的系统辅助字号。
- 首页增加 840px 响应式断点：手机使用底部导航，宽屏使用侧栏；主内容限制最大宽度。
- 总览、预算、分类支出和流水列表改用主题语义色，保持原有绿色视觉方向。
- 账户净资产卡片与三栏摘要支持深色模式；金额行使用缩放保护，修复 430px 屏幕横向溢出。
- 手动记账弹窗保留拖拽柄并调整为屏幕高度的 92%，避免遮住关闭区域；内容继续通过滚动和 `viewInsets` 适配键盘。
- 智能录入和外观页操作按钮改用 `OverflowBar`，窄屏或大字体时可自动换行。
- 待确认、重复候选和已忽略页面统一为空状态组件。
- 新增 360×800、深色模式、160% 系统字号的回归测试。

## Decisions Made

- **(user) 使用 Material 3，同时兼顾 Android 和 iOS 交互习惯。** 继续使用 Flutter 原生路由、控件和平台自适应行为，不引入 HTML、CSS 或 React。
- **(user) 保留软件自带主题，主题颜色不能变化过大。** 使用现有绿色种子色生成语义色，未采用独立品牌色或高饱和渐变重做。
- **(user) 不修改业务逻辑、状态管理和 API。** 本次修改集中在主题、布局、组件样式和 Widget 测试。
- **(user) 优先复用现有组件。** `SectionCard`、`EntryTile` 和 `EmptyView` 继续作为共享组件，只补充主题感知能力。
- 保留五个一级导航目的地。项目恰好有总览、流水、账户、分析、管理五个入口，符合 Material 3 `NavigationBar` 的使用边界，无需新增抽屉或路由层。
- 不在本次提交中升版本或发布 APK。用户本次只要求提交源码和交接文档；发布应在真机验收或明确要求后进行。

## Approaches That Did Not Work

- UI UX Pro Max 搜索返回的玻璃拟态、深蓝配色和网页字体方案与现有记账 App 风格不符，未采用；只采纳 Material 3、对比度、触控尺寸和响应式原则。
- 全局强制所有 BottomSheet 显示拖拽柄会让 96% 高度的记账弹窗占满可关闭区域。最终只在需要的弹窗显式显示，并把记账弹窗高度降为 92%。
- `OverflowBarAlignment.stretch` 在当前 Flutter 3.47.6 SDK 中不存在。已改为兼容的 `OverflowBar` 自动换行配置。
- Windows 上连续启动多个 Flutter 测试进程时偶发 `did not complete`。改为串行或单文件重跑后，核心回归稳定通过。

## Open Discussions

- **下一发布版本** — 尚未决定是否将本次 UI 优化发布为 `0.29.11`。需要先完成真机视觉验收，再决定版本号、Release Notes 和标签。
- **截图 OCR 重试测试** — `capture_widget_test.dart` 中“模型已就绪后重试同一截图”用例曾在完整文件运行时找不到 `transaction_tags`；前三个截图流程通过，单独重跑又受 Windows 测试宿主偶发未完成影响，尚未形成稳定结论。
- **维护页旧断言** — `maintenance_widget_test.dart` 仍期待旧文案“请选择可用项或先在管理中恢复”，而当前代码和 `v0.29.10` 基线文案为“请重新选择可用项”。这是已有测试与实现不一致，本次没有顺手修改。

## Project Context

- 仓库：`https://github.com/wannenqingnian/KnowAccounts`，默认交付分支为 `main`。
- 应用离线优先；自动记账、OCR 和语音识别默认在本机处理。不应为提高自动入账率而绕过置信度、重复检测或人工确认。
- Android 是当前唯一发布安装包的平台，GitHub Actions 构建 `arm64-v8a` APK。iOS 和 Linux 保留源码但暂不发布安装包。
- 稳定签名通过 GitHub Actions Secrets 恢复，私钥不得提交到公开仓库。
- 最近版本已经处理自动记账重复、退款误弹、待报销、账户联动、分类一致性，以及手动记账中重复账户/分类/时间控件。后续 UI 修改不得恢复这些问题。

## Next Steps

1. 在 Android 真机上检查 360–430px 屏幕、系统 100%/160% 字号、浅色/深色、键盘弹出、底部手势区域和横竖屏切换。
2. 单独稳定复现并修复截图 OCR 重试测试；同步维护页断言与当前产品文案。
3. 若真机验收通过，再将版本升至下一个版本，更新 `README.md` 与 `RELEASE_NOTES.md`。
4. 推送与 `pubspec.yaml` 一致的版本标签，由 GitHub Actions 使用稳定签名构建并发布 Android ARM64 APK。

## Key References

- `lib/main.dart`：Material 3 全局主题和系统字号合并。
- `lib/features/home_shell.dart`：响应式首页、导航和总览。
- `lib/features/widgets.dart`：共享卡片、流水和空状态。
- `lib/features/manage_page.dart`：账户概览和小屏金额布局。
- `lib/features/transaction_editor.dart`：手动/自动核对共用记账弹窗。
- `lib/features/smart_input.dart`：智能输入弹窗。
- `lib/features/review_inbox.dart`：待确认、重复候选、已忽略页面。
- `lib/features/appearance_page.dart`：主题设置页。
- `test/widget_test.dart`：核心流程与小屏深色大字体回归。
- 验证结果：`flutter analyze --no-pub` 无问题；核心 Widget 12 项、分析 2 项、自动记账/OCR/回收站/语音 10 项通过。
