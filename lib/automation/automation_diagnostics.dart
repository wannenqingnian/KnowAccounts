import 'payment_apps.dart';
import 'payment_quality.dart';

const diagnosticLabels = <String, String>{
  'notification_connected': '通知监听服务已连接',
  'notification_disconnected': '通知监听服务已断开',
  'accessibility_connected': '无障碍服务已连接',
  'accessibility_interrupted': '无障碍采集被中断',
  'accessibility_disconnected': '无障碍服务已断开',
  'event_received': '支付软件页面发生变化',
  'event_text_read': '已读取本次页面提供的文本',
  'page_session_started': '开始收集本次交易的分段信息',
  'page_session_waiting': '金额或成功状态还未出现',
  'page_session_matched': '已组合出一笔可处理的交易',
  'page_session_resumed': 'OCR结束，立即检查最新账单页面',
  'ocr_fallback': '页面节点信息不足，转入本地截图OCR',
  'ocr_event_coalesced': 'OCR期间检测到新的页面变化',
  'screenshot_requested': '已请求单帧截图OCR',
  'screenshot_capability_missing': '系统尚未授予截图能力，请关闭后重新开启无障碍服务',
  'screenshot_unavailable': '系统未提供截图，请重新授权无障碍',
  'ocr_model_missing': '未安装可用的飞桨OCR模型',
  'ocr_started': '已开始本地飞桨OCR',
  'quick_capture_started': '快捷截图服务已启动',
  'quick_capture_ready': '已取得支付页面截图',
  'quick_capture_cancelled': '用户取消了系统截图授权',
  'quick_capture_failed': '系统截图未完成，可从通知栏直接重试',
  'quick_ocr_text_read': '快捷截图已读取文字行',
  'quick_ocr_matched': '快捷截图OCR已识别，正在生成账单草稿',
  'quick_ocr_failed': '快捷截图未识别到账单，已发送失败通知',
  'ocr_no_match': '截图未匹配明确的已完成账单',
  'ocr_matched': '截图 OCR 匹配成功，已提交生成草稿',
  'ocr_failed': '本地截图OCR处理失败',
  'master_disabled': '未采集：自动记账总开关关闭',
  'enhanced_disabled': '未采集：无障碍增强关闭',
  'app_disabled': '未采集：该软件来源未启用',
  'chat_filtered': '已过滤普通聊天窗口或聊天通知',
  'empty_content': '来源没有提供可读取的内容',
  'window_changed': '当前窗口已切换，停止本次读取',
  'node_read': '已扫描支付页面结构',
  'no_payment_match': '未匹配明确交易账单',
  'matched': '已匹配交易信息',
  'too_long': '内容超出识别长度限制',
  'group_summary': '已跳过通知分组摘要',
  'untrusted_title': '微信通知标题未匹配支付渠道',
  'state_unsupported': '已跳过未支付、失败、退款或营销等内容',
  'success_missing': '未找到明确交易成功状态',
  'money_missing': '未找到可识别的交易金额',
  'fields_missing': '页面缺少明确账单字段',
  'read_failed': '页面读取失败',
  'queued': '采集已进入后台队列',
  'replay_skipped': '这笔交易已处理，未重复弹窗',
  'queue_dropped': '队列超限或过期，已丢弃旧采集',
  'config_saved': '自动记账配置已保存',
  'queue_reset': '配置变化，取消未处理的旧采集',
  'reconnect_requested': '正在请求 Android 重新连接通知服务',
  'retry_requested': '用户请求后台重试',
  'worker_start': '后台处理引擎开始启动',
  'worker_ready': '后台数据库已就绪',
  'worker_take': '后台开始解析本次采集',
  'confidence_high': '统一置信度为高，可自动入账',
  'confidence_review': '统一置信度为中，需要人工核对',
  'confidence_low': '统一置信度为低，仅允许人工填写',
  'worker_revoked': '采集授权已变化，未继续处理',
  'worker_posted': '账单已自动保存',
  'worker_pending': '账单已保留为待确认草稿',
  'worker_duplicate_order': '疑似重复：订单号与已有账单一致',
  'worker_duplicate_semantic': '疑似重复：商户、金额、账户和时间一致',
  'worker_duplicate_same_day': '疑似重复：同日同商户同金额',
  'worker_duplicate_time': '疑似重复：金额、账户和时间相近',
  'worker_quality': '本次识别质量已评分',
  'worker_repeated': '已有本次采集的草稿或账单',
  'worker_discarded': '目标账本不存在，采集未入账',
  'worker_finish': '本轮后台处理完成',
  'worker_start_failed': '后台引擎启动失败',
  'worker_timeout': '后台启动或处理超时',
  'plugin_unavailable': '后台组件未连接',
  'invalid_capture': '采集格式异常',
  'database_error': '数据库暂不可用',
  'processing_error': '后台处理失败',
  'amount_missing': '草稿金额未确定，需用户补充',
  'account_missing': '草稿账户未确定，需用户选择',
  'category_missing': '草稿分类未确定，需用户选择',
  'peer_review': '转账或红包需核对收支方向',
  'warning_review': '草稿存在识别警告，需用户核对',
  'overlay_denied': '未获得悬浮窗权限，草稿仍保留',
  'overlay_queued': '草稿已进入悬浮表单队列',
  'overlay_overflow': '悬浮队列已满，请查看待确认账单',
  'overlay_expanded': '记账悬浮表单已展开',
  'overlay_collapsed': '记账表单已收起为悬浮球',
  'overlay_failed': '系统未允许显示悬浮窗，请查看待确认账单',
  'form_submitted': '用户已提交保存或忽略操作',
  'form_saved': '表单操作保存成功',
  'form_rejected': '表单保存未完成，请核对字段或重试',
  'form_duplicate': '检测到疑似重复，需要用户明确确认',
  'app_exception': '软件/系统运行异常',
  'sync_exception': '云备份/WebDAV同步异常',
  'db_exception': '本地数据库存储异常',
  'ocr_engine_exception': 'OCR模型引擎运行异常',
  'network_exception': '网络请求/接口连接异常',
};

