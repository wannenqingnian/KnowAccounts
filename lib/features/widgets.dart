import 'money_privacy.dart';
import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../theme/transaction_colors.dart';

const ink = Color(0xFF183C38);
const teal = Color(0xFF237A66);
const orange = Color(0xFFC97443);

const categoryIconLibrary = <String, IconData>{
  'food': Icons.restaurant_outlined,
  'transport': Icons.directions_transit_outlined,
  'shopping': Icons.shopping_bag_outlined,
  'home': Icons.home_outlined,
  'entertainment': Icons.sports_esports_outlined,
  'medical': Icons.medical_services_outlined,
  'education': Icons.school_outlined,
  'travel': Icons.flight_outlined,
  'salary': Icons.payments_outlined,
  'investment': Icons.trending_up,
  'gift': Icons.card_giftcard_outlined,
  'digital': Icons.devices_outlined,
  'sports': Icons.fitness_center_outlined,
  'beauty': Icons.spa_outlined,
  'child': Icons.child_care_outlined,
  'insurance': Icons.health_and_safety_outlined,
  'other': Icons.receipt_long_outlined,
};

const categoryIconLabels = <String, String>{
  'food': '餐饮',
  'transport': '交通',
  'shopping': '购物',
  'home': '居住',
  'entertainment': '娱乐',
  'medical': '医疗',
  'education': '教育',
  'travel': '旅行',
  'salary': '工资',
  'investment': '投资',
  'gift': '礼物',
  'digital': '数码',
  'sports': '运动',
  'beauty': '美容',
  'child': '育儿',
  'insurance': '保险',
  'other': '其他',
};

IconData categoryIcon(String? name, [String iconKey = '']) {
  if (categoryIconLibrary.containsKey(iconKey)) {
    return categoryIconLibrary[iconKey]!;
  }
  if (name != null && RegExp('餐|咖啡|外卖').hasMatch(name)) {
    return Icons.restaurant_outlined;
  }
  if (name != null && RegExp('交通|打车|地铁').hasMatch(name)) {
    return Icons.directions_transit_outlined;
  }
  if (name != null && RegExp('购物|日用|服饰').hasMatch(name)) {
    return Icons.shopping_bag_outlined;
  }
  if (name != null && RegExp('居住|房租|水电').hasMatch(name)) {
    return Icons.home_outlined;
  }
  return Icons.receipt_long_outlined;
}

String typeLabel(TransactionType type) => switch (type) {
  TransactionType.expense => '支出',
  TransactionType.income => '收入',
  TransactionType.transfer => '转账',
  TransactionType.refund => '退款',
  TransactionType.adjustment => '调整',
};

