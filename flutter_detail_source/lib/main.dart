// lib/main.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'core/auth/insightflow_auth_service.dart';
import 'core/auth/supabase_auth_service.dart';
import 'features/auth/auth_gate.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'features/dashboard/data_screen.dart';
import 'core/interop/office_host.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {}

@pragma('vm:entry-point')
void alarmDispatcher() {}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassWidgets.initialize();

  // Additive Phase 1 initialization. Firebase remains the active provider.
  try {
    await InsightFlowSupabaseAuthService.initialize();
    InsightFlowSupabaseAuthService.logSafeStatus();
  } catch (error) {
    debugPrint(
      '[supabase-auth] optional initialization failed: ${error.runtimeType}',
    );
  }

  String? firebaseInitError;
  final supabaseConfigured = InsightFlowSupabaseConfig.isConfigured;

  // Keep Firebase configuration validation/core initialization separate from
  // optional provider initialization. A Google SDK failure must never be
  // reported as a missing Firebase configuration.
  try {
    final firebaseOptions =
        InsightFlowAuthService.validateFirebaseConfiguration();
    debugPrint('[auth-init] firebase-options: valid');
    await InsightFlowAuthService.initializeFirebaseCore(firebaseOptions);
    debugPrint('[auth-init] firebase-core: initialized');
  } catch (error, stackTrace) {
    debugPrint(
      '[auth-init] Firebase startup failed at configuration/core stage: '
      '${error.runtimeType}',
    );
    debugPrintStack(stackTrace: stackTrace);
    if (!supabaseConfigured) {
      firebaseInitError =
          'Firebase authentication is not configured for this build.';
    }
  }

  if (firebaseInitError == null) {
    try {
      await InsightFlowAuthService.initializeFirebasePersistence();
      debugPrint('[auth-init] firebase-persistence: initialized');
    } catch (error, stackTrace) {
      debugPrint(
        '[auth-init] firebase-persistence failed: ${error.runtimeType}',
      );
      debugPrintStack(stackTrace: stackTrace);
    }

    try {
      await InsightFlowAuthService.initializeGoogleSignIn();
      debugPrint('[auth-init] google-sign-in: initialized');
    } catch (error, stackTrace) {
      debugPrint('[auth-init] google-sign-in failed: ${error.runtimeType}');
      debugPrintStack(stackTrace: stackTrace);
    }

    try {
      await InsightFlowAuthService.initializeRedirectResult();
      debugPrint('[auth-init] redirect-result: processed');
    } catch (error, stackTrace) {
      debugPrint('[auth-init] redirect-result failed: ${error.runtimeType}');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  runApp(ElectricAIApp(firebaseInitError: firebaseInitError));
}

class ElectricAIApp extends StatelessWidget {
  const ElectricAIApp({super.key, this.firebaseInitError});

  final String? firebaseInitError;

  /// Detect if device has low available memory.
  ///
  /// Returns:
  /// - `true` on Android (assume memory-constrained, disable shaders)
  /// - `false` on web (no shader memory constraints)
  /// - `false` on iOS/desktop (sufficient memory for shaders)
  ///
  /// This prevents OutOfMemory crashes by using BackdropFilter-only
  /// (GlassQuality.minimal) rendering on constrained devices.
  bool _isLowMemoryDevice() {
    // Web has no memory constraints from shader rendering
    // (web uses Skia/CanvasKit which handles shaders differently)
    if (kIsWeb) return false;

    // dart:io is only available on native platforms (Android, iOS, desktop)
    // On web, this code path never executes
    if (!Platform.isAndroid) return false;

    // Conservative: assume Android phones may be memory-constrained
    // (typical Android heap: 256-512MB; shaders can add 40-60MB overhead)
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // Office Add-in task panes run inside a WebView2 instance that, on some
    // machines, doesn't reliably support the fragment shaders that
    // GlassQuality.standard/premium depend on — GlassContainer/GlassCard
    // surfaces then paint as solid blank blocks instead of throwing a
    // catchable error (this doesn't happen in a plain Chrome tab, which is
    // why "flutter run -d chrome" during development looks fine while the
    // real Excel Add-in doesn't). GlassQuality.minimal is the only tier that
    // never touches a shader (BackdropFilter-only). Hosted Flutter Web is
    // also forced onto this tier because browser/WebGL shader failures can
    // otherwise turn dynamically-built analysis cards into blank white
    // surfaces. Excel Add-in and browser web therefore use the same robust
    // non-fragment-shader rendering path; native desktop/mobile keeps the
    // richer shader path where supported.
    final officeHost = isRunningInsideOffice;
    final lowMemory = _isLowMemoryDevice();
    final shouldForceMinimal = officeHost || lowMemory || kIsWeb;

    return LiquidGlassWidgets.wrap(
      adaptiveQuality: !shouldForceMinimal,
      theme: GlassThemeData(
        // Force dark — this app is a dark liquid glass surface regardless
        // of system brightness.
        brightness: Brightness.dark,
        dark: GlassThemeVariant(
          settings: const GlassThemeSettings(
            glassColor: Color(0x1FFFFFFF), // ~12% white
            thickness: 20,
            blur: 14,
            refractiveIndex: 0.9,
            saturation: 1.2,
            ambientStrength: 0.4,
            lightIntensity: 0.8,
          ),
          quality: shouldForceMinimal
              ? GlassQuality.minimal
              : GlassQuality.standard,
        ),
      ),
      child: CupertinoApp(
        debugShowCheckedModeBanner: false,
        theme: const CupertinoThemeData(brightness: Brightness.dark),
        // CupertinoApp only wires up Cupertino localizations by default.
        // This app also uses Material widgets (Scaffold, DropdownButton,
        // SnackBar/ScaffoldMessenger) throughout, so those delegates must
        // be added explicitly — without them you get "No MaterialLocalizations
        // found" for any Material widget that needs one.
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => Theme(
          data: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(
              0xFF020715,
            ), // deep navy, matches glass_settings.dart
            fontFamily: 'SFPro', // swap out the old 'Courier' tech-console font
          ),
          // MaterialApp normally inserts a ScaffoldMessenger above the
          // Navigator automatically; CupertinoApp doesn't. Without this,
          // any ScaffoldMessenger.of(context).showSnackBar(...) call
          // (e.g. showError/showNotification in data_screen.dart) throws
          // "No ScaffoldMessenger widget found".
          child: ScaffoldMessenger(child: child!),
        ),
        home: firebaseInitError == null
            ? const AuthGate()
            : const _FirebaseConfigurationError(),
      ),
    );
  }
}

class _FirebaseConfigurationError extends StatelessWidget {
  const _FirebaseConfigurationError();

  @override
  Widget build(BuildContext context) {
    return const CupertinoPageScaffold(
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Firebase authentication is not configured for this build.\n\n'
            'Register the InsightFlow Web app and rebuild with its Firebase Web configuration.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
