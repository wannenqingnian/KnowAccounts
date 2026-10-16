import 'money_privacy.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../app_state.dart';
import '../data/family_payment_repository.dart';
import '../domain/family_payment.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import '../finance/analysis.dart';
import '../finance/advanced_analysis.dart';
import '../finance/family_payment_analysis.dart';
import 'widgets.dart';
import 'year_month_picker.dart';

enum AnalysisRange { month, year, all, custom }

class _FamilyAnalysisSource {
  const _FamilyAnalysisSource(this.events, this.cards);
  final List<FamilyPaymentEvent> events;
  final List<FamilyCardAccountSummary> cards;
}

class AnalysisPage extends StatefulWidget {
  const AnalysisPage({super.key, required this.state});
  final LedgerController state;
  @override
  State<AnalysisPage> createState() => _AnalysisPageState();
}

class _AnalysisPageState extends State<AnalysisPage> {
  AnalysisRange _range = AnalysisRange.month;
  bool _income = false, _roots = false, _hideUntagged = false;
  int _chartMetric = 0, _heatMetric = 0;
  String _assetAccount = '';
  int? _heatYear;
  DateTimeRange? _custom;
  String? _familyLedgerId;
  Future<_FamilyAnalysisSource>? _familySource;
  static const colors = [
    teal,
    orange,
    Color(0xFF5A83A6),
    Color(0xFF9980AF),
    Color(0xFFBA9852),
    Color(0xFF758C63),
  ];

  Future<void> _chooseRange(AnalysisRange range) async {
    if (range == AnalysisRange.custom) {
      final selected = await showDateRangePicker(
        context: context,
        firstDate: DateTime(1900),
        lastDate: DateTime(2100, 12, 31),
        initialDateRange: _custom,
      );
      if (selected == null || !mounted) return;
      setState(() {
        _custom = selected;
        _range = range;
        _heatYear = selected.start.year;
      });
    } else {
      setState(() {
        _range = range;
        _heatYear = null;
      });
    }
  }

  Widget _metricPicker(int value, ValueChanged<int> changed) =>
      DropdownButton<int>(
        value: value,
        underline: const SizedBox(),
        items: const [
          DropdownMenuItem(value: 0, child: Text('支出')),
          DropdownMenuItem(value: 1, child: Text('收入')),
          DropdownMenuItem(value: 2, child: Text('结余')),
        ],
        onChanged: (v) => changed(v!),
      );
  int _value(PeriodAnalysis p, int metric) => metric == 0
      ? p.expense
      : metric == 1
      ? p.income
      : p.surplus;
  List<MapEntry<String, int>> _sort(Map<String, int> map) =>
      map.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

  Future<_FamilyAnalysisSource> _familyData(
    LedgerController state, {
    bool force = false,
  }) {
    if (force || _familySource == null || _familyLedgerId != state.ledgerId) {
      _familyLedgerId = state.ledgerId;
      _familySource = () async {
        final repository = FamilyPaymentRepository(state.repository.db);
        final events = await repository.events(state.ledgerId);
        final cards = await repository.cards(
          state.ledgerId,
          includeArchived: true,
        );
        return _FamilyAnalysisSource(events, cards);
      }();
    }
    return _familySource!;
  }

