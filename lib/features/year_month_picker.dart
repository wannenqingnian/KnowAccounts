import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<DateTime?> showYearMonthPicker(
  BuildContext context, {
  required DateTime initial,
  bool yearOnly = false,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (_) => _YearMonthDialog(initial: initial, yearOnly: yearOnly),
  );
}

class _YearMonthDialog extends StatefulWidget {
  const _YearMonthDialog({required this.initial, required this.yearOnly});
  final DateTime initial;
  final bool yearOnly;

  @override
  State<_YearMonthDialog> createState() => _YearMonthDialogState();
}

class _YearMonthDialogState extends State<_YearMonthDialog> {
  late int _year = widget.initial.year;

  Future<void> _enterYear() async {
    var input = '$_year';
    String? error;
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('输入年份'),
          content: TextFormField(
            key: const ValueKey('year_manual_input'),
            initialValue: input,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (value) => input = value,
            decoration: InputDecoration(
              labelText: '年份',
              helperText: '可输入 1900～2100',
              errorText: error,
            ),
            onFieldSubmitted: (value) {
              final year = int.tryParse(value);
              if (year != null && year >= 1900 && year <= 2100) {
                Navigator.pop(context, year);
              } else {
                setDialogState(() => error = '请输入 1900～2100');
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final year = int.tryParse(input);
                if (year == null || year < 1900 || year > 2100) {
                  setDialogState(() => error = '请输入 1900～2100');
                  return;
                }
                Navigator.pop(context, year);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (widget.yearOnly) {
      Navigator.pop(context, DateTime(selected, widget.initial.month));
    } else {
      setState(() => _year = selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final decade = (_year ~/ 10) * 10;
    return AlertDialog(
      title: Text(widget.yearOnly ? '选择年份' : '选择年月'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: widget.yearOnly ? '上十年' : '上一年',
                  onPressed: () =>
                      setState(() => _year -= widget.yearOnly ? 10 : 1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: TextButton.icon(
                    key: const ValueKey('year_manual_button'),
                    onPressed: _enterYear,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.edit_outlined, size: 17),
                    label: Text(
                      widget.yearOnly ? '$decade—${decade + 11}' : '$_year 年',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: widget.yearOnly ? '下十年' : '下一年',
                  onPressed: () =>
                      setState(() => _year += widget.yearOnly ? 10 : 1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            const SizedBox(height: 8),
            GridView.count(
              shrinkWrap: true,
              crossAxisCount: 4,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.5,
              children: widget.yearOnly
                  ? List.generate(12, (index) {
                      final year = decade + index;
                      return _Choice(
                        label: '$year',
                        selected: year == widget.initial.year,
                        onTap: () => Navigator.pop(
                          context,
                          DateTime(year, widget.initial.month),
                        ),
                      );
                    })
                  : List.generate(12, (index) {
                      final month = index + 1;
                      return _Choice(
                        label: '$month 月',
                        selected:
                            _year == widget.initial.year &&
                            month == widget.initial.month,
                        onTap: () =>
                            Navigator.pop(context, DateTime(_year, month)),
                      );
                    }),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? Theme.of(context).colorScheme.primaryContainer
        : Theme.of(context).colorScheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    ),
  );
}
