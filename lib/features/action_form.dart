import 'package:flutter/material.dart';
import '../domain/models.dart';

void showError(BuildContext context, Object error) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error is LedgerException ? error.message : '操作失败，请重试'),
      ),
    );

class InputSpec {
  const InputSpec(
    this.key,
    this.label, {
    this.initial = '',
    this.options,
    this.numeric = false,
    this.secret = false,
    this.required = true,
  });
  final String key;
  final String label;
  final String initial;
  final Map<String, String>? options;
  final bool numeric;
  final bool secret;
  final bool required;
}

Future<bool?> actionForm(
  BuildContext context, {
  required String title,
  required List<InputSpec> fields,
  required Future<void> Function(Map<String, String>) submit,
  String? description,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ActionDialog(
    title: title,
    fields: fields,
    submit: submit,
    description: description,
  ),
);

class _ActionDialog extends StatefulWidget {
  const _ActionDialog({
    required this.title,
    required this.fields,
    required this.submit,
    this.description,
  });
  final String title;
  final List<InputSpec> fields;
  final Future<void> Function(Map<String, String>) submit;
  final String? description;
  @override
  State<_ActionDialog> createState() => _ActionDialogState();
}

class _ActionDialogState extends State<_ActionDialog> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers;
  final Map<String, String> _choices = {};
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final field in widget.fields)
        if (field.options == null)
          field.key: TextEditingController(text: field.initial),
    };
    for (final field in widget.fields) {
      if (field.options != null) {
        _choices[field.key] = field.options!.containsKey(field.initial)
            ? field.initial
            : field.options!.keys.first;
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.submit({
        ..._choices,
        for (final e in _controllers.entries) e.key: e.value.text,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is LedgerException ? e.message : '操作失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.description != null) ...[
                  Text(widget.description!),
                  const SizedBox(height: 18),
                ],
                for (final field in widget.fields)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: field.options != null
                        ? DropdownButtonFormField<String>(
                            initialValue: _choices[field.key],
                            decoration: InputDecoration(labelText: field.label),
                            isExpanded: true,
                            items: field.options!.entries
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value),
                                  ),
                                )
                                .toList(),
                            onChanged: _busy
                                ? null
                                : (v) => _choices[field.key] = v!,
                          )
                        : TextFormField(
                            controller: _controllers[field.key],
                            enabled: !_busy,
                            obscureText: field.secret,
                            keyboardType: field.numeric
                                ? const TextInputType.numberWithOptions(
                                    decimal: true,
                                    signed: true,
                                  )
                                : TextInputType.text,
                            decoration: InputDecoration(labelText: field.label),
                            validator: (v) =>
                                field.required &&
                                    (v == null || v.trim().isEmpty)
                                ? '请填写${field.label}'
                                : null,
                          ),
                  ),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_busy) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? '处理中…' : '确认'),
        ),
      ],
    ),
  );
}