  Widget _familyAnalysisSection(
    LedgerController state,
    DateTime start,
    DateTime end,
  ) => FutureBuilder<_FamilyAnalysisSource>(
    future: _familyData(state),
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return _section('亲情卡分析', const [LinearProgressIndicator()]);
      }
      if (snapshot.hasError) {
        return _section(
          '亲情卡分析',
          [const Text('亲情卡统计读取失败，请重试。')],
          control: IconButton(
            tooltip: '重新加载亲情卡统计',
            onPressed: () => setState(() => _familyData(state, force: true)),
            icon: const Icon(Icons.refresh),
          ),
        );
      }
      final source = snapshot.requireData;
      var effectiveStart = start;
      var effectiveEnd = end;
      if (_range == AnalysisRange.all && source.events.isNotEmpty) {
        final dates =
            source.events
                .map((event) => event.occurredAt ?? event.createdAt)
                .toList()
              ..sort();
        effectiveStart = dates.first;
        final last = dates.last;
        effectiveEnd = DateTime(last.year, last.month, last.day + 1);
      }
      final report = FamilyPaymentAnalysis(
        source.events,
        source.cards,
        effectiveStart,
        effectiveEnd,
      );
      return _section(
        '亲情卡分析',
        [
          const Text(
            '资金方统计真实代付；消费方统计他人代付给你的消费。两种口径独立展示，消费方金额不会加入账户余额或普通支出。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          if (report.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(child: Text('当前范围暂无亲情卡记录')),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final payer = _familyRoleReport(
                  key: const ValueKey('family_payer_report'),
                  title: '资金方实际代付',
                  description: '计入真实支出与实际扣款账户',
                  netMinor: report.payerNetMinor,
                  grossMinor: report.payerGrossMinor,
                  refundMinor: report.payerRefundMinor,
                  count: report.payerCount,
                  byPlatform: report.payerByPlatform,
                  byCard: report.payerByCard,
                  color: orange,
                );
                final beneficiary = _familyRoleReport(
                  key: const ValueKey('family_beneficiary_report'),
                  title: '消费方受资助消费',
                  description: '只统计消费价值，不扣减本人账户',
                  netMinor: report.beneficiaryNetMinor,
                  grossMinor: report.beneficiaryGrossMinor,
                  refundMinor: report.beneficiaryRefundMinor,
                  count: report.beneficiaryCount,
                  byPlatform: report.beneficiaryByPlatform,
                  byCard: report.beneficiaryByCard,
                  color: teal,
                );
                if (constraints.maxWidth >= 680) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: payer),
                      const SizedBox(width: 12),
                      Expanded(child: beneficiary),
                    ],
                  );
                }
                return Column(
                  children: [payer, const SizedBox(height: 12), beneficiary],
                );
              },
            ),
          if (report.pendingCount > 0) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.tertiaryContainer.withValues(alpha: .55),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '另有 ${report.pendingCount} 笔待审核，合计 ${visibleMoney(context, report.pendingMinor)}；确认角色后才进入对应报表。',
              ),
            ),
          ],
        ],
        control: IconButton(
          tooltip: '刷新亲情卡统计',
          onPressed: () => setState(() => _familyData(state, force: true)),
          icon: const Icon(Icons.refresh, size: 20),
        ),
      );
    },
  );

  Widget _familyRoleReport({
    required Key key,
    required String title,
    required String description,
    required int netMinor,
    required int grossMinor,
    required int refundMinor,
    required int count,
    required Map<String, int> byPlatform,
    required Map<String, int> byCard,
    required Color color,
  }) {
    final platforms = _sort(byPlatform);
    final cards = _sort(byCard);
    return Container(
      key: key,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(
            description,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Text(
            visibleMoney(context, netMinor),
            style: TextStyle(
              color: color,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(
            '$count 笔 · 原消费 ${visibleMoney(context, grossMinor)} · 已退款 ${visibleMoney(context, refundMinor)}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          if (platforms.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final item in platforms)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      '${item.key} ${visibleMoney(context, item.value)}',
                    ),
                  ),
              ],
            ),
          ],
          if (cards.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final item in cards.take(5))
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(visibleMoney(context, item.value)),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children, {Widget? control}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  ?control,
                ],
              ),
              const SizedBox(height: 14),
              ...children,
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    if (MoneyPrivacy.of(context)) {
      return const SectionCard(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 36),
          child: Center(child: Text('金额隐私模式已开启，分析金额和图表已隐藏。')),
        ),
      );
    }
    final date = state.month;
    var start = DateTime(
      date.year,
      _range == AnalysisRange.year ? 1 : date.month,
    );
    var end = _range == AnalysisRange.year
        ? DateTime(date.year + 1)
        : DateTime(date.year, date.month + 1);
    if (_range == AnalysisRange.custom && _custom != null) {
      start = _custom!.start;
      end = DateTime(
        _custom!.end.year,
        _custom!.end.month,
        _custom!.end.day + 1,
      );
    }
    if (_range == AnalysisRange.all) {
      final dates =
          state.entries
              .where((e) => !e.deleted)
              .map((e) => e.occurredDate)
              .toList()
            ..sort();
      start = dates.isEmpty ? DateTime(date.year) : dates.first;
      final last = dates.isEmpty ? date : dates.last;
      end = DateTime(last.year, last.month, last.day + 1);
    }
    final previousStart = _range == AnalysisRange.year
        ? DateTime(date.year - 1)
        : _range == AnalysisRange.month
        ? DateTime(date.year, date.month - 1)
        : DateTime(
            start.year,
            start.month,
            start.day - end.difference(start).inDays,
          );
    final report = PeriodAnalysis(state.entries, start, end);
    final previous = PeriodAnalysis(state.entries, previousStart, start);
    final categoryGroups = categoryTotals(
      state.entries,
      state.allCategories,
      start,
      end,
      income: _income,
      roots: _roots,
    );
    final tags = tagTotals(state.entries, start, end, income: _income);
    if (_hideUntagged) tags.remove('未标记');
    final flows = dailyFlows(state.entries, start, end);
    final trendStart = _range == AnalysisRange.month
        ? DateTime(date.year, date.month - 5)
        : DateTime(start.year, start.month);
    final lastMonth = _range == AnalysisRange.month
        ? date
        : DateTime(end.year, end.month, end.day - 1);
    final fullCount =
        (lastMonth.year - trendStart.year) * 12 +
        lastMonth.month -
        trendStart.month +
        1;
    final count = math.min(120, fullCount);
    final offset = math.max(0, fullCount - count);
    final trends = List.generate(count, (i) {
      final month = DateTime(trendStart.year, trendStart.month + i + offset);
      // Recent-month chart intentionally includes previous months. Custom/all
      // boundary months use only the chosen dates.
      final bucketStart =
          _range == AnalysisRange.month || !month.isBefore(start)
          ? month
          : start;
      final monthEnd = DateTime(month.year, month.month + 1);
      final bucketEnd = _range == AnalysisRange.month || !monthEnd.isAfter(end)
          ? monthEnd
          : end;
      return PeriodAnalysis(state.entries, bucketStart, bucketEnd);
    });
    final validAssetAccount =
        state.allAccounts.any((a) => a.id == _assetAccount)
        ? _assetAccount
        : '';
    final assets = [
      for (final p in trends)
        balanceAt(
          state.entries,
          state.allAccounts,
          p.end,
          accountId: validAssetAccount.isEmpty ? null : validAssetAccount,
        ),
    ];
    final annual = PeriodAnalysis(
      state.entries,
      DateTime(date.year),
      DateTime(date.year + 1),
    );
    final annualFlows = dailyFlows(
      state.entries,
      DateTime(date.year),
      DateTime(date.year + 1),
    );
    final annualMonths = List.generate(
      12,
      (i) => PeriodAnalysis(
        state.entries,
        DateTime(date.year, i + 1),
        DateTime(date.year, i + 2),
      ),
    );
    final peakMonth = annualMonths.reduce(
      (a, b) => a.expense >= b.expense ? a : b,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final range in AnalysisRange.values)
              ChoiceChip(
                label: Text(const ['按月', '按年', '全部', '自定义'][range.index]),
                selected: _range == range,
                onSelected: (_) => _chooseRange(range),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_range == AnalysisRange.month || _range == AnalysisRange.year)
          Row(
            children: [
              IconButton(
                tooltip: '上一期',
                onPressed: state.loading
                    ? null
                    : () => state.changeMonth(
                        _range == AnalysisRange.year ? -12 : -1,
                      ),
                icon: const Icon(Icons.chevron_left),
              ),
              Flexible(
                child: InkWell(
                  key: const ValueKey('analysis_period_picker'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: state.loading
                      ? null
                      : () async {
                          final selected = await showYearMonthPicker(
                            context,
                            initial: date,
                            yearOnly: _range == AnalysisRange.year,
                          );
                          if (selected != null) {
                            await state.selectMonth(selected);
                          }
                        },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            _range == AnalysisRange.year
                                ? '${date.year} 年'
                                : '${date.year} 年 ${date.month} 月',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.expand_more, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: '下一期',
                onPressed: state.loading
                    ? null
                    : () => state.changeMonth(
                        _range == AnalysisRange.year ? 12 : 1,
                      ),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          )
        else
          Text(
            '${dateKey(start)} ～ ${dateKey(DateTime(end.year, end.month, end.day - 1))}',
          ),
        const SizedBox(height: 16),
        SectionCard(
          key: const ValueKey('analysis_summary'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final metrics = [
                ('收入', report.income, previous.income, teal),
                ('消费净额', report.netExpense, previous.netExpense, orange),
                ('结余', report.surplus, previous.surplus, ink),
              ];
              final largeText = MediaQuery.textScalerOf(context).scale(12) > 18;
              if (largeText) {
                return Column(
                  children: [
                    for (final m in metrics)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Text(m.$1, style: const TextStyle(fontSize: 12)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: FittedBox(
                                  child: Text(
                                    visibleMoney(context, m.$2),
                                    style: TextStyle(
                                      color: m.$4,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < metrics.length; i++) ...[
                    if (i > 0) const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            metrics[i].$1,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 8),
                          FittedBox(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              visibleMoney(context, metrics[i].$2),
                              style: TextStyle(
                                color: metrics[i].$4,
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _range == AnalysisRange.all
                                ? '全部已入账'
                                : PeriodAnalysis.comparison(
                                    metrics[i].$2,
                                    metrics[i].$3,
                                  ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            '支出 ${visibleMoney(context, report.expense)} · 退款 ${visibleMoney(context, report.refund)} · 报销到账 ${visibleMoney(context, report.reimbursement)} · ${report.count} 笔',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          children: const [
            Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                '消费净额 = 支出 − 到账退款 − 报销到账；结余 = 收入 − 消费净额。转账、还款本金、排除统计的交易与待确认草稿不计入。',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _section(
          '收支统计',
          [
            const Text('月度收支趋势', style: TextStyle(color: Colors.grey)),
            const Text(
              '支出按退款/报销前金额；点击月份看明细，左右滑动查看更多。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (fullCount > 120) const Text('趋势及月度表仅展示最近120个月，摘要统计包含全部选定数据。'),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, c) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(c.maxWidth, trends.length * 48.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final p in trends)
                        Expanded(
                          child: _bar(
                            p,
                            trends.fold<int>(
                              0,
                              (v, p) =>
                                  math.max(v, _value(p, _chartMetric).abs()),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          control: _metricPicker(
            _chartMetric,
            (v) => setState(() => _chartMetric = v),
          ),
        ),
        _familyAnalysisSection(state, start, end),
        _section(
          '收支热力',
          [
            if (_range != AnalysisRange.month)
              DropdownButton<int>(
                value: (_heatYear ?? date.year).clamp(
                  start.year,
                  lastMonth.year,
                ),
                items: [
                  for (
                    var y = start.year;
                    y <= math.min(2100, lastMonth.year);
                    y++
                  )
                    DropdownMenuItem(value: y, child: Text('$y 年')),
                ],
                onChanged: (v) => setState(() => _heatYear = v),
              ),
            const Text(
              '颜色越深金额越高；红色表示负结余。点击日期查看当天流水。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, c) {
                final year = (_heatYear ?? date.year).clamp(
                  start.year,
                  end.year,
                );
                final months = _range == AnalysisRange.month
                    ? [DateTime(date.year, date.month)]
                    : [for (var m = 1; m <= 12; m++) DateTime(year, m)];
                final max = flows.values.fold<int>(
                  0,
                  (v, f) => math.max(v, f.value(_heatMetric).abs()),
                );
                final columns = c.maxWidth < 600 ? 2 : 4;
                return Wrap(
                  spacing: 12,
                  runSpacing: 16,
                  children: [
                    for (final month in months)
                      SizedBox(
                        width: _range == AnalysisRange.month
                            ? math.min(320, c.maxWidth)
                            : (c.maxWidth - 12 * (columns - 1)) / columns,
                        child: _calendar(month, flows, max, start, end),
                      ),
                  ],
                );
              },
            ),
          ],
          control: _metricPicker(
            _heatMetric,
            (v) => setState(() => _heatMetric = v),
          ),
        ),
        _section(
          '资产走势',
          [
            const Text(
              '按当前期初余额和真实分录回溯，不含未录入资产；调整期初余额会影响历史走势。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (assets.isEmpty)
              const Text('暂无数据')
            else ...[
              Text(
                '期末余额 ${visibleMoney(context, assets.last)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  onTapUp: (details) {
                    final width = constraints.maxWidth;
                    final i = (details.localPosition.dx / width * assets.length)
                        .floor()
                        .clamp(0, assets.length - 1);
                    _info(
                      '${trends[i].start.year}年${trends[i].start.month}月期末',
                      visibleMoney(context, assets[i]),
                    );
                  },
                  child: SizedBox(
                    height: 170,
                    width: double.infinity,
                    child: CustomPaint(painter: _AssetLine(assets)),
                  ),
                ),
              ),
              Text(
                '${trends.first.start.year}/${trends.first.start.month} → ${trends.last.start.year}/${trends.last.start.month} · 点击曲线查看余额',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ],
          control: DropdownButton<String>(
            value: validAssetAccount,
            items: [
              const DropdownMenuItem(value: '', child: Text('全部账户净余额')),
              for (final a in state.allAccounts)
                DropdownMenuItem(
                  value: a.id,
                  child: SizedBox(
                    width: 130,
                    child: Text(a.displayName, overflow: TextOverflow.ellipsis),
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _assetAccount = v!),
          ),
        ),
        _section(
          '分类占比',
          [
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('一级分类'),
                  selected: _roots,
                  onSelected: (_) => setState(() => _roots = true),
                ),
                ChoiceChip(
                  label: const Text('二级分类'),
                  selected: !_roots,
                  onSelected: (_) => setState(() => _roots = false),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _ring(categoryGroups, _income ? '总收入' : '退款/报销前支出'),
          ],
          control: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('支出')),
              ButtonSegment(value: true, label: Text('收入')),
            ],
            selected: {_income},
            onSelectionChanged: (v) => setState(() => _income = v.single),
          ),
        ),
        _section(_income ? '收入排行' : '支出排行', [
          _ranking(categoryGroups, (name) {
            final byId = {for (final c in state.allCategories) c.id: c};
            _transactions(
              name,
              state.entries.where((e) {
                if (!inReport(e, start, end) ||
                    e.type !=
                        (_income
                            ? TransactionType.income
                            : TransactionType.expense)) {
                  return false;
                }
                final c = byId[e.categoryId];
                return (_roots && c?.parentId != null
                        ? byId[c!.parentId]?.name
                        : c?.name ?? e.categoryName ?? '未分类') ==
                    name;
              }).toList(),
            );
          }),
        ]),
        _section('月度汇总', [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 18,
              columns: const [
                DataColumn(label: Text('月份')),
                DataColumn(label: Text('收入'), numeric: true),
                DataColumn(label: Text('支出'), numeric: true),
                DataColumn(label: Text('退款/报销'), numeric: true),
                DataColumn(label: Text('结余'), numeric: true),
              ],
              rows: [
                for (final p in trends)
                  DataRow(
                    onSelectChanged: (_) => _periodDetails(p),
                    cells: [
                      DataCell(Text('${p.start.year}/${p.start.month}')),
                      DataCell(
                        Text(visibleMoney(context, p.income, symbol: false)),
                      ),
                      DataCell(
                        Text(visibleMoney(context, p.expense, symbol: false)),
                      ),
                      DataCell(
                        Text(
                          visibleMoney(
                            context,
                            p.refund + p.reimbursement,
                            symbol: false,
                          ),
                        ),
                      ),
                      DataCell(
                        Text(visibleMoney(context, p.surplus, symbol: false)),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ]),
        _section('标签占比', [
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('隐藏未标记'),
            value: _hideUntagged,
            onChanged: (v) => setState(() => _hideUntagged = v!),
          ),
          const Text(
            '多标签交易按标签平均分摊金额，避免重复计算；统计类型沿用分类区域的收入/支出选择。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          _ring(tags, '标签分摊金额'),
        ]),
        _section('标签排行', [
          _ranking(
            tags,
            (tag) => _transactions(
              '#$tag',
              state.entries
                  .where(
                    (e) =>
                        inReport(e, start, end) &&
                        e.type ==
                            (_income
                                ? TransactionType.income
                                : TransactionType.expense) &&
                        (tag == '未标记' ? e.tags.isEmpty : e.tags.contains(tag)),
                  )
                  .toList(),
            ),
          ),
        ]),
        _section('年度总结 · ${date.year}', [
          Text(
            '收入 ${visibleMoney(context, annual.income)}\n消费净额 ${visibleMoney(context, annual.netExpense)}\n结余 ${visibleMoney(context, annual.surplus)}\n到账退款 ${visibleMoney(context, annual.refund)}\n报销到账 ${visibleMoney(context, annual.reimbursement)}',
            style: const TextStyle(height: 1.7),
          ),
          const SizedBox(height: 8),
          Text(
            '已入账 ${annual.count} 笔 · 记账 ${annualFlows.length} 天\n全年日均消费净额 ${visibleMoney(context, (annual.netExpense / DateTime(date.year + 1).difference(DateTime(date.year)).inDays).round())}\n储蓄率 ${annual.income == 0 ? "收入为零，无法计算" : "${(annual.surplus / annual.income * 100).toStringAsFixed(1)}%"}\n${annual.expense == 0 ? "全年暂无支出" : "支出最高月份 ${peakMonth.start.month}月 · ${visibleMoney(context, peakMonth.expense)}"}',
          ),
          const Text(
            '年度总结独立统计所选年份；全部/自定义筛选下也可通过月份选择对应年份。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ]),
      ],
    );
  }

  Widget _bar(PeriodAnalysis p, int max) {
    final value = _value(p, _chartMetric);
    final h = max == 0 ? 0.0 : 62 * value.abs() / max;
    return InkWell(
      onTap: () => _periodDetails(p),
      child: Semantics(
        label: '${p.start.month}月${visibleMoney(context, value)}',
        child: Column(
          children: [
            SizedBox(
              height: 130,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: 65,
                    child: Divider(height: 1),
                  ),
                  Positioned(
                    top: value >= 0 ? 65 - h : 65,
                    child: Container(
                      width: 16,
                      height: h,
                      decoration: BoxDecoration(
                        color: value < 0
                            ? Colors.redAccent
                            : _chartMetric == 0
                            ? orange
                            : teal,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Text('${p.start.month}月', style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _calendar(
    DateTime month,
    Map<String, DailyFlow> flows,
    int max,
    DateTime start,
    DateTime end,
  ) {
    final days = DateTime(month.year, month.month + 1, 0).day;
    final offset = month.weekday - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${month.month}月'),
        const SizedBox(height: 6),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: offset + days,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            crossAxisSpacing: 2,
            mainAxisSpacing: 2,
          ),
          itemBuilder: (context, index) {
            if (index < offset) return const SizedBox();
            final day = DateTime(month.year, month.month, index - offset + 1);
            final value = flows[dateKey(day)]?.value(_heatMetric) ?? 0;
            final inRange = !day.isBefore(start) && day.isBefore(end);
            return Tooltip(
              message: '${dateKey(day)} ${visibleMoney(context, value)}',
              child: InkWell(
                onTap: !inRange
                    ? null
                    : () => _transactions(
                        dateKey(day),
                        widget.state.entries
                            .where(
                              (e) =>
                                  inReport(
                                    e,
                                    day,
                                    DateTime(day.year, day.month, day.day + 1),
                                  ) &&
                                  [
                                    TransactionType.income,
                                    TransactionType.expense,
                                    TransactionType.refund,
                                  ].contains(e.type),
                            )
                            .toList(),
                      ),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: !inRange || value == 0
                        ? const Color(0xFFEEF1EC)
                        : (value < 0 ? Colors.red : teal).withValues(
                            alpha: .15 + .75 * value.abs() / math.max(1, max),
                          ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '${day.day}',
                    style: TextStyle(
                      fontSize: 10,
                      color: inRange ? ink : Colors.grey,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _ring(Map<String, int> groups, String label) {
    final values = _sort(groups);
    final total = values.fold<int>(0, (sum, e) => sum + e.value);
    if (total == 0) {
      return const EmptyView(title: '本期暂无数据', description: '保存交易及标签后会自动统计。');
    }
    return Center(
      child: SizedBox(
        width: 180,
        height: 180,
        child: CustomPaint(
          painter: _Ring(values.map((e) => e.value).toList(), colors),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: const TextStyle(fontSize: 12)),
                Text(
                  visibleMoney(context, total),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _ranking(Map<String, int> groups, ValueChanged<String> tap) {
    final sorted = _sort(groups);
    final total = sorted.fold<int>(0, (sum, e) => sum + e.value);
    if (total == 0) return const Text('本期暂无数据');
    return Column(
      children: [
        for (var i = 0; i < sorted.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              radius: 14,
              backgroundColor: colors[i % colors.length].withValues(alpha: .15),
              child: Text('${i + 1}', style: const TextStyle(fontSize: 12)),
            ),
            title: Text(sorted[i].key),
            subtitle: Text(
              '${(sorted[i].value / total * 100).toStringAsFixed(1)}%',
            ),
            trailing: Text(
              visibleMoney(context, sorted[i].value),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            onTap: () => tap(sorted[i].key),
          ),
      ],
    );
  }

  Future<void> _info(String title, String text) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
  Future<void> _periodDetails(PeriodAnalysis p) => _info(
    '${p.start.year} 年 ${p.start.month} 月',
    '收入：${visibleMoney(context, p.income)}\n支出：${visibleMoney(context, p.expense)}\n退款：${visibleMoney(context, p.refund)}\n报销到账：${visibleMoney(context, p.reimbursement)}\n消费净额：${visibleMoney(context, p.netExpense)}\n结余：${visibleMoney(context, p.surplus)}',
  );
  Future<void> _transactions(
    String title,
    List<LedgerEntry> entries,
  ) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .75,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            if (entries.isEmpty) const Text('当天没有已入账收支'),
            for (final e in entries)
              EntryTile(
                entry: e,
                onTap: () => _info(
                  e.merchant.isEmpty ? e.categoryName ?? '账目' : e.merchant,
                  '${visibleMoney(context, e.amountMinor)}\n${dateKey(e.occurredDate)}\n${e.accountName}\n${e.tags.map((t) => "#$t").join(" ")}\n${e.note}',
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _AssetLine extends CustomPainter {
  _AssetLine(this.values);
  final List<int> values;
  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final min = values.reduce(math.min), max = values.reduce(math.max);
    final range = math.max(1, max - min);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = values.length == 1
          ? size.width / 2
          : i / (values.length - 1) * size.width;
      final y = 10 + (max - values[i]) / range * (size.height - 20);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      canvas.drawCircle(Offset(x, y), 3, Paint()..color = teal);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = teal
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _AssetLine oldDelegate) => true;
}

class _Ring extends CustomPainter {
  _Ring(this.values, this.colors);
  final List<int> values;
  final List<Color> colors;
  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<int>(0, (a, b) => a + b);
    if (total <= 0) return;
    var start = -math.pi / 2;
    final rect = Offset.zero & size;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * math.pi * 2;
      canvas.drawArc(
        rect.deflate(9),
        start,
        sweep,
        false,
        Paint()
          ..color = colors[i % colors.length]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 16,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _Ring old) => true;
}
