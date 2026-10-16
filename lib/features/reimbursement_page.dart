import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_state.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import 'money_privacy.dart';
import 'widgets.dart';
import 'transaction_editor.dart';
import 'action_form.dart';

class ReimbursementPage extends ConsumerWidget {
  const ReimbursementPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ledgerProvider);
    final originals = state.entries
        .where((e) => e.type == TransactionType.expense && e.reimbursable)
        .toList();
    final remaining = originals.fold<int>(
      0,
      (sum, e) => sum + e.reimbursementRemaining,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('报销管理')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('待报销总额'),
                Text(
                  visibleMoney(context, remaining),
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Text('到账增加账户余额，按到账日期冲减消费净额，不计普通收入。'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (originals.isEmpty)
            const EmptyView(
              title: '暂无报销账目',
              description: '记支出时开启“标记待报销”，即可在此记录到账。',
            ),
          for (final original in originals)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SectionCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      original.merchant.isEmpty
                          ? original.categoryName ?? '报销支出'
                          : original.merchant,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${dateKey(original.occurredDate)} · ${original.reimbursementStatus}',
                    ),
                    Text(
                      '垫付 ${visibleMoney(context, original.amountMinor)} · 退款 ${visibleMoney(context, original.refundedMinor)}',
                    ),
                    Text(
                      '已报销 ${visibleMoney(context, original.reimbursedMinor)} · 剩余 ${visibleMoney(context, original.reimbursementRemaining)}',
                    ),
                    if (original.reimbursementRemaining > 0)
                      TextButton.icon(
                        onPressed: () => showTransactionEditor(
                          context,
                          refundOf: original,
                          reimbursement: true,
                        ),
                        icon: const Icon(Icons.add),
                        label: const Text('记录报销到账'),
                      ),
                    for (final receipt in state.entries.where(
                      (e) =>
                          e.isReimbursement &&
                          e.relatedTransactionId == original.id,
                    ))
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '到账 ${visibleMoney(context, receipt.amountMinor)}',
                        ),
                        subtitle: Text(
                          '${dateKey(receipt.occurredDate)} · ${receipt.accountName}',
                        ),
                        onTap: () =>
                            showTransactionEditor(context, entry: receipt),
                        trailing: IconButton(
                          tooltip: '删除到账记录',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('删除报销到账记录？'),
                                content: const Text(
                                  '账户余额、报销状态及统计会重新计算，可在回收站恢复。',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('取消'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('删除'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true) {
                              try {
                                await state.delete(receipt.id);
                              } catch (e) {
                                if (context.mounted) showError(context, e);
                              }
                            }
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