enum DiagnosticLevel { normal, progress, success, warning, error }

class DiagnosticExplanation {
  const DiagnosticExplanation({
    required this.what,
    required this.result,
    this.action = '',
    this.level = DiagnosticLevel.normal,
  });

  final String what;
  final String result;
  final String action;
  final DiagnosticLevel level;
}

const diagnosticStateLabels = <String, String>{
  'sensitiveLogging': '敏感识别信息日志',
  'enabled': '自动记账总开关',
  'enhanced': '无障碍增强',
  'screenshotFallback': '支付页面本地截图OCR增强',
  'ocrModelReady': '飞桨OCR模型可用',
  'reviewPopup': '识别后弹窗',
  'wechatEnabled': '微信来源开关',
  'notificationsGranted': '通知读取权限',
  'notificationConnected': '通知服务连接',
  'accessibilityGranted': '无障碍权限',
  'accessibilityConnected': '无障碍服务连接',
  'overlayGranted': '悬浮窗权限',
  'overlayVisible': '悬浮窗当前可见',
  'batteryExempt': '已忽略电池优化',
  'workerRunning': '后台正在处理',
};

class DiagnosticEvent {
  const DiagnosticEvent(
    this.time,
    this.code,
    this.app,
    this.source,
    this.reference,
    this.count,
    this.repeats, {
    this.fields = const {},
  });
  final int time, count, repeats;
  final String code, app, source, reference;
  final Map<String, String> fields;
  String get label => diagnosticLabels[code]!;
  PaymentQuality? get quality =>
      code == 'worker_quality' ? PaymentQuality.tryParse(fields) : null;
  String get recognizedText => fields.entries
      .where(
        (item) => const {
          'amount',
          'merchant',
          'account',
          'category',
        }.contains(item.key),
      )
      .map(
        (item) =>
            '${switch (item.key) {
              'amount' => '金额',
              'merchant' => '商户',
              'account' => '账户',
              _ => '分类',
            }} ${item.value}',
      )
      .join(' · ');

  /// High-frequency lifecycle probes stay available through the “处理中”
  /// filter, but do not flood the default meaningful-event view or export.
  bool get isInternalNoise => const {
    'event_received',
    'event_text_read',
    'page_session_started',
    'page_session_waiting',
    'page_session_resumed',
    'ocr_event_coalesced',
    'screenshot_requested',
    'ocr_started',
    'node_read',
    'worker_start',
    'worker_ready',
    'worker_take',
    'worker_finish',
    'reconnect_requested',
  }.contains(code);

  String detailedText() {
    final detail = explanation;
    final recognized = recognizedText;
    final level = switch (detail.level) {
      DiagnosticLevel.error => '错误',
      DiagnosticLevel.warning => '警告',
      DiagnosticLevel.success => '成功',
      DiagnosticLevel.progress => '处理中',
      DiagnosticLevel.normal => '记录',
    };
    return '${DateTime.fromMillisecondsSinceEpoch(time).toLocal().toIso8601String()} '
        '| $level | $origin | $label'
        '${detail.result.isEmpty ? "" : " | ${detail.result}"}'
        '${detail.action.isEmpty ? "" : " | 建议：${detail.action}"}'
        '${reference.isEmpty ? "" : " | 编号 $reference"}'
        '${count == 0 ? "" : " | 数量 $count"}'
        '${repeats <= 1 ? "" : " | 合并重复 $repeats 次"}'
        '${recognized.isEmpty ? "" : " | 识别：$recognized"}'
        '${quality == null ? "" : " | 质量 ${quality!.score} 分 ${quality!.summary}"}'
        ' | 事件码 $code\n';
  }

  /// A user-facing explanation. It deliberately uses only allowlisted state
  /// and counters, never captured payment text or other sensitive content.
  DiagnosticExplanation get explanation => switch (code) {
    'notification_connected' => const DiagnosticExplanation(
      what: '通知监听服务已建立连接。',
      result: '通知自动记账就绪。',
      level: DiagnosticLevel.success,
    ),
    'notification_disconnected' => const DiagnosticExplanation(
      what: '通知监听服务与 Android 断开。',
      result: '无法接收新的支付通知。',
      action: '请在系统设置中重新勾选通知读取权限。',
      level: DiagnosticLevel.warning,
    ),
    'accessibility_connected' => const DiagnosticExplanation(
      what: '无障碍服务已建立连接。',
      result: '无障碍页面增强就绪。',
      level: DiagnosticLevel.success,
    ),
    'accessibility_interrupted' ||
    'accessibility_disconnected' => const DiagnosticExplanation(
      what: '无障碍服务已被系统中断或关闭。',
      result: '无法继续读取支付应用视图。',
      action: '请在系统设置中重新开启知账无障碍服务。',
      level: DiagnosticLevel.warning,
    ),
    'event_received' => DiagnosticExplanation(
      what: '触发识别账单：监听到支付应用前台视图发生变动。',
      result: repeats > 1 ? '已合并处理短时间内 $repeats 次视图变动。' : '准备扫描交易字段。',
      level: DiagnosticLevel.progress,
    ),
    'event_text_read' => DiagnosticExplanation(
      what: '识别账单原因：提取到${count > 0 ? " $count 段" : ""}可见页面文本线索。',
      result: '开始匹配金额与完成状态。',
      level: DiagnosticLevel.progress,
    ),
    'page_session_started' => const DiagnosticExplanation(
      what: '识别账单原因：开始组合合并分段显示的支付信息。',
      result: '信息收集阶段。',
      level: DiagnosticLevel.progress,
    ),
    'page_session_waiting' => DiagnosticExplanation(
      what: '识别失败原因：页面未同时出现金额和完成标志。',
      result: '已发起${count > 0 ? "第 $count 次" : ""}重试。',
      action: '请停留在完成页片刻；若最后显示“未匹配”请导出日志。',
      level: DiagnosticLevel.progress,
    ),
    'page_session_matched' => DiagnosticExplanation(
      what: '识别账单成功：已从多次页面变动中组合出完整交易结构。',
      result: '匹配通过，即将送入后台解析与去重。',
      level: DiagnosticLevel.success,
    ),
    'page_session_resumed' => const DiagnosticExplanation(
      what: '触发识别账单：页面发生新变动，跳过旧事件积压。',
      result: '直接读取最新视图。',
      level: DiagnosticLevel.progress,
    ),
    'ocr_event_coalesced' => const DiagnosticExplanation(
      what: '触发识别账单：OCR 运行期间收到后续事件，保持最新视图。',
      result: 'OCR 结束后继续处理。',
      level: DiagnosticLevel.progress,
    ),
    'ocr_fallback' => const DiagnosticExplanation(
      what: '启动 OCR 原因：无障碍节点字段不足（缺少金额或完成状态），转入本地单帧截图 OCR 补全。',
      result: '正在尝试截图识别。',
      action: '请确保离线 OCR 模型已安装。',
      level: DiagnosticLevel.progress,
    ),
    'screenshot_requested' => const DiagnosticExplanation(
      what: '启动 OCR 原因：触发无障碍单帧截图识别流程。',
      result: '等待图像返回。',
      level: DiagnosticLevel.progress,
    ),
    'screenshot_capability_missing' ||
    'screenshot_unavailable' => const DiagnosticExplanation(
      what: '启动 OCR 失败：Android 系统未提供截图能力。',
      result: '无法进行截图 OCR。',
      action: '请重新开关知账无障碍服务。',
      level: DiagnosticLevel.warning,
    ),
    'ocr_model_missing' => const DiagnosticExplanation(
      what: '启动 OCR 失败：未找到离线飞桨 OCR 模型。',
      result: '无法使用截图识别。',
      action: '请在管理页“OCR 模型”中下载模型。',
      level: DiagnosticLevel.warning,
    ),
    'ocr_started' => const DiagnosticExplanation(
      what: '启动 OCR 原因：已获取画面图像，开始运行本地飞桨模型。',
      result: '图像识别中。',
      level: DiagnosticLevel.progress,
    ),
    'quick_capture_started' => const DiagnosticExplanation(
      what: '启动 OCR 原因：用户从快捷栏/通知栏主动发起截图记账。',
      result: '获取屏幕图像中。',
      level: DiagnosticLevel.progress,
    ),
    'quick_capture_ready' => const DiagnosticExplanation(
      what: '启动 OCR 原因：已取得单帧屏幕截图，送入飞桨矩阵解析。',
      result: '送入 OCR 解析。',
      level: DiagnosticLevel.success,
    ),
    'quick_capture_cancelled' => const DiagnosticExplanation(
      what: '启动 OCR 失败：用户取消了系统截图授权。',
      result: '取消识别。',
      action: '重新发起截图并允许授权。',
      level: DiagnosticLevel.warning,
    ),
    'quick_capture_failed' => const DiagnosticExplanation(
      what: '启动 OCR 失败：系统单帧截图未获取到图像。',
      result: '未获得可用图像。',
      action: '请在交易详情页重试。',
      level: DiagnosticLevel.error,
    ),
    'quick_ocr_text_read' => DiagnosticExplanation(
      what: '识别账单原因：快捷截图 OCR 提取到${count > 0 ? " $count 行" : ""}文字。',
      result: '筛选交易字段中。',
      level: DiagnosticLevel.progress,
    ),
    'quick_ocr_matched' => const DiagnosticExplanation(
      what: '识别账单成功：快捷截图成功识别金额与完成状态。',
      result: '已送入后台生成可编辑的账单草稿。',
      level: DiagnosticLevel.success,
    ),
    'quick_ocr_failed' || 'ocr_no_match' => const DiagnosticExplanation(
      what: '识别失败原因：截图文本中未找到明确金额和已完成交易证据。',
      result: '为避免误记，未生成账单。',
      action: '请在交易详情或支付成功页重试，确保无遮挡。',
      level: DiagnosticLevel.warning,
    ),
    'ocr_matched' => const DiagnosticExplanation(
      what: '识别账单成功：本地截图 OCR 成功匹配到已完成交易。',
      result: '已生成账单草稿并送入后台去重。',
      level: DiagnosticLevel.success,
    ),
    'ocr_failed' => const DiagnosticExplanation(
      what: '识别失败原因：本地 OCR 模型计算或图像解码发生错误。',
      result: '未完成识别。',
      action: '请在模型管理页重试或重新下载模型。',
      level: DiagnosticLevel.error,
    ),
    'master_disabled' => const DiagnosticExplanation(
      what: '已跳过：自动记账总开关未开启。',
      result: '跳过事件处理。',
      action: '在管理页开启自动记账总开关。',
      level: DiagnosticLevel.warning,
    ),
    'enhanced_disabled' => const DiagnosticExplanation(
      what: '已跳过：无障碍增强开关未开启。',
      result: '跳过页面采集。',
      action: '在设置中开启无障碍增强。',
      level: DiagnosticLevel.warning,
    ),
    'app_disabled' => const DiagnosticExplanation(
      what: '已跳过：当前应用来源未启用。',
      result: '跳过事件处理。',
      action: '在支持的应用列表中勾选开启。',
      level: DiagnosticLevel.warning,
    ),
    'chat_filtered' => const DiagnosticExplanation(
      what: '识别为普通聊天内容。',
      result: '已过滤，避免把聊天误记为账单。',
      level: DiagnosticLevel.normal,
    ),
    'empty_content' => const DiagnosticExplanation(
      what: '页面无有效可读内容。',
      result: '无字段可供解析。',
      action: '等待结果页加载完毕，或尝试截图 OCR。',
      level: DiagnosticLevel.warning,
    ),
    'window_changed' => const DiagnosticExplanation(
      what: '前台窗口发生切换。',
      result: '停止本轮读取，防止内容混淆。',
      level: DiagnosticLevel.normal,
    ),
    'node_read' => DiagnosticExplanation(
      what: '无障碍服务扫描了${count > 0 ? " $count 个" : ""}页面节点。',
      result: '检索交易字段中。',
      level: DiagnosticLevel.progress,
    ),
    'no_payment_match' || 'fields_missing' => const DiagnosticExplanation(
      what: '已读取页面，但缺少确定账单所需的关键字段。',
      result: '暂不生成账单。',
      action: '请打开包含实付金额的交易详情页。',
      level: DiagnosticLevel.warning,
    ),
    'matched' => const DiagnosticExplanation(
      what: '成功匹配到交易状态与基本字段。',
      result: '识别成功，下一步送入后台解析。',
      level: DiagnosticLevel.success,
    ),
    'too_long' => const DiagnosticExplanation(
      what: '文本超出最大限制。',
      result: '停止解析。',
      level: DiagnosticLevel.warning,
    ),
    'group_summary' => const DiagnosticExplanation(
      what: '跳过系统通知摘要消息。',
      result: '等待具体账单通知。',
      level: DiagnosticLevel.normal,
    ),
    'untrusted_title' => const DiagnosticExplanation(
      what: '微信通知标题未匹配官方支付通道。',
      result: '已过滤普通聊天通知。',
      level: DiagnosticLevel.normal,
    ),
    'state_unsupported' => const DiagnosticExplanation(
      what: '显示为未支付、取消、处理中或非消费页面。',
      result: '已跳过，仅已完成交易才会记录。',
      level: DiagnosticLevel.normal,
    ),
    'success_missing' => const DiagnosticExplanation(
      what: '未找到“支付成功/已完成”等交易状态标志。',
      result: '暂不生成账单，避免记录未完成订单。',
      action: '请打开显示交易成功状态的界面。',
      level: DiagnosticLevel.warning,
    ),
    'money_missing' => const DiagnosticExplanation(
      what: '未找到唯一、明确的本笔交易金额。',
      result: '暂不生成账单。',
      action: '请打开显示“实付金额”的交易详情页。',
      level: DiagnosticLevel.warning,
    ),
    'read_failed' => const DiagnosticExplanation(
      what: '节点读取异常。',
      result: '停止本轮解析。',
      level: DiagnosticLevel.error,
    ),
    'queued' => DiagnosticExplanation(
      what: '采集已入后台队列${count > 0 ? " ($count 项)" : ""}。',
      result: '即将进行去重与分类规则解析。',
      level: DiagnosticLevel.success,
    ),
    'replay_skipped' => const DiagnosticExplanation(
      what: '同一界面的交易指纹与已处理记录相同。',
      result: '已跳过重复处理，不重复弹窗。',
      action: '若为新交易，请导出日志检查指纹。',
      level: DiagnosticLevel.normal,
    ),
    'queue_dropped' => const DiagnosticExplanation(
      what: '队列溢出或超时。',
      result: '较旧数据已被移除。',
      action: '保证知账后台持续运行。',
      level: DiagnosticLevel.error,
    ),
    'config_saved' => const DiagnosticExplanation(
      what: '自动记账设置已更新并保存。',
      result: '即刻按新设置执行。',
      level: DiagnosticLevel.success,
    ),
    'queue_reset' => const DiagnosticExplanation(
      what: '设置发生变动。',
      result: '清除旧队列数据。',
      level: DiagnosticLevel.normal,
    ),
    'reconnect_requested' => const DiagnosticExplanation(
      what: '请求系统重新绑定通知服务。',
      result: '发送请求中。',
      level: DiagnosticLevel.progress,
    ),
    'retry_requested' => const DiagnosticExplanation(
      what: '用户请求重试待处理队列。',
      result: '后台重新启动处理中。',
      level: DiagnosticLevel.progress,
    ),
    'worker_start' => DiagnosticExplanation(
      what: '后台处理引擎启动${count > 0 ? " (待处理 $count 项)" : ""}。',
      result: '准备处理数据。',
      level: DiagnosticLevel.progress,
    ),
    'worker_ready' => const DiagnosticExplanation(
      what: '后台数据库及目标账本就绪。',
      result: '可安全解析入库。',
      level: DiagnosticLevel.success,
    ),
    'worker_take' => const DiagnosticExplanation(
      what: '后台开始解析当前采集。',
      result: '校验金额、账户与分类规则。',
      level: DiagnosticLevel.progress,
    ),
    'confidence_high' => DiagnosticExplanation(
      what: '交易各字段均达高置信度 (评分 $count%)。',
      result: '自动生成账单。',
      level: DiagnosticLevel.success,
    ),
    'confidence_review' => DiagnosticExplanation(
      what: '部分字段未达自动入账门槛 (评分 $count%)。',
      result: '保留为待确认草稿。',
      action: '核对表单中标黄提示。',
      level: DiagnosticLevel.warning,
    ),
    'confidence_low' => DiagnosticExplanation(
      what: '识别存在争议或字段缺失 (评分 $count%)。',
      result: '仅保留手工核对入口。',
      action: '请手动补充必填字段。',
      level: DiagnosticLevel.warning,
    ),
    'worker_revoked' => const DiagnosticExplanation(
      what: '授权发生变化。',
      result: '已暂停处理。',
      level: DiagnosticLevel.warning,
    ),
    'worker_posted' => const DiagnosticExplanation(
      what: '账单已成功自动保存入账。',
      result: '已记入账本。',
      level: DiagnosticLevel.success,
    ),
    'worker_pending' => const DiagnosticExplanation(
      what: '账单已保存为待确认草稿。',
      result: '存入待确认列表，不影响余额。',
      action: '请在确认表单中补充完整。',
      level: DiagnosticLevel.success,
    ),
    'worker_duplicate_order' => const DiagnosticExplanation(
      what: '查重命中：页面订单号与已有账单相同。',
      result: '已阻断自动入账，草稿留在待确认。',
      action: '确认是同一笔就忽略；若确为两笔，请核对订单号后手动保存。',
      level: DiagnosticLevel.warning,
    ),
    'worker_duplicate_semantic' => const DiagnosticExplanation(
      what: '查重命中：商户、金额、账户、方向和相近时间与已有账单一致。',
      result: '已阻断自动入账，草稿留在待确认。',
      action: '确认是同一笔就忽略；若确为两笔，可在待确认中手动保存。',
      level: DiagnosticLevel.warning,
    ),
    'worker_duplicate_same_day' => const DiagnosticExplanation(
      what: '查重命中：同一天、同商户、同账户、同金额和同方向已有账单。',
      result: '已阻断自动入账，草稿留在待确认。',
      action: '确认是同一笔就忽略；若确为两笔，可在待确认中手动保存。',
      level: DiagnosticLevel.warning,
    ),
    'worker_duplicate_time' => const DiagnosticExplanation(
      what: '商户没有识别完整，但金额、账户、方向和 5 分钟内时间窗与已有账单一致。',
      result: '为避免重复记账，已阻断自动入账并保留草稿。',
      action: '请打开待确认账单，核对商户或订单号后决定保存或忽略。',
      level: DiagnosticLevel.warning,
    ),
    'worker_quality' => DiagnosticExplanation(
      what: '已把解析结果与实际入账字段逐项对照。',
      result: quality == null
          ? '评分字段不完整，暂无法判断。'
          : '识别质量 ${quality!.score} 分 · ${quality!.grade}。${quality!.summary}',
      action: quality == null
          ? '请导出日志继续排查。'
          : quality!.needsReview
          ? '低分表示分类、账户或金额被修正过，建议在待确认账单中复核。'
          : '各字段一致性良好，无需额外处理。',
      level: quality == null
          ? DiagnosticLevel.normal
          : quality!.needsReview
          ? DiagnosticLevel.warning
          : DiagnosticLevel.success,
    ),
    'worker_repeated' => const DiagnosticExplanation(
      what: '发现重复采集。',
      result: '未重复保存。',
      level: DiagnosticLevel.normal,
    ),
    'worker_discarded' => const DiagnosticExplanation(
      what: '目标账本失效或丢失。',
      result: '无法入账。',
      level: DiagnosticLevel.error,
    ),
    'worker_finish' => const DiagnosticExplanation(
      what: '本轮后台处理完毕。',
      result: '请查看对应存草稿或入账通知。',
      level: DiagnosticLevel.success,
    ),
    'worker_start_failed' ||
    'plugin_unavailable' => const DiagnosticExplanation(
      what: '后台处理组件连接失败。',
      result: '仍保留在队列中。',
      action: '尝试重新打开应用并取消电池优化。',
      level: DiagnosticLevel.error,
    ),
    'worker_timeout' => const DiagnosticExplanation(
      what: '后台处理超时。',
      result: '暂停处理。',
      action: '请检查系统后台运行限制。',
      level: DiagnosticLevel.error,
    ),
    'invalid_capture' => const DiagnosticExplanation(
      what: '采集数据格式损坏。',
      result: '已拒绝处理。',
      level: DiagnosticLevel.error,
    ),
    'database_error' || 'processing_error' => const DiagnosticExplanation(
      what: '数据库写入发生异常。',
      result: '未完成入库。',
      action: '导出日志反馈并重试。',
      level: DiagnosticLevel.error,
    ),
    'amount_missing' => const DiagnosticExplanation(
      what: '金额未自动确定。',
      result: '保留为草稿。',
      action: '请手动填写交易金额。',
      level: DiagnosticLevel.warning,
    ),
    'account_missing' => const DiagnosticExplanation(
      what: '扣款账户未锁定。',
      result: '保留为草稿。',
      action: '请在确认表单中选择账户。',
      level: DiagnosticLevel.warning,
    ),
    'category_missing' => const DiagnosticExplanation(
      what: '账单分类未确定。',
      result: '保留为草稿。',
      action: '请在确认表单中选择分类。',
      level: DiagnosticLevel.warning,
    ),
    'peer_review' => const DiagnosticExplanation(
      what: '转账或红包需核对收支方向。',
      result: '不自动入账。',
      action: '请核对“支出”还是“收入”。',
      level: DiagnosticLevel.warning,
    ),
    'warning_review' => const DiagnosticExplanation(
      what: '包含低置信度字段或识别警告。',
      result: '进入手工确认流程。',
      action: '请核对标黄字段。',
      level: DiagnosticLevel.warning,
    ),
    'overlay_denied' || 'overlay_failed' => const DiagnosticExplanation(
      what: '无法弹出记账悬浮窗。',
      result: '草稿已保留在待确认箱。',
      action: '在系统设置中授予悬浮窗权限。',
      level: DiagnosticLevel.warning,
    ),
    'overlay_queued' => DiagnosticExplanation(
      what: '记账确认弹窗已进入队列${count > 0 ? " ($count 笔)" : ""}。',
      result: '准备展开表单。',
      level: DiagnosticLevel.success,
    ),
    'overlay_overflow' => const DiagnosticExplanation(
      what: '悬浮窗弹窗队列已满。',
      result: '草稿存入待确认，不再弹出新窗口。',
      action: '请清理待确认账单。',
      level: DiagnosticLevel.warning,
    ),
    'overlay_expanded' => const DiagnosticExplanation(
      what: '记账确认弹窗已在屏幕展开。',
      result: '等待用户确认。',
      level: DiagnosticLevel.success,
    ),
    'overlay_collapsed' => const DiagnosticExplanation(
      what: '记账表单已收起为悬浮球。',
      result: '草稿保留，点击悬浮球可重新打开。',
      level: DiagnosticLevel.normal,
    ),
    'form_submitted' => const DiagnosticExplanation(
      what: '用户在表单中点击了保存或忽略。',
      result: '提交后台校验。',
      level: DiagnosticLevel.progress,
    ),
    'form_saved' => const DiagnosticExplanation(
      what: '表单操作校验成功并已保存。',
      result: '已成功写入账本。',
      level: DiagnosticLevel.success,
    ),
    'form_rejected' => const DiagnosticExplanation(
      what: '表单必填项缺失或保存失败。',
      result: '未写入账本。',
      action: '请补齐必填项后再次点击保存。',
      level: DiagnosticLevel.error,
    ),
    'form_duplicate' => const DiagnosticExplanation(
      what: '存在高度相似交易。',
      result: '需人工勾选“确认”后方可添加。',
      level: DiagnosticLevel.warning,
    ),
    _ => const DiagnosticExplanation(
      what: '这是自动记账流程中的一个内部阶段。',
      result: '请结合相邻日志判断最终是否生成草稿或账单。',
    ),
  };
  String get origin {
    final name = app == manualOcrPackage
        ? 'OCR截图'
        : paymentApps.where((a) => a.packageName == app).firstOrNull?.name;
    final kind = source == 'notification'
        ? '通知'
        : source == 'accessibility'
        ? '无障碍'
        : source == 'screenshot'
        ? '截图'
        : '后台/系统';
    return name == null ? kind : '$name · $kind';
  }
}

