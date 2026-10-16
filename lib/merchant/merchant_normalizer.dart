class MerchantMatch {
  const MerchantMatch(this.name, this.category, this.evidence);
  final String name;
  final String category;
  final String evidence;
}

/// A small, explicit starter dictionary. Unknown merchants stay unresolved.
class MerchantNormalizer {
  static const _aliases = {
    '瑞幸咖啡': ('咖啡', ['瑞幸咖啡', '瑞幸', 'luckin']),
    '星巴克': ('咖啡', ['星巴克', 'starbucks']),
    '松果出行': ('交通', ['松果出行', '北京快松果科技有限公司', '北京快松果']),
    '哈啰出行': ('交通', ['哈啰出行', '哈啰单车']),
    '美团单车': ('交通', ['美团单车']),
    '青桔单车': ('交通', ['青桔单车']),
    '滴滴': ('打车', ['滴滴', 'didi']),
    '美团外卖': ('外卖', ['美团外卖']),
    '饿了么': ('外卖', ['饿了么']),
    '盒马': ('日用品', ['盒马']),
    '京东': ('购物', ['京东', 'jd.com']),
    '淘宝': ('购物', ['淘宝']),
    'Costco': ('购物', ['costco', '开市客']),
  };

  List<MerchantMatch> find(String text) {
    final lower = text.toLowerCase();
    return [
      for (final entry in _aliases.entries)
        if (entry.value.$2.any(lower.contains))
          MerchantMatch(
            entry.key,
            entry.value.$1,
            entry.value.$2.firstWhere(lower.contains),
          ),
    ];
  }
}
