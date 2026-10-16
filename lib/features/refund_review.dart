import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../domain/models.dart';
import '../domain/money.dart';
import 'money_privacy.dart';
import '../transaction/parser/transaction_parser.dart';
import '../transaction/refund_matcher.dart';
import 'transaction_editor.dart';
import 'widgets.dart';

Future<void> showRefundReview(
  BuildContext context, {
  required TransactionDraft draft,
  String? draftId,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => _RefundReview(draft: draft, draftId: draftId),
);

class _RefundReview extends ConsumerStatefulWidget {
  const _RefundReview({required this.draft, this.draftId});

  final TransactionDraft draft;
  final String? draftId;

  @override
  ConsumerState<_RefundReview> createState() => _RefundReviewState();
}

class _RefundReviewState extends ConsumerState<_RefundReview> {
  bool _busy = false;
  String? _error;

  Future<void> _select(String originalId) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = ref.read(ledgerProvider);
    try {
      final linked = RefundMatcher.link(
        widget.draft,
        originalId,
        state.accounts,
        state.categories,
      );
      final id = await state.repository.storeDraft(linked, id: widget.draftId);
      await state.load();
      if (!mounted) return;
      Navigator.pop(context);
      await showTransactionEditor(context, draft: linked, draftId: id);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error is LedgerException ? error.message : '退款关联失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ledgerProvider);
    final matches = RefundMatcher.candidates(widget.draft, state.entries);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .82,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('关联退款', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(
              '已识别退款 ${widget.draft.amountMinor == null ? '金额待确认' : visibleMoney(context, widget.draft.amountMinor!)}。请选择对应的原消费，退款不会计为普通收入。',
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 12),
            if (matches.isEmpty)
              const SectionCard(
                child: Text('没有找到金额足够且日期更早的原消费。请先导入或补记原消费，再处理本条退款。'),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: matches.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = matches[index];
                    return ListTile(
                      enabled: !_busy,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        item.merchant.isEmpty ? '未填写商户' : item.merchant,
                      ),
                      subtitle: Text(
                        '${dateKey(item.occurredDate)} · ${item.accountName} · 可退 ${visibleMoney(context, item.reimbursementRemaining)}',
                      ),
                      trailing: Text(visibleMoney(context, item.amountMinor)),
                      onTap: () => _select(item.id),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