enum PaymentLogOutcome {
  posted,
  pending,
  duplicate,
  repeated,
  skipped,
  processing,
}

/// One transaction-sized view of the technical trace.
///
/// The raw event list is intentionally code-oriented. Users need to know
/// “what happened to this payment”, so events sharing a capture reference are
/// folded into a single record with a plain-language result and next action.
class PaymentLogRecord {
  const PaymentLogRecord({
    required this.reference,
    required this.time,
    required this.outcome,
    required this.events,
    required this.decisive,
    this.amount = '',
    this.merchant = '',
    this.account = '',
    this.category = '',
    this.quality,
  });

  final String reference;
  final int time;
  final PaymentLogOutcome outcome;
  final List<DiagnosticEvent> events;
  final DiagnosticEvent decisive;
  final String amount, merchant, account, category;
  final PaymentQuality? quality;

  bool get needsAttention =>
      outcome == PaymentLogOutcome.pending ||
      outcome == PaymentLogOutcome.duplicate ||
      outcome == PaymentLogOutcome.skipped;

  String get title => switch (outcome) {
    PaymentLogOutcome.posted => '已自动入账',
    PaymentLogOutcome.pending => '待确认账单',
    PaymentLogOutcome.duplicate => '疑似重复，已拦下',
    PaymentLogOutcome.repeated => '重复采集，已跳过',
    PaymentLogOutcome.skipped => '未生成账单',
    PaymentLogOutcome.processing => '处理中',
  };

