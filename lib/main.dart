import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_state.dart';
import 'automation/payment_worker.dart';
import 'automation/recurring_background.dart';
import 'core/database/app_database.dart';
import 'data/ledger_repository.dart';
import 'features/home_shell.dart';
import 'features/money_privacy.dart';
import 'features/widgets.dart';
import 'core/security/card_vault.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'PaddleOCR / PP-OCR',
      'RapidOCR model conversion',
      'ONNX Runtime',
      'OpenCV',
    ], await rootBundle.loadString('assets/ocr_licenses.txt'));
  });
  try {
    final database = await AppDatabase.open();
    final repository = LedgerRepository(
      database,
      cardVault: const DeviceCardVault(),
    );
    await repository.initialize();
    try {
      await RecurringBackground.sync(repository);
    } catch (_) {
      // Unsupported desktop platforms still process plans when the app opens.
    }
    runApp(
      ProviderScope(
        overrides: [repositoryProvider.overrideWithValue(repository)],
        child: const SmartLedgerApp(),
      ),
    );
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.storage_outlined, size: 48),
                SizedBox(height: 16),
                Text('本地数据库无法打开'),
                SizedBox(height: 8),
                Text('请检查设备剩余空间后重启应用。'),
                SizedBox(height: 8),
                Text('已有数据不会被自动删除。'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SmartLedgerApp extends ConsumerWidget {
  const SmartLedgerApp({super.key, this.fontFamily});
  final String? fontFamily;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(ledgerProvider).appearance;
    final radius = appearance.iconStyle == 'sharp' ? 5.0 : 14.0;
    ThemeData createTheme(Brightness brightness) {
      final dark = brightness == Brightness.dark;
      final scheme = ColorScheme.fromSeed(
        seedColor: Color(appearance.seedColor),
        brightness: brightness,
        surface: dark
            ? const Color(0xFF111714)
            : Color(appearance.backgroundColor),
      );
      return ThemeData(
        fontFamily: fontFamily ?? appearance.fontFamily,
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
        textTheme: TextTheme(
          bodyMedium: TextStyle(color: dark ? scheme.onSurface : ink),
        ),
        iconTheme: IconThemeData(
          fill: appearance.iconStyle == 'filled' ? 1 : 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: dark ? scheme.surfaceContainerHigh : Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        cardTheme: CardThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius + 4),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
            ),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: dark ? scheme.surfaceContainer : Colors.white,
          indicatorColor: scheme.primaryContainer,
        ),
      );
    }

    return MaterialApp(
      title: '知账',
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(appearance.fontScale),
          ),
          child: MoneyPrivacy(
            hidden: ref.watch(ledgerProvider).amountPrivacy,
            child: child!,
          ),
        );
      },
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: switch (appearance.brightness) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      theme: createTheme(Brightness.light),
      darkTheme: createTheme(Brightness.dark),
      home: const HomeShell(),
    );
  }
}

@pragma('vm:entry-point')
Future<void> paymentAutomationWorker() => runPaymentAutomationWorker();

@pragma('vm:entry-point')
Future<void> recurringPlanWorker() => runRecurringBackgroundWorker();
