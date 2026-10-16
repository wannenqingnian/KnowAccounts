import 'dart:async';
import 'package:flutter/material.dart';

class CardNumberDialog extends StatefulWidget {
  const CardNumberDialog({super.key, required this.name, required this.number});
  final String name;
  final String number;
  @override
  State<CardNumberDialog> createState() => _CardNumberDialogState();
}

class _CardNumberDialogState extends State<CardNumberDialog> {
  bool _shown = false;
  Timer? _timer;
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle() {
    _timer?.cancel();
    setState(() => _shown = !_shown);
    if (_shown) {
      _timer = Timer(const Duration(seconds: 30), () {
        if (mounted) setState(() => _shown = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.name),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _shown
              ? widget.number
              : '•••• •••• •••• ${widget.number.substring(widget.number.length - 4)}',
        ),
        TextButton.icon(
          onPressed: _toggle,
          icon: Icon(
            _shown ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          ),
          label: Text(_shown ? '隐藏完整卡号' : '显示完整卡号'),
        ),
        const Text('显示后30秒自动隐藏'),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
