import 'money_privacy.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_state.dart';
import '../backup/backup_service.dart';
import '../domain/models.dart';
import '../domain/family_payment.dart';
import '../domain/money.dart';
import '../data/family_payment_repository.dart';
import 'widgets.dart';
import 'action_form.dart';
export 'action_form.dart';
import 'category_manager.dart';
import 'archived_accounts.dart';
import 'account_editor.dart';
import 'review_inbox.dart';
import 'ocr_page.dart';
import 'speech_model_page.dart';
import 'automation_page.dart';
import 'automation_logs_page.dart';
import 'transaction_editor.dart';
import 'card_number_dialog.dart';
import 'reimbursement_page.dart';
import 'trash_page.dart';
import 'bill_import_page.dart';
import 'transaction_templates_page.dart';
import 'recurring_rules_page.dart';
import 'desktop_shortcuts_page.dart';
import 'webdav_sync_page.dart';
import 'financial_assets_page.dart';
import 'currency_page.dart';
import 'bill_tools_page.dart';
import 'appearance_page.dart';
import 'auto_correction_page.dart';
import 'budget_page.dart';
import 'tag_manager_page.dart';
import 'family_cards_page.dart';

Future<void> editBudget(
  BuildContext context,
  WidgetRef ref,
  LedgerController state,
) async {
  await actionForm(
    context,
    title: '${state.month.month} 月预算',
    fields: [
      InputSpec(
        'amount',
        '预算金额',
        numeric: true,
        initial: (state.summary!.budgetMinor / 100).toStringAsFixed(2),
      ),
    ],
    description: '输入 0 可取消本月预算。',
    submit: (values) async {
      final value = values['amount']!.trim();
      final amount = RegExp(r'^0(\.0{1,2})?$').hasMatch(value)
          ? 0
          : parseMoney(value);
      await state.repository.setBudget(state.ledgerId, state.month, amount);
      await state.load();
    },
  );
}

class AccountsPage extends ConsumerStatefulWidget {
  const AccountsPage({super.key, required this.state});
  final LedgerController state;

