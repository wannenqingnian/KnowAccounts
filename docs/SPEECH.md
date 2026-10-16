# 本地语音记账

Android 0.16.1 使用 sherpa-onnx 1.13.8、SenseVoiceSmall INT8 和 Silero VAD INT8。推理运行库随 APK 提供，但模型权重不内置、不自动下载。

用户在“管理 → 语音模型”中主动下载约 156 MB 的官方模型包。App 校验下载大小和 SHA-256，在应用私有目录解压出约 229 MB 的模型文件，再次校验后原子启用；失败或取消不会替换已有可用模型。模型可随时删除，账本和草稿不受影响。安装阶段需要额外临时空间保存压缩包。

识别流程为：

```text
立即录音 + 并行加载模型 → Silero VAD 自动截句 → SenseVoiceSmall 本地识别
       → 领域同音词纠正 → ChineseNumberParser → TransactionParser
       → 持久化待确认草稿
```

录音只在当前识别任务的内存中处理，不写入文件、不上传。点击语音按钮时只读取小型安装清单并检查文件大小，不再扫描并哈希约239 MB的模型；麦克风随即启动，同时在另一线程加载模型。冷启动期间说出的开头也会保留，模型就绪后会补做 VAD 与识别。默认一直录音到用户点击“完成录音”，不会自行按固定时间结束。用户也可在“管理 → 语音模型”中单独开启静音自动结束，并设置检测到说话后连续静音1～10秒结束（默认2秒）；还可选设5～300秒最长录音时长。下载安装阶段仍会完整校验模型，管理页“运行模型自检”也会重新执行完整哈希与模型初始化。未检测到语音或模型损坏时不会生成账单。

未安装本地模型时，界面提供“下载模型”和“系统语音”两个明确选项。系统语音仅作为临时兜底，是否离线及是否联网由手机所安装的语音服务决定。所有识别文字都可在生成草稿前编辑，正式入账仍需用户核对。

模型来源：

- sherpa-onnx 1.13.8：`k2-fsa/sherpa-onnx` 官方 GitHub Release
- SenseVoiceSmall INT8：`sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17`
- Silero VAD INT8：sherpa-onnx 官方 ASR 模型 Release

下载清单和固定哈希位于 `lib/speech/speech_model_service.dart`，Android 录音、VAD 和解码桥接位于 `LocalSpeechEngine.kt`。