  String get subtitle => [
    if (amount.isNotEmpty) '¥$amount',
    if (merchant.isNotEmpty) merchant,
    if (account.isNotEmpty) account,
    if (category.isNotEmpty) category,
  ].join(' · ');

  String get reason {
    if (outcome == PaymentLogOutcome.posted) {
      return '已按实付金额入账，余额和报表已更新。';
    }
    if (outcome == PaymentLogOutcome.repeated) {
      return '通知、无障碍或 OCR 重复采集了同一笔支付，没有再次入账。';
    }
    if (outcome == PaymentLogOutcome.duplicate) {
      return decisive.explanation.what;
    }
    if (outcome == PaymentLogOutcome.pending) {
      if (quality?.needsReview == true) {
        return '识别质量 ${quality!.score} 分：${quality!.summary}';
      }
      DiagnosticEvent? warning;
      for (final event in events) {
        if (const {
          'amount_missing',
          'account_missing',
          'category_missing',
          'peer_review',
          'warning_review',
          'overlay_denied',
          'overlay_failed',
        }.contains(event.code)) {
          warning = event;
        }
      }
      return warning?.explanation.what ?? '字段不完整或置信度不足，暂未自动入账。';
    }
    if (outcome == PaymentLogOutcome.skipped) {
      return decisive.explanation.what;
    }
    return '后台已收到采集，尚未返回最终结果。';
  }

