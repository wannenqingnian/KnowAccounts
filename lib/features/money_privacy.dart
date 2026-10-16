import 'package:flutter/material.dart';
import '../domain/money.dart';

class MoneyPrivacy extends InheritedWidget {
  const MoneyPrivacy({super.key, required this.hidden, required super.child});
  final bool hidden;
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MoneyPrivacy>()?.hidden ??
      false;
  @override
  bool updateShouldNotify(MoneyPrivacy oldWidget) => hidden != oldWidget.hidden;
}

String visibleMoney(BuildContext context, int minor, {bool symbol = true}) =>
    MoneyPrivacy.of(context) ? '••••' : money(minor, symbol: symbol);

String visibleCurrencyMoney(
  BuildContext context,
  int minor, {
  required String symbol,
  required int decimals,
}) => MoneyPrivacy.of(context)
    ? '••••'
    : currencyMoney(minor, symbol: symbol, decimals: decimals);