class EntryTile extends StatelessWidget {
  const EntryTile({
    super.key,
    required this.entry,
    required this.onTap,
    this.onEdit,
    this.onDelete,
  });
  final LedgerEntry entry;
  final VoidCallback onTap;
  final Future<void> Function()? onEdit;
  final Future<void> Function()? onDelete;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final transactionColors = TransactionColors.of(context);
    final positive =
        entry.type == TransactionType.income ||
        entry.type == TransactionType.refund;
    final transfer = entry.type == TransactionType.transfer;
    final title = entry.merchant.isNotEmpty
        ? entry.merchant
        : entry.categoryName ?? typeLabel(entry.type);
    final swipeEnabled = onEdit != null || onDelete != null;
    final tile = ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      minVerticalPadding: 4,
      contentPadding: const EdgeInsets.symmetric(horizontal: 2),
      onTap: swipeEnabled ? null : onTap,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: (positive ? colors.primary : colors.tertiaryContainer)
              .withValues(alpha: positive ? .10 : .55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          transfer
              ? Icons.swap_horiz
              : positive
              ? Icons.south_west
              : categoryIcon(entry.categoryName),
          color: positive ? colors.primary : colors.onTertiaryContainer,
          size: 20,
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.titleSmall,
      ),
      subtitle: Text(
        '${entry.accountName} · ${entry.isReimbursement ? '报销到账' : typeLabel(entry.type)}${entry.currency == 'CNY' ? '' : ' · 折合${visibleMoney(context, entry.amountMinor)}'}${entry.reimbursable ? ' · ${entry.reimbursementStatus}' : ''}${entry.attachmentCount > 0 ? ' · 图片${entry.attachmentCount}' : ''}${entry.note.isNotEmpty ? ' · ${entry.note}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodySmall,
      ),
      trailing: Text(
        '${transfer
            ? ''
            : positive
            ? '+'
            : '-'}${entry.currency == 'CNY' ? visibleMoney(context, entry.amountMinor) : visibleCurrencyMoney(context, entry.displayAmountMinor, symbol: entry.currencySymbol, decimals: entry.currencyDecimals)}',
        style: TextStyle(
          color: transfer
              ? colors.onSurface
              : positive
              ? transactionColors.income
              : transactionColors.expense,
          fontWeight: FontWeight.w700,
          fontSize: 15,
        ),
      ),
    );
    if (!swipeEnabled) return tile;
    return SwipeActionPane(
      onTap: onTap,
      actions: [
        if (onEdit != null)
          SwipePaneAction(
            key: ValueKey('entry-edit-${entry.id}'),
            color: colors.primary,
            icon: Icons.edit_outlined,
            label: '编辑',
            onPressed: onEdit!,
          ),
        if (onDelete != null)
          SwipePaneAction(
            key: ValueKey('entry-delete-${entry.id}'),
            color: colors.error,
            icon: Icons.delete_outline,
            label: '删除',
            onPressed: onDelete!,
          ),
      ],
      child: tile,
    );
  }
}

class SwipePaneAction {
  const SwipePaneAction({
    required this.key,
    required this.color,
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final Key key;
  final Color color;
  final IconData icon;
  final String label;
  final Future<void> Function() onPressed;
}

class SwipeActionPane extends StatefulWidget {
  const SwipeActionPane({
    super.key,
    required this.onTap,
    required this.actions,
    required this.child,
  });
  final VoidCallback onTap;
  final List<SwipePaneAction> actions;
  final Widget child;

  @override
  State<SwipeActionPane> createState() => _SwipeActionPaneState();
}

class _SwipeActionPaneState extends State<SwipeActionPane> {
  static const _actionWidth = 68.0;
  double _offset = 0;
  bool _dragging = false;

  double get _paneWidth => _actionWidth * widget.actions.length;
  bool get _isOpen => _offset < -1;

  void _close() {
    if (!mounted) return;
    setState(() {
      _dragging = false;
      _offset = 0;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    _close();
    await action();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: Stack(
      children: [
        Positioned.fill(
          child: Align(
            alignment: Alignment.centerRight,
            child: IgnorePointer(
              ignoring: !_isOpen,
              child: ExcludeSemantics(
                excluding: !_isOpen,
                child: SizedBox(
                  width: _paneWidth,
                  child: Row(
                    children: [
                      for (final action in widget.actions)
                        _action(
                          key: action.key,
                          color: action.color,
                          icon: action.icon,
                          label: action.label,
                          onTap: () => _run(action.onPressed),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        AnimatedContainer(
          duration: _dragging
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(_offset, 0, 0),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => setState(() => _dragging = true),
            onHorizontalDragUpdate: (details) {
              setState(() {
                _offset = (_offset + details.delta.dx).clamp(-_paneWidth, 0);
              });
            },
            onHorizontalDragEnd: (_) {
              setState(() {
                _dragging = false;
                _offset = _offset < -40 ? -_paneWidth : 0;
              });
            },
            onHorizontalDragCancel: _close,
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              child: InkWell(
                onTap: _isOpen ? _close : widget.onTap,
                child: widget.child,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _action({
    required Key key,
    required Color color,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) => SizedBox(
    key: key,
    width: _actionWidth,
    child: Material(
      color: color,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 19, color: Colors.white),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.title,
    required this.description,
    this.icon = Icons.auto_stories_outlined,
    this.action,
  });
  final String title;
  final String description;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 12),
      child: Center(
        child: Column(
          children: [
            Icon(icon, size: 38, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