  String get action {
    if (decisive.explanation.action.isNotEmpty) {
      return decisive.explanation.action;
    }
    return switch (outcome) {
      PaymentLogOutcome.posted => '无需操作，可在流水中查看或编辑。',
      PaymentLogOutcome.pending => '到“待确认账单”核对并保存。',
      PaymentLogOutcome.duplicate => '确认是同一笔就忽略；确为两笔时可在待确认中手动保存。',
      PaymentLogOutcome.repeated => '无需操作。',
      PaymentLogOutcome.skipped => '打开支付成功页或账单详情页后重试。',
      PaymentLogOutcome.processing => '稍等片刻；长时间无结果可点上方刷新。',
    };
  }

  DiagnosticLevel get level => switch (outcome) {
    PaymentLogOutcome.posted => DiagnosticLevel.success,
    PaymentLogOutcome.duplicate ||
    PaymentLogOutcome.skipped => DiagnosticLevel.warning,
    PaymentLogOutcome.pending => DiagnosticLevel.warning,
    PaymentLogOutcome.repeated => DiagnosticLevel.normal,
    PaymentLogOutcome.processing => DiagnosticLevel.progress,
  };

  String get readableTime => DateTime.fromMillisecondsSinceEpoch(
    time,
  ).toLocal().toIso8601String().replaceFirst('T', ' ');

