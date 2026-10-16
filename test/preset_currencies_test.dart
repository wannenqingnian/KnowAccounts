import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ledger/domain/preset_currencies.dart';

void main() {
  test('preset currencies list includes major global currencies from screenshots', () {
    expect(presetCurrencies, isNotEmpty);
    expect(presetCurrencies.length, greaterThan(150));

    final usd = presetCurrencies.firstWhere((c) => c.code == 'USD');
    expect(usd.name, '美元');
    expect(usd.symbol, '\$');
    expect(usd.rateToCny, 6.71);

    final eur = presetCurrencies.firstWhere((c) => c.code == 'EUR');
    expect(eur.name, '欧元');
    expect(eur.symbol, '€');
    expect(eur.rateToCny, 7.52);

    final hkd = presetCurrencies.firstWhere((c) => c.code == 'HKD');
    expect(hkd.name, '港元');
    expect(hkd.rateToCny, 0.86);

    final jpy = presetCurrencies.firstWhere((c) => c.code == 'JPY');
    expect(jpy.name, '日元');
    expect(jpy.decimals, 0);

    final thb = presetCurrencies.firstWhere((c) => c.code == 'THB');
    expect(thb.name, '泰铢');
    expect(thb.rateToCny, 0.20);
  });

  test('preset currency reciprocal rates calculate properly', () {
    final nok = presetCurrencies.firstWhere((c) => c.code == 'NOK');
    expect(nok.rateToCny, 0.70);
    expect(nok.cnyToRate, closeTo(1.4285, 0.01));
  });
}
