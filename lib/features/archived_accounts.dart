import 'money_privacy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_state.dart';
import '../domain/models.dart';
import 'action_form.dart';

Future<void> archiveAccount(
  BuildContext context,
  LedgerController state,
  Account account,
) async {
  final ledger = state.ledgerId;
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('归档“${account.name}”？'),
      content: const Text('新记账不再显示此账户。余额、欠款、历史流水及统计仍保留；需要记账或还款时请先恢复账户。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('归档'),
        ),
      ],
    ),
  );
  if (yes != true) return;
  try {
    if (state.ledgerId != ledger) throw const LedgerException('账本已变化，请重新操作');
    await state.repository.setAccountArchived(ledger, account.id, true);
    await state.load();
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> showArchivedAccounts(BuildContext context) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => const ArchivedAccounts()),
);

class ArchivedAccounts extends ConsumerStatefulWidget {
  const ArchivedAccounts({super.key});
  @override
  ConsumerState<ArchivedAccounts> createState() => _ArchivedAccountsState();
}

class _ArchivedAccountsState extends ConsumerState<ArchivedAccounts> {
  bool _busy = false;
  Future<void> _restore(Account account) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final state = ref.read(ledgerProvider);
      await state.repository.setAccountArchived(
        state.ledgerId,
        account.id,
        false,
      );
      await state.load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref
        .watch(ledgerProvider)
        .allAccounts
        .where((a) => a.archived)
        .toList();
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('已归档账户')),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('归档账户仍计入总余额及资产趋势；恢复后可继续记账与还款。'),
            ),
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('暂无已归档账户'))
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (_, i) => ListTile(
                        title: Text(rows[i].displayName),
                        subtitle: Text(
                          '余额 ${visibleMoney(context, rows[i].balanceMinor)}',
                        ),
                        trailing: TextButton(
                          onPressed: _busy ? null : () => _restore(rows[i]),
                          child: const Text('恢复账户'),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