  String get exportText => [
    '$readableTime · $title',
    if (subtitle.isNotEmpty) '识别：$subtitle',
    '原因：$reason',
    '下一步：$action',
    if (quality != null) '识别质量：${quality!.score} 分 · ${quality!.summary}',
    '技术过程：${events.map((event) => event.code).join(' → ')}',
  ].join('\n');

  static List<PaymentLogRecord> fromEvents(List<DiagnosticEvent> source) {
    final groups = <String, List<DiagnosticEvent>>{};
    for (final event in source) {
      if (event.reference.isEmpty) continue;
      groups.putIfAbsent(event.reference, () => []).add(event);
    }
    final records = <PaymentLogRecord>[];
    for (final entry in groups.entries) {
      final events = [...entry.value]..sort((a, b) => a.time.compareTo(b.time));
      final outcome = _outcome(events);
      if (outcome == null) continue;
      final decisive = events.lastWhere(
        (event) => _codeOutcome(event.code) == outcome,
        orElse: () => events.last,
      );
      String field(String key) {
        for (final event in events.reversed) {
          final value = event.fields[key];
          if (value != null && value.isNotEmpty) return value;
        }
        return '';
      }

      PaymentQuality? quality;
      for (final event in events) {
        if (event.quality != null) quality = event.quality;
      }
      records.add(
        PaymentLogRecord(
          reference: entry.key,
          time: decisive.time,
          outcome: outcome,
          events: events,
          decisive: decisive,
          amount: field('amount'),
          merchant: field('merchant'),
          account: field('account'),
          category: field('category'),
          quality: quality,
        ),
      );
    }
    records.sort((a, b) => b.time.compareTo(a.time));
    return records;
  }

