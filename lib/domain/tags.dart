import 'dart:convert';
import 'models.dart';

List<String> normalizeTags(Iterable<String> tags) {
  final result = <String>{};
  for (final raw in tags) {
    final tag = raw.trim().replaceFirst(RegExp(r'^#+'), '');
    if (tag.isEmpty) continue;
    if (tag.length > 20 || RegExp(r'[,，;；\s]').hasMatch(tag)) {
      throw const LedgerException('标签最多20字，不包含空格或分隔符');
    }
    result.add(tag);
  }
  if (result.length > 10) throw const LedgerException('每笔最多10个标签');
  return List.unmodifiable(result);
}

List<String> parseTagInput(String text) =>
    normalizeTags(text.split(RegExp(r'[,，;；\s]+')));
List<String> decodeTags(String json) {
  final value = jsonDecode(json);
  if (value is! List || value.any((v) => v is! String)) {
    throw const LedgerException('标签数据格式错误');
  }
  return normalizeTags(value.cast<String>());
}
