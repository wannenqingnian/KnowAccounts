import 'dart:convert';

class AppearanceSettings {
  const AppearanceSettings({
    this.seedColor = 0xFF1D8C73,
    this.backgroundColor = 0xFFF7F8F2,
    this.font = 'system',
    this.fontScale = 1,
    this.iconStyle = 'outlined',
    this.brightness = 'system',
    this.transactionPalette = 'expenseRed',
  });

  final int seedColor;
  final int backgroundColor;
  final String font;
  final double fontScale;
  final String iconStyle;
  final String brightness;
  final String transactionPalette;

  String? get fontFamily => switch (font) {
    'serif' => 'serif',
    'monospace' => 'monospace',
    _ => null,
  };

  AppearanceSettings copyWith({
    int? seedColor,
    int? backgroundColor,
    String? font,
    double? fontScale,
    String? iconStyle,
    String? brightness,
    String? transactionPalette,
  }) => AppearanceSettings(
    seedColor: seedColor ?? this.seedColor,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    font: font ?? this.font,
    fontScale: fontScale ?? this.fontScale,
    iconStyle: iconStyle ?? this.iconStyle,
    brightness: brightness ?? this.brightness,
    transactionPalette: transactionPalette ?? this.transactionPalette,
  );

  Map<String, Object> toJson() => {
    'version': 1,
    'seedColor': seedColor,
    'backgroundColor': backgroundColor,
    'font': font,
    'fontScale': fontScale,
    'iconStyle': iconStyle,
    'brightness': brightness,
    'transactionPalette': transactionPalette,
  };

  String encode() => jsonEncode(toJson());

  String shareCode() =>
      'ZHI-THEME-1:${base64Url.encode(utf8.encode(encode())).replaceAll('=', '')}';

  static AppearanceSettings decode(String? source) {
    if (source == null || source.trim().isEmpty) {
      return const AppearanceSettings();
    }
    var value = source.trim();
    if (value.startsWith('ZHI-THEME-1:')) {
      final encoded = value.substring('ZHI-THEME-1:'.length);
      value = utf8.decode(base64Url.decode(base64Url.normalize(encoded)));
    }
    final json = jsonDecode(value);
    if (json is! Map<String, dynamic> || json['version'] != 1) {
      throw const FormatException('不支持的主题格式');
    }
    final seed = json['seedColor'];
    final background = json['backgroundColor'];
    final scale = json['fontScale'];
    final font = json['font'];
    final icons = json['iconStyle'];
    final brightness = json['brightness'];
    final transactionPalette = json['transactionPalette'] ?? 'expenseRed';
    if (seed is! int ||
        background is! int ||
        scale is! num ||
        !{'system', 'serif', 'monospace'}.contains(font) ||
        !{'outlined', 'filled', 'sharp'}.contains(icons) ||
        !{'system', 'light', 'dark'}.contains(brightness) ||
        !{'expenseRed', 'expenseGreen'}.contains(transactionPalette) ||
        scale < .8 ||
        scale > 1.4) {
      throw const FormatException('主题参数无效');
    }
    return AppearanceSettings(
      seedColor: seed,
      backgroundColor: background,
      font: font as String,
      fontScale: scale.toDouble(),
      iconStyle: icons as String,
      brightness: brightness as String,
      transactionPalette: transactionPalette as String,
    );
  }
}
