/// Native text confidence is an engine score, not a correctness probability.
class OcrTextLine {
  const OcrTextLine(this.text, this.confidence, this.top);
  final String text;
  final double confidence;
  final int top;
}

class OcrRecognition {
  const OcrRecognition(
    this.text, {
    this.lines = const [],
    this.engineVersion = '',
    this.modelVersion = '',
  });
  final String text;
  final List<OcrTextLine> lines;
  final String engineVersion;
  final String modelVersion;

  Iterable<OcrTextLine> get bodyLines {
    final footer = lines
        .where(
          (line) => RegExp(r'^(?:交易服务|账单服务|商家小程序)$').hasMatch(line.text.trim()),
        )
        .toList();
    final end = footer.isEmpty
        ? null
        : footer.map((line) => line.top).reduce((a, b) => a < b ? a : b);
    return lines.where(
      (line) =>
          (end == null || line.top < end) &&
          line.text.trim().runes.length >= 2 &&
          !RegExp(r'^(?:主页|首页|留言|交易详情|账单详情|返回|关闭)$').hasMatch(line.text.trim()),
    );
  }

  bool get hasClearBody {
    final body = bodyLines;
    return body.isNotEmpty &&
        body.every(
          (line) =>
              line.confidence.isFinite &&
              line.confidence >= .90 &&
              line.confidence <= 1,
        );
  }
}