  static PaymentLogOutcome? _outcome(List<DiagnosticEvent> events) {
    final outcomes = events.map((event) => _codeOutcome(event.code)).toSet();
    for (final outcome in const [
      PaymentLogOutcome.posted,
      PaymentLogOutcome.duplicate,
      PaymentLogOutcome.repeated,
      PaymentLogOutcome.pending,
      PaymentLogOutcome.skipped,
      PaymentLogOutcome.processing,
    ]) {
      if (outcomes.contains(outcome)) return outcome;
    }
    return null;
  }

  static PaymentLogOutcome? _codeOutcome(String code) => switch (code) {
    'worker_posted' || 'form_saved' => PaymentLogOutcome.posted,
    'worker_duplicate_order' ||
    'worker_duplicate_semantic' ||
    'worker_duplicate_same_day' ||
    'worker_duplicate_time' ||
    'form_duplicate' => PaymentLogOutcome.duplicate,
    'worker_repeated' || 'replay_skipped' => PaymentLogOutcome.repeated,
    'worker_pending' ||
    'overlay_expanded' ||
    'overlay_collapsed' ||
    'overlay_queued' => PaymentLogOutcome.pending,
    'worker_discarded' ||
    'no_payment_match' ||
    'fields_missing' ||
    'money_missing' ||
    'success_missing' ||
    'state_unsupported' ||
    'ocr_no_match' ||
    'quick_ocr_failed' ||
    'empty_content' ||
    'too_long' => PaymentLogOutcome.skipped,
    'queued' ||
    'worker_take' ||
    'worker_quality' ||
    'confidence_high' ||
    'confidence_review' ||
    'confidence_low' ||
    'form_submitted' => PaymentLogOutcome.processing,
    _ => null,
  };
}

/// Both display and export rebuild an allowlisted report, never stringify the bridge payload.
class AccessibilityDiagnostic {
  const AccessibilityDiagnostic({
    this.rootNodeCount = 0,
    this.usableTextCount = 0,
    this.pageSessionId = '',
    this.windowPackage = '',
  });

  final int rootNodeCount;
  final int usableTextCount;
  final String pageSessionId;
  final String windowPackage;

  factory AccessibilityDiagnostic.fromJson(Map data) {
    int bounded(dynamic value, int max) =>
        value is int ? value.clamp(0, max) : 0;
    String safe(dynamic value, RegExp pattern, int maxLength) {
      if (value is! String || value.length > maxLength) return '';
      return pattern.hasMatch(value) ? value : '';
    }

    return AccessibilityDiagnostic(
      rootNodeCount: bounded(data['rootNodeCount'], 1000000),
      usableTextCount: bounded(data['usableTextCount'], 1000000),
      pageSessionId: safe(
        data['pageSessionId'],
        RegExp(r'^[0-9A-Za-z_.:|\-]+$'),
        160,
      ),
      windowPackage: safe(
        data['windowPackage'],
        RegExp(r'^[0-9A-Za-z_.]+$'),
        180,
      ),
    );
  }
}

class OcrDiagnostic {
  const OcrDiagnostic({
    this.screenshotSucceeded = false,
    this.recognizedLineCount = 0,
    this.amountCandidateFound = false,
    this.successMarkerFound = false,
    this.rejectionReason = '',
  });

  final bool screenshotSucceeded;
  final int recognizedLineCount;
  final bool amountCandidateFound;
  final bool successMarkerFound;
  final String rejectionReason;

  factory OcrDiagnostic.fromJson(Map data) {
    int bounded(dynamic value, int max) =>
        value is int ? value.clamp(0, max) : 0;
    return OcrDiagnostic(
      screenshotSucceeded: data['screenshotSucceeded'] == true,
      recognizedLineCount: bounded(data['recognizedLineCount'], 1000000),
      amountCandidateFound: data['amountCandidateFound'] == true,
      successMarkerFound: data['successMarkerFound'] == true,
      rejectionReason:
          data['rejectionReason'] is String &&
              diagnosticLabels.containsKey(data['rejectionReason'])
          ? data['rejectionReason'] as String
          : '',
    );
  }
}

class NotificationDiagnostic {
  const NotificationDiagnostic({
    this.listenerConnected = false,
    this.lastConnectedAt = 0,
  });

  final bool listenerConnected;
  final int lastConnectedAt;

  factory NotificationDiagnostic.fromJson(Map data) {
    final rawTime = data['lastConnectedAt'];
    return NotificationDiagnostic(
      listenerConnected: data['listenerConnected'] == true,
      lastConnectedAt: rawTime is int ? rawTime.clamp(0, 4102444800000) : 0,
    );
  }
}

