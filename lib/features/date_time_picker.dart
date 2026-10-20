import 'package:flutter/material.dart';

import '../domain/money.dart';

Future<DateTime?> showSecondDateTimePicker(
  BuildContext context, {
  required DateTime initial,
}) async {
  var value = DateTime(
    initial.year,
    initial.month,
    initial.day,
    initial.hour,
    initial.minute,
    initial.second,
  );
  return showDialog<DateTime>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('选择记账时间'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text(dateKey(value)),
                onPressed: () async {
                  final date = await showDatePicker(
                    context: dialogContext,
                    initialDate: value,
                    firstDate: DateTime(1900),
                    lastDate: DateTime(2100, 12, 31),
                  );
                  if (date != null) {
                    setDialogState(() {
                      value = DateTime(
                        date.year,
                        date.month,
                        date.day,
                        value.hour,
                        value.minute,
                        value.second,
                      );
                    });
                  }
                },
              ),
              const SizedBox(height: 16),
              const Text('时间（时 : 分 : 秒）'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _TimeUnit(
                      key: const ValueKey('transaction_hour'),
                      value: value.hour,
                      count: 24,
                      onChanged: (hour) => setDialogState(
                        () => value = DateTime(
                          value.year,
                          value.month,
                          value.day,
                          hour,
                          value.minute,
                          value.second,
                        ),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text(':'),
                  ),
                  Expanded(
                    child: _TimeUnit(
                      key: const ValueKey('transaction_minute'),
                      value: value.minute,
                      count: 60,
                      onChanged: (minute) => setDialogState(
                        () => value = DateTime(
                          value.year,
                          value.month,
                          value.day,
                          value.hour,
                          minute,
                          value.second,
                        ),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text(':'),
                  ),
                  Expanded(
                    child: _TimeUnit(
                      key: const ValueKey('transaction_second'),
                      value: value.second,
                      count: 60,
                      onChanged: (second) => setDialogState(
                        () => value = DateTime(
                          value.year,
                          value.month,
                          value.day,
                          value.hour,
                          value.minute,
                          second,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                dateTimeLabel(value),
                textAlign: TextAlign.center,
                softWrap: true,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, value),
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}

class _TimeUnit extends StatelessWidget {
  const _TimeUnit({
    super.key,
    required this.value,
    required this.count,
    required this.onChanged,
  });
  final int value;
  final int count;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<int>(
    initialValue: value,
    isExpanded: true,
    decoration: const InputDecoration(
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 12),
    ),
    items: List.generate(
      count,
      (index) => DropdownMenuItem(
        value: index,
        child: Text(index.toString().padLeft(2, '0')),
      ),
    ),
    onChanged: (next) {
      if (next != null) onChanged(next);
    },
  );
}
