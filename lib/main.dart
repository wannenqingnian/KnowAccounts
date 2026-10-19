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
      final base = ThemeData(
        fontFamily: fontFamily ?? appearance.fontFamily,
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
        visualDensity: VisualDensity.standard,
      );
      final textTheme = base.textTheme.copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -.3,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.45),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.45),
        bodySmall: base.textTheme.bodySmall?.copyWith(
          height: 1.4,
          color: scheme.onSurfaceVariant,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      );
      return base.copyWith(
        textTheme: textTheme,
        iconTheme: IconThemeData(
          fill: appearance.iconStyle == 'filled' ? 1 : 0,
          color: scheme.onSurfaceVariant,
        ),
        appBarTheme: AppBarThemeData(
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          backgroundColor: scheme.surface,
          foregroundColor: scheme.onSurface,
          titleTextStyle: textTheme.titleLarge?.copyWith(
            color: scheme.onSurface,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surfaceContainerHighest,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 15,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide(color: scheme.primary, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(radius),
            borderSide: BorderSide(color: scheme.error),
          ),
        ),
        cardTheme: CardThemeData(
          color: scheme.surfaceContainerLowest,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius + 4),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
            ),
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.primary,
            side: BorderSide(color: scheme.outlineVariant),
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
            ),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            minimumSize: const Size(48, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
            ),
          ),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          elevation: 1,
          focusElevation: 2,
          hoverElevation: 2,
          highlightElevation: 2,
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius + 4),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          height: 72,
          elevation: 0,
          backgroundColor: scheme.surfaceContainerLowest,
          indicatorColor: scheme.primaryContainer,
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => textTheme.labelMedium?.copyWith(
              color: states.contains(WidgetState.selected)
                  ? scheme.onSurface
                  : scheme.onSurfaceVariant,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
            ),
          ),
        ),
        navigationRailTheme: NavigationRailThemeData(
          backgroundColor: scheme.surfaceContainerLowest,
          indicatorColor: scheme.primaryContainer,
          selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
          selectedLabelTextStyle: textTheme.labelLarge?.copyWith(
            color: scheme.primary,
          ),
        ),
        listTileTheme: ListTileThemeData(
          iconColor: scheme.onSurfaceVariant,
          textColor: scheme.onSurface,
          minTileHeight: 52,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant,
          thickness: 1,
          space: 24,
        ),
        chipTheme: base.chipTheme.copyWith(
          side: BorderSide(color: scheme.outlineVariant),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: scheme.surfaceContainerHigh,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius + 8),
          ),
        ),
        bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: scheme.surfaceContainerLow,
          modalBackgroundColor: scheme.surfaceContainerLow,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(radius + 10),
            ),
          ),
        ),
        menuTheme: MenuThemeData(
          style: MenuStyle(
            backgroundColor: WidgetStatePropertyAll(
              scheme.surfaceContainerHigh,
            ),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(3),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radius + 2),
              ),
            ),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: scheme.inverseSurface,
          contentTextStyle: textTheme.bodyMedium?.copyWith(
            color: scheme.onInverseSurface,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      );
    }

    return MaterialApp(
      title: '知账',
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(
              (media.textScaler.scale(1) * appearance.fontScale).clamp(.8, 2),
            ),
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