class AutomationDiagnostics {
  const AutomationDiagnostics({
    required this.enabled,
    required this.version,
    required this.api,
    required this.state,
    required this.events,
    required this.queued,
    required this.errorCode,
    this.accessibility = const AccessibilityDiagnostic(),
    this.ocr = const OcrDiagnostic(),
    this.notification = const NotificationDiagnostic(),
  });
  final bool enabled;
  final String version, errorCode;
  final int api, queued;
  final Map<String, bool> state;
  final List<DiagnosticEvent> events;
  final AccessibilityDiagnostic accessibility;
  final OcrDiagnostic ocr;
  final NotificationDiagnostic notification;
  factory AutomationDiagnostics.fromJson(Map data) {
    final raw = data['state'] is Map ? data['state'] as Map : const {};
    final revealSensitive = raw['sensitiveLogging'] == true;
    final accessibilityMap = raw['accessibility'] is Map
        ? raw['accessibility'] as Map
        : const {};
    final ocrMap = raw['ocr'] is Map ? raw['ocr'] as Map : const {};
    final notificationMap = raw['notification'] is Map
        ? raw['notification'] as Map
        : const {};
    int bounded(dynamic value, int max, [int min = 0]) =>
        value is int ? value.clamp(min, max) : min;
    final events = <DiagnosticEvent>[];
    for (final row
        in (data['events'] is List ? data['events'] as List : const []).take(
          50000,
        )) {
      if (row is! Map ||
          !diagnosticLabels.containsKey(row['code']) ||
          row['time'] is! int ||
          row['time'] <= 0 ||
          row['time'] > 4102444800000) {
        continue;
      }
      events.add(
        DiagnosticEvent(
          row['time'],
          row['code'],
          paymentApps.any((a) => a.packageName == row['app']) ||
                  row['app'] == manualOcrPackage
              ? row['app']
              : '',
          [
                'notification',
                'accessibility',
                'screenshot',
              ].contains(row['source'])
              ? row['source']
              : '',
          row['ref'] is String && RegExp(r'^[a-f0-9]{12}$').hasMatch(row['ref'])
              ? row['ref']
              : '',
          bounded(row['count'], 1000000),
          bounded(row['repeats'], 999999, 1),
          fields: _diagnosticFields(row['fields'], reveal: revealSensitive),
        ),
      );
    }
    return AutomationDiagnostics(
      enabled: data['enabled'] != false,
      version:
          data['appVersion'] is String &&
              RegExp(r'^\d+\.\d+\.\d+$').hasMatch(data['appVersion'])
          ? data['appVersion']
          : '未知',
      api: bounded(data['androidApi'], 100),
      state: {
        for (final key in diagnosticStateLabels.keys) key: raw[key] == true,
      },
      events: events.reversed.toList(),
      queued: bounded(raw['queued'], 100),
      errorCode: diagnosticLabels.containsKey(raw['errorCode'])
          ? raw['errorCode']
          : '',
      accessibility: AccessibilityDiagnostic.fromJson(accessibilityMap),
      ocr: OcrDiagnostic.fromJson(ocrMap),
      notification: NotificationDiagnostic.fromJson(notificationMap),
    );
  }
  String text() {
    int total(DiagnosticLevel level) => events
        .where((event) => event.explanation.level == level)
        .fold(0, (sum, event) => sum + event.repeats);
    final out = StringBuffer(
      '知账诊断日志\n版本 $version · Android API $api\n日志记录：${enabled ? "开启" : "关闭"}\n',
    );
    for (final entry in diagnosticStateLabels.entries) {
      out.writeln('${entry.value}：${state[entry.key] == true ? "是" : "否"}');
    }
    out.writeln('待处理采集：$queued');
    if (errorCode.isNotEmpty) {
      out.writeln('后台错误：${diagnosticLabels[errorCode]}');
    }
    out.writeln(
      '诊断摘要：错误 ${total(DiagnosticLevel.error)} · '
      '警告 ${total(DiagnosticLevel.warning)} · '
      '成功 ${total(DiagnosticLevel.success)} · '
      '处理中 ${total(DiagnosticLevel.progress)}',
    );
    out.writeln('\n--- 无障碍采集诊断 ---');
    out.writeln('扫描节点数：${accessibility.rootNodeCount}');
    out.writeln('可用文本段数：${accessibility.usableTextCount}');
    out.writeln(
      '会话标识：${accessibility.pageSessionId.isEmpty ? "无" : accessibility.pageSessionId}',
    );
    out.writeln(
      '前台窗口应用：${accessibility.windowPackage.isEmpty ? "无" : accessibility.windowPackage}',
    );

    out.writeln('\n--- 本地截图 OCR 诊断 ---');
    out.writeln('截图状态：${ocr.screenshotSucceeded ? "成功" : "未成功 / 未触发"}');
    out.writeln('识别文本行数：${ocr.recognizedLineCount}');
    out.writeln('找到金额候选：${ocr.amountCandidateFound ? "是" : "否"}');
    out.writeln('找到交易成功状态：${ocr.successMarkerFound ? "是" : "否"}');
    out.writeln(
      '拒绝原因：${ocr.rejectionReason.isEmpty ? "无" : (diagnosticLabels[ocr.rejectionReason] ?? ocr.rejectionReason)}',
    );

    out.writeln('\n--- 通知监听诊断 ---');
    out.writeln('服务连接状态：${notification.listenerConnected ? "已连接" : "未连接"}');
    out.writeln(
      '最后连接时间：${notification.lastConnectedAt > 0 ? DateTime.fromMillisecondsSinceEpoch(notification.lastConnectedAt).toLocal().toIso8601String().replaceFirst("T", " ") : "无记录"}',
    );

    out.writeln(
      '\n以下为最近48小时最多400条有效诊断，最新在前；内部轮询过程已过滤。${state['sensitiveLogging'] == true ? '已开启敏感识别信息，分享前请检查金额、商户及账户。' : '识别摘要已脱敏，金额未记录。'}',
    );
    for (final event in events.where((event) => !event.isInternalNoise)) {
      out.write(event.detailedText());
    }
    return out.toString();
  }
}

Map<String, String> _diagnosticFields(dynamic value, {bool reveal = false}) {
  if (value is! Map) return const {};
  final result = <String, String>{};
  final amount = value['amount'];
  if (reveal &&
      amount is String &&
      RegExp(r'^\d{1,12}\.\d{2}$').hasMatch(amount)) {
    result['amount'] = amount;
  }
  for (final key in const ['merchant', 'account', 'category']) {
    final raw = value[key];
    if (raw is! String || raw.isEmpty || raw.length > 100) continue;
    if (reveal) {
      result[key] = raw;
      continue;
    }
    final chars = raw.runes.map(String.fromCharCode).toList();
    final tail = key == 'account'
        ? (RegExp(r'\d{4}(?=\D*$)').firstMatch(raw)?[0] ?? chars.last)
        : chars.last;
    result[key] = chars.length == 1
        ? '*'
        : '${chars.first}${List.filled((chars.length - tail.length - 1).clamp(1, 100), '*').join()}$tail';
  }
  return result;
}