  @override
  ConsumerState<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends ConsumerState<AccountsPage> {
  LedgerController get state => widget.state;
  List<FamilyCardAccountSummary> _familyCards = const [];
  final Set<String> _collapsedGroups = {};

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_loadFamilyCards);
  }

  @override
  void didUpdateWidget(covariant AccountsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.ledgerId != widget.state.ledgerId) {
      Future<void>.microtask(_loadFamilyCards);
    }
  }

  Future<void> _loadFamilyCards() async {
    final ledgerId = state.ledgerId;
    try {
      final cards = await FamilyPaymentRepository(
        state.repository.db,
      ).cards(ledgerId);
      if (mounted && state.ledgerId == ledgerId) {
        setState(() => _familyCards = cards);
      }
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _add(BuildContext context) async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('新增账户'), subtitle: Text('选择账户类型')),
            ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: const Text('资金与负债账户'),
              subtitle: const Text('现金、银行卡、微信、支付宝、信用卡等'),
              onTap: () => Navigator.pop(sheetContext, 'normal'),
            ),
            ListTile(
              leading: const Icon(Icons.family_restroom_outlined),
              title: const Text('亲情卡账户'),
              subtitle: const Text('微信亲属卡或支付宝亲情卡额度账户'),
              onTap: () => Navigator.pop(sheetContext, 'family'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (kind == 'normal') {
      await showAccountEditor(context, state);
    } else if (kind == 'family') {
      await showFamilyCardEditor(context, state);
      await _loadFamilyCards();
    }
  }

  Future<void> _edit(BuildContext context, Account account) =>
      showAccountEditor(context, state, account: account);

  Future<void> _viewCard(BuildContext context, Account account) async {
    try {
      final value = await state.repository.fullCardNumber(
        state.ledgerId,
        account.id,
      );
      if (context.mounted && value != null) {
        await showDialog<void>(
          context: context,
          builder: (_) => CardNumberDialog(name: account.name, number: value),
        );
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _accountActions(BuildContext context, Account account) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(account.displayName),
              subtitle: Text(
                '${accountKindLabel(account.kind)} · ${visibleCurrencyMoney(context, account.balanceMinor, symbol: account.currencySymbol, decimals: account.currencyDecimals)}',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑账户'),
              onTap: () => Navigator.pop(sheetContext, 'edit'),
            ),
            if (account.cardSecretId != null)
              ListTile(
                leading: const Icon(Icons.visibility_off_outlined),
                title: const Text('查看卡号'),
                onTap: () => Navigator.pop(sheetContext, 'card'),
              ),
            if (account.kind.isDebt)
              ListTile(
                leading: const Icon(Icons.payments_outlined),
                title: const Text('记录还款'),
                onTap: () => Navigator.pop(sheetContext, 'repay'),
              ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('归档账户'),
              onTap: () => Navigator.pop(sheetContext, 'archive'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case 'edit':
        await _edit(context, account);
        return;
      case 'card':
        await _viewCard(context, account);
        return;
      case 'repay':
        await showTransactionEditor(context, repaymentTo: account);
        return;
      case 'archive':
        await archiveAccount(context, state, account);
        return;
    }
  }

  bool _isInvestmentAccount(Account a) {
    final name = a.name.toLowerCase();
    return name.contains('理财') ||
        name.contains('基金') ||
        name.contains('股票') ||
        name.contains('证券') ||
        name.contains('投资') ||
        name.contains('余额宝') ||
        name.contains('理财通') ||
        name.contains('定期') ||
        name.contains('黄金') ||
        name.contains('资产');
  }

  Widget _buildGroupSection(
    BuildContext context, {
    required String groupKey,
    required String title,
    required String totalText,
    required List<Account> accounts,
    List<FamilyCardAccountSummary> familyCards = const [],
    required IconData icon,
    required Color iconColor,
  }) {
    if (accounts.isEmpty && familyCards.isEmpty) return const SizedBox.shrink();
    final isCollapsed = _collapsedGroups.contains(groupKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() {
            if (isCollapsed) {
              _collapsedGroups.remove(groupKey);
            } else {
              _collapsedGroups.add(groupKey);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                Icon(icon, size: 17, color: iconColor),
                const SizedBox(width: 6),
                Text(
                  '$title · ${accounts.length + familyCards.length}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Icon(
                  isCollapsed
                      ? Icons.keyboard_arrow_right
                      : Icons.keyboard_arrow_down,
                  size: 18,
                  color: Colors.grey,
                ),
                const Spacer(),
                Text(
                  totalText,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!isCollapsed) ...[
          const SizedBox(height: 2),
          SectionCard(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < accounts.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 52, endIndent: 4),
                  _accountTile(context, accounts[i]),
                ],
                for (var i = 0; i < familyCards.length; i++) ...[
                  if (accounts.isNotEmpty || i > 0)
                    const Divider(height: 1, indent: 52, endIndent: 4),
                  _familyAccountTile(context, familyCards[i]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    int inCny(Account account) =>
        (account.balanceMinor * account.rateToCnyMicros + 500000) ~/ 1000000;

    final fundingAccounts = state.accounts
        .where((a) => !a.kind.isDebt && !_isInvestmentAccount(a))
        .toList();
    final investmentAccounts = state.accounts
        .where((a) => !a.kind.isDebt && _isInvestmentAccount(a))
        .toList();
    final creditDebtAccounts = state.accounts
        .where((a) => a.kind.isDebt)
        .toList();

    final fundingAssets = state.allAccounts
        .where((a) => !a.kind.isDebt && !_isInvestmentAccount(a))
        .fold<int>(0, (s, a) => s + inCny(a));

    final investmentAssets = state.allAccounts
        .where((a) => !a.kind.isDebt && _isInvestmentAccount(a))
        .fold<int>(0, (s, a) => s + inCny(a));

    final investmentProfit = state.entries
        .where(
          (e) =>
              e.type == TransactionType.income &&
              (e.categoryName?.contains('理财') == true ||
                  e.categoryName?.contains('投资') == true ||
                  e.categoryName?.contains('利息') == true ||
                  e.categoryName?.contains('收益') == true),
        )
        .fold<int>(0, (s, e) => s + e.amountMinor);

    final debtTotal = state.allAccounts
        .where((a) => a.kind.isDebt)
        .fold<int>(
          0,
          (s, a) => s + (a.balanceMinor < 0 ? -inCny(a) : inCny(a)),
        );

    final receivableTotal = state.allAccounts
        .where(
          (a) =>
              !a.kind.isDebt &&
              (a.name.contains('应收') ||
                  a.name.contains('借出') ||
                  a.name.contains('债权')),
        )
        .fold<int>(0, (s, a) => s + (a.balanceMinor > 0 ? inCny(a) : 0));

    final reimbursableExpenses = state.entries
        .where((e) => e.type == TransactionType.expense && e.reimbursable)
        .toList();
    final pendingReimbursement = reimbursableExpenses.fold<int>(
      0,
      (s, e) => s + e.reimbursementRemaining,
    );
    final reimbursedTotal = reimbursableExpenses.fold<int>(
      0,
      (s, e) => s + e.reimbursedMinor,
    );

    final positiveFunding = state.allAccounts
        .where(
          (a) =>
              !a.kind.isDebt && !_isInvestmentAccount(a) && a.balanceMinor > 0,
        )
        .fold<int>(0, (s, a) => s + inCny(a));
    final positiveInvestment = state.allAccounts
        .where(
          (a) =>
              !a.kind.isDebt && _isInvestmentAccount(a) && a.balanceMinor > 0,
        )
        .fold<int>(0, (s, a) => s + inCny(a));

    final totalAssets = positiveFunding + positiveInvestment + receivableTotal;

    final negativeFunding = state.allAccounts
        .where((a) => !a.kind.isDebt && a.balanceMinor < 0)
        .fold<int>(0, (s, a) => s + -inCny(a));
    final totalLiabilities = debtTotal + negativeFunding;

    final netAsset = totalAssets - totalLiabilities;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 顶部净资产主卡片（对齐用户图示风格）
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 16, 18, 18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                colors.primaryContainer,
                colors.primaryContainer.withValues(alpha: .72),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: colors.shadow.withValues(alpha: .08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '净资产(元)',
                    style: TextStyle(
                      color: colors.onPrimaryContainer,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    visualDensity: VisualDensity.compact,
                    tooltip: state.amountPrivacy ? '显示金额' : '隐藏金额',
                    icon: Icon(
                      state.amountPrivacy
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                      color: colors.onPrimaryContainer,
                    ),
                    onPressed: () =>
                        state.setAmountPrivacy(!state.amountPrivacy),
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '总资产 ',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                          Text(
                            visibleMoney(context, totalAssets, symbol: false),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '负资产 ',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                          Text(
                            visibleMoney(
                              context,
                              totalLiabilities,
                              symbol: false,
                            ),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: colors.onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                visibleMoney(context, netAsset),
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                  color: netAsset < 0
                      ? colors.error
                      : colors.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // 下方 3 栏轻卡片：报销 / 债务 / 理财 （完全契合截图要求）
        Row(
          children: [
            // 报销卡片
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ReimbursementPage()),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 10,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: colors.shadow.withValues(alpha: .06),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Text(
                        '报销',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '可报: ',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              visibleMoney(
                                context,
                                pendingReimbursement,
                                symbol: false,
                              ),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: colors.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 3),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '已报: ',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            Text(
                              visibleMoney(
                                context,
                                reimbursedTotal,
                                symbol: false,
                              ),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),

            // 债务卡片
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 10,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: colors.shadow.withValues(alpha: .06),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Text(
                      '债务',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '应付: ',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            visibleMoney(context, debtTotal, symbol: false),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: debtTotal > 0
                                  ? colors.error
                                  : colors.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 3),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '应收: ',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            visibleMoney(
                              context,
                              receivableTotal,
                              symbol: false,
                            ),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: colors.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),

            // 理财卡片
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 10,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: colors.shadow.withValues(alpha: .06),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Text(
                      '理财',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: colors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '总额: ',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            visibleMoney(
                              context,
                              investmentAssets,
                              symbol: false,
                            ),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: colors.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 3),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '盈亏: ',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            visibleMoney(
                              context,
                              investmentProfit,
                              symbol: false,
                            ),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: investmentProfit >= 0
                                  ? colors.primary
                                  : colors.error,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                '全部账户 · ${state.accounts.length + _familyCards.length}',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => showArchivedAccounts(context),
              icon: const Icon(Icons.archive_outlined, size: 17),
              label: Text(
                '归档 ${state.allAccounts.where((a) => a.archived).length}',
              ),
            ),
            IconButton(
              tooltip: '新增账户',
              visualDensity: VisualDensity.compact,
              onPressed: () => _add(context),
              icon: const Icon(Icons.add, color: teal),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (state.accounts.isEmpty && _familyCards.isEmpty)
          const SectionCard(
            child: EmptyView(title: '还没有账户', description: '新增账户后即可开始记账。'),
          )
        else ...[
          _buildGroupSection(
            context,
            groupKey: 'funding',
            title: '资金账户',
            totalText: '资金 ${visibleMoney(context, fundingAssets)}',
            accounts: fundingAccounts,
            icon: Icons.account_balance_wallet_outlined,
            iconColor: teal,
          ),
          _buildGroupSection(
            context,
            groupKey: 'investment',
            title: '理财账户',
            totalText: '理财 ${visibleMoney(context, investmentAssets)}',
            accounts: investmentAccounts,
            icon: Icons.trending_up,
            iconColor: Colors.blue,
          ),
          _buildGroupSection(
            context,
            groupKey: 'credit',
            title: '信贷与债务',
            totalText: '债务 ${visibleMoney(context, debtTotal)}',
            accounts: creditDebtAccounts,
            icon: Icons.credit_card,
            iconColor: orange,
          ),
          _buildGroupSection(
            context,
            groupKey: 'family',
            title: '亲情卡账户',
            totalText: '${_familyCards.length} 张',
            accounts: const [],
            familyCards: _familyCards,
            icon: Icons.family_restroom_outlined,
            iconColor: Colors.deepOrange,
          ),
        ],
      ],
    );
  }

  Widget _accountTile(BuildContext context, Account account) {
    final repayment = account.nextRepayment(DateTime.now());
    final isInvest = _isInvestmentAccount(account);
    final iconColor = account.kind.isDebt
        ? orange
        : isInvest
        ? Colors.blue
        : teal;
    final bgColor = account.kind.isDebt
        ? const Color(0xFFFFF3E0)
        : isInvest
        ? const Color(0xFFE8F1FF)
        : const Color(0xFFEAF2E9);
    final iconData = account.kind.isDebt
        ? Icons.credit_card
        : isInvest
        ? Icons.trending_up
        : Icons.account_balance_wallet_outlined;
    final subtitle = [
      accountKindLabel(account.kind),
      account.currency,
      if (account.kind.isDebt)
        repayment == null ? '未设还款日' : '${repayment.month}月${repayment.day}日还款',
      if (account.cardSecretId != null) '已保存卡号',
    ].join(' · ');
    final shownBalance = account.kind.isDebt && account.balanceMinor < 0
        ? -account.balanceMinor
        : account.balanceMinor;
    return SwipeActionPane(
      onTap: () => _accountActions(context, account),
      actions: [
        SwipePaneAction(
          key: ValueKey('edit_account_${account.id}'),
          color: teal,
          icon: Icons.edit_outlined,
          label: '编辑',
          onPressed: () => _edit(context, account),
        ),
        SwipePaneAction(
          key: ValueKey('archive_account_${account.id}'),
          color: orange,
          icon: Icons.archive_outlined,
          label: '归档',
          onPressed: () => archiveAccount(context, state, account),
        ),
      ],
      child: ListTile(
        key: ValueKey('account_row_${account.id}'),
        dense: true,
        visualDensity: const VisualDensity(vertical: -2),
        minVerticalPadding: 4,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(iconData, color: iconColor, size: 20),
        ),
        title: Text(
          account.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        trailing: Text(
          '${account.kind.isDebt && account.balanceMinor < 0 ? '欠 ' : ''}${visibleCurrencyMoney(context, shownBalance, symbol: account.currencySymbol, decimals: account.currencyDecimals)}',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: account.balanceMinor < 0 ? orange : ink,
          ),
        ),
      ),
    );
  }

  Future<void> _editFamily(BuildContext context, FamilyCardAccount card) async {
    await showFamilyCardEditor(context, state, card: card);
    await _loadFamilyCards();
  }

  Future<void> _archiveFamily(
    BuildContext context,
    FamilyCardAccount card,
  ) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('归档亲情卡账户？'),
        content: Text('${card.displayName} 的历史额度和消费记录会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (approved != true || !context.mounted) return;
    await FamilyPaymentRepository(
      state.repository.db,
    ).archiveCard(state.ledgerId, card.id);
    await _loadFamilyCards();
  }

  Widget _familyAccountTile(
    BuildContext context,
    FamilyCardAccountSummary summary,
  ) {
    final card = summary.card;
    final roleLabel = card.localRole == FamilyLocalRole.payer ? '发送方' : '使用方';
    final limit = card.activeLimitMinor;
    final usage = limit <= 0
        ? null
        : (summary.usedMinor / limit).clamp(0.0, 1.0);
    final percent = usage == null ? '未设置' : '已用 ${(usage * 100).round()}%';
    return SwipeActionPane(
      onTap: () => _editFamily(context, card),
      actions: [
        SwipePaneAction(
          key: ValueKey('edit_family_account_${card.id}'),
          color: teal,
          icon: Icons.edit_outlined,
          label: '编辑',
          onPressed: () => _editFamily(context, card),
        ),
        SwipePaneAction(
          key: ValueKey('archive_family_account_${card.id}'),
          color: orange,
          icon: Icons.archive_outlined,
          label: '归档',
          onPressed: () => _archiveFamily(context, card),
        ),
      ],
      child: ListTile(
        key: ValueKey('family_account_row_${card.id}'),
        dense: true,
        visualDensity: const VisualDensity(vertical: -2),
        minVerticalPadding: 4,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFFEAF2E9),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.family_restroom_outlined,
            color: teal,
            size: 20,
          ),
        ),
        title: Text(
          card.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${card.platform.label} · $roleLabel · 本月已用 ${visibleMoney(context, summary.usedMinor)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: usage ?? 0,
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  percent,
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              visibleMoney(context, summary.availableMinor),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
            Text(
              '$roleLabel可用',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

String accountKindLabel(AccountKind kind) => accountTypeLabel(kind);

class ManagePage extends ConsumerWidget {
  const ManagePage({super.key});

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color color = teal,
  }) => ListTile(
    dense: true,
    visualDensity: const VisualDensity(vertical: -1),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
    minLeadingWidth: 36,
    leading: Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon, color: color, size: 20),
    ),
    title: Text(
      title,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ),
    subtitle: Text(
      subtitle,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: Color(0xFF77827E)),
    ),
    trailing: const Icon(Icons.chevron_right, size: 20),
    onTap: onTap,
  );

  Widget _section(String title, List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 7),
        child: Text(
          title,
          style: const TextStyle(
            color: Color(0xFF66736F),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      SectionCard(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: children),
      ),
    ],
  );

  Widget get _divider => const Divider(height: 1, indent: 64, endIndent: 14);

  Future<void> _backup(
    BuildContext context,
    LedgerController state, {
    required bool restore,
  }) async {
    await actionForm(
      context,
      title: restore ? '恢复加密备份' : '导出加密备份',
      description: restore
          ? '恢复会替换所有账本的当前数据。请先导出当前备份；密码验证和数据检查失败时，当前数据保持不变。'
          : '所有账本将加密保存为一个文件。请妥善保管密码，丢失后无法恢复。',
      fields: [
        const InputSpec('password', '备份密码', secret: true),
        if (!restore) const InputSpec('confirmation', '再次输入密码', secret: true),
      ],
      submit: (values) async {
        final service = BackupService(
          state.repository.db,
          cardVault: state.repository.cardVault,
        );
        if (restore) {
          final result = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: ['slbackup'],
            withData: false,
          );
          if (result == null) return;
          final file = result.files.single;
          if (file.size > maxBackupBytes) {
            throw const LedgerException('备份文件超过 50 MB');
          }
          final bytes = file.bytes ?? await File(file.path!).readAsBytes();
          await service.restore(bytes, values['password']!);
          await state.load();
        } else {
          if (values['password'] != values['confirmation']) {
            throw const LedgerException('两次输入的密码不一致');
          }
          final bytes = await service.export(values['password']!);
          final path = await FilePicker.platform.saveFile(
            dialogTitle: '保存加密备份',
            fileName: '知账-${dateKey(DateTime.now())}.slbackup',
            type: FileType.custom,
            allowedExtensions: ['slbackup'],
            bytes: bytes,
          );
          if (path != null &&
              (Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
            await File(path).writeAsBytes(bytes, flush: true);
          }
        }
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(ledgerProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section('待处理', [
          _tile(
            icon: Icons.inbox_outlined,
            title: '待确认账单 · ${state.pendingDrafts.length}',
            subtitle: '核对或忽略，未确认账单不计入余额',
            onTap: () => showReviewInbox(context),
          ),
          _divider,
          _tile(
            icon: Icons.payments_outlined,
            title: '报销管理',
            subtitle: '待报销、部分报销、已报销及到账记录',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ReimbursementPage(),
              ),
            ),
          ),
          _divider,
          _tile(
            icon: Icons.delete_outline,
            title: '回收站',
            subtitle: '恢复、彻底删除及设置自动清理期限',
            onTap: () => showTrashPage(context),
          ),
        ]),
        _section('智能记账', [
          _tile(
            icon: Icons.auto_mode,
            title: '自动记账',
            subtitle: '支付通知监听、无障碍增强与软件适配',
            onTap: () => showAutomationPage(context),
          ),
          _divider,
          _tile(
            icon: Icons.manage_search_outlined,
            title: '自动修正管理',
            subtitle: '按商户沿用账户、分类、账本和标签',
            onTap: () => showAutoCorrectionPage(context),
          ),
          _divider,
          _tile(
            icon: Icons.document_scanner_outlined,
            title: 'OCR模型与图片导入',
            subtitle: '按需下载模型，离线识别截图',
            onTap: () => showOcrPage(context),
          ),
          _divider,
          _tile(
            icon: Icons.table_view_outlined,
            title: '批量导入账单',
            subtitle: '支付宝、微信、云闪付及 Excel，支持退款关联',
            onTap: () => showBillImportPage(context),
          ),
          _divider,
          _tile(
            icon: Icons.mic_none,
            title: '语音模型',
            subtitle: '按需下载 SenseVoiceSmall，本地离线识别',
            onTap: () => showSpeechModelPage(context),
          ),
          _divider,
          _tile(
            icon: Icons.receipt_long_outlined,
            title: '日志记录',
            subtitle: '默认记录全部日志，可开关、查看、筛选、复制或导出',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AutomationLogsPage(),
              ),
            ),
          ),
          _divider,
          _tile(
            icon: Icons.widgets_outlined,
            title: '桌面快捷方式与小组件',
            subtitle: '把记账、语音、OCR和模板入口添加到桌面',
            onTap: () => showDesktopShortcutsPage(context),
          ),
        ]),
        _section('账本与分类', [
          _tile(
            icon: Icons.donut_small_outlined,
            title: '预算管理',
            subtitle: '分类、多预算、周期结转、超支提醒、明细与归档',
            onTap: () => showBudgetPlansPage(context),
          ),
          _divider,
          _tile(
            icon: Icons.category_outlined,
            title: '分类管理',
            subtitle: '图标、模板、分享、新增、排序与归档',
            onTap: () => showCategoryManager(context),
          ),
          _divider,
          _tile(
            icon: Icons.label_outline,
            title: '标签管理',
            subtitle: '改名、合并、隐藏、智能标签与标签账单页',
            onTap: () => showTagManager(context),
          ),
          _divider,
          _tile(
            icon: Icons.dashboard_customize_outlined,
            title: '记账模板',
            subtitle: '组合金额、账户、分类、标签和备注后快速套用',
            onTap: () => showTransactionTemplates(context),
          ),
          _divider,
          _tile(
            icon: Icons.auto_stories_outlined,
            title: '新建账本',
            subtitle: '个人、旅行、装修等账目分别记录',
            onTap: () => actionForm(
              context,
              title: '新建账本',
              fields: [const InputSpec('name', '账本名称')],
              submit: (v) async {
                await state.repository.createLedger(v['name']!);
                await state.load();
              },
            ),
          ),
        ]),
        _section('资产与账单工具', [
          _tile(
            icon: Icons.account_balance_outlined,
            title: '资产与负债',
            subtitle: '股票、基金、定期、房贷、分期、借出与信用卡周期',
            onTap: () => showFinancialAssetsPage(context),
          ),
          _divider,
          _tile(
            icon: Icons.currency_exchange,
            title: '币种与汇率',
            subtitle: '外币账户、币种精度及兑人民币汇率',
            onTap: () => showCurrencyPage(context),
          ),
          _divider,
          _tile(
            icon: Icons.folder_copy_outlined,
            title: '账单分组与 AA',
            subtitle: '管理账单分组；拆分与AA可从每条流水的操作中进入',
            onTap: () => showBillGroupsPage(context),
          ),
        ]),
        _section('周期计划', [
          _tile(
            icon: Icons.event_repeat_outlined,
            title: '周期收支',
            subtitle: '房租、工资、订阅等固定收入与支出',
            onTap: () =>
                showRecurringRules(context, RecurringKind.incomeExpense),
          ),
          _divider,
          _tile(
            icon: Icons.swap_horiz,
            title: '周期转账',
            subtitle: '账户间自动规划划转与还款',
            onTap: () => showRecurringRules(context, RecurringKind.transfer),
          ),
          _divider,
          _tile(
            icon: Icons.trending_up,
            title: '周期投资',
            subtitle: '定投、储蓄和投资账户划转计划',
            onTap: () => showRecurringRules(context, RecurringKind.investment),
          ),
        ]),
        _section('外观与个性化', [
          _tile(
            icon: Icons.palette_outlined,
            title: '主题、字体与图标',
            subtitle: '颜色、背景、字号、图标风格及主题分享',
            onTap: () => showAppearancePage(context),
          ),
        ]),
        _section('数据与隐私', [
          SwitchListTile.adaptive(
            dense: true,
            visualDensity: const VisualDensity(vertical: -1),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 2,
            ),
            secondary: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: teal.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(
                Icons.visibility_off_outlined,
                color: teal,
                size: 20,
              ),
            ),
            title: const Text(
              '金额隐私模式',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              '隐藏金额与分析图表，编辑账目时仍可查看',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Color(0xFF77827E)),
            ),
            value: state.amountPrivacy,
            onChanged: (v) async {
              try {
                await state.setAmountPrivacy(v);
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
          _divider,
          _tile(
            icon: Icons.cloud_sync_outlined,
            title: 'WebDAV 加密同步',
            subtitle: '加密后上传，支持多设备恢复与冲突保护',
            onTap: () => showWebDavSyncPage(context),
          ),
          _divider,
          _tile(
            icon: Icons.lock_outline,
            title: '导出加密备份',
            subtitle: '保存全部账本，使用密码加密',
            onTap: () => _backup(context, state, restore: false),
          ),
          _divider,
          _tile(
            icon: Icons.restore,
            title: '恢复备份',
            subtitle: '从加密文件恢复全部账本',
            onTap: () => _backup(context, state, restore: true),
          ),
        ]),
        const SizedBox(height: 4),
      ],
    );
  }
}
