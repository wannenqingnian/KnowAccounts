import 'package:flutter/material.dart';

@immutable
class TransactionColors extends ThemeExtension<TransactionColors> {
  const TransactionColors({required this.expense, required this.income});

  final Color expense;
  final Color income;

  static TransactionColors of(BuildContext context) =>
      Theme.of(context).extension<TransactionColors>() ??
      const TransactionColors(
        expense: Color(0xFFC63C4D),
        income: Color(0xFF16815F),
      );

  @override
  TransactionColors copyWith({Color? expense, Color? income}) =>
      TransactionColors(
        expense: expense ?? this.expense,
        income: income ?? this.income,
      );

  @override
  TransactionColors lerp(TransactionColors? other, double t) => other == null
      ? this
      : TransactionColors(
          expense: Color.lerp(expense, other.expense, t)!,
          income: Color.lerp(income, other.income, t)!,
        );
}
