import 'package:flutter/foundation.dart';
import 'package:flutter_litert/flutter_litert.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/material.dart';
import 'ui/login_page.dart';
import 'ui/main_screen.dart'; 
import 'logic/inventory_controller.dart'; 
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'login/auth_service.dart';
import 'services/realtime/realtime_sync_service.dart';

Future<void> main() async {
  final startupStopwatch = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();

  if (kDebugMode) debugPrint('[Startup] Flutter entry');
  
try {
      await dotenv.load(fileName: "lib/.env");
      // Use const String.fromEnvironment to read Vercel's injected keys
      // await Supabase.initialize(
      //   url: const String.fromEnvironment('SUPABASE_URL'),
      //   anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
      // );

      await Supabase.initialize(
      url: dotenv.env['SUPABASE_URL']!,
      anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
    );
    if (kDebugMode) {
      debugPrint(
        '[Startup] Supabase initialized '
        'elapsed=${startupStopwatch.elapsedMilliseconds}ms',
      );
    }
  } catch (e) {
    debugPrint("Initialization Error: $e");
  }

  final inventoryController = InventoryController();
  final realtimeSyncService = RealtimeSyncService();

  inventoryController.bindRealtimeSync(realtimeSyncService);

  runApp(
    InventoryApp(
      controller: inventoryController,
      realtimeSync: realtimeSyncService,
    ),
  );
  if (kDebugMode) {
    debugPrint(
      '[Startup] runApp requested '
      'elapsed=${startupStopwatch.elapsedMilliseconds}ms',
    );
  }
}
Future<void> initDetectorRuntime() async {
  if (kIsWeb) {
    await initializeWeb(); // loads the LiteRT.js/TFLite.js runtime in-browser
  }
}

class InventoryApp extends StatelessWidget {
  final InventoryController controller;
  final RealtimeSyncService realtimeSync;

  const InventoryApp({
    super.key,
    required this.controller,
    required this.realtimeSync,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Inventory Plus',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => AuthWrapper(controller: controller),
        '/login': (context) => LoginPage(controller: controller),
        '/main': (context) =>
            MainScreen(controller: controller, realtimeSync: realtimeSync),
        
      },
    );
  }
}

class AuthWrapper extends StatefulWidget {
  final InventoryController controller;

  const AuthWrapper({super.key, required this.controller});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  _AuthRestoreState _restoreState = _AuthRestoreState.restoring;
  bool _restoreInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAuth();
    });
  }

  Future<void> _checkAuth() async {
    if (_restoreInFlight) return;
    _restoreInFlight = true;
    if (mounted) {
      setState(() => _restoreState = _AuthRestoreState.restoring);
    }
    final stopwatch = Stopwatch()..start();
    if (kDebugMode) debugPrint('[Startup] Auth restore started');

    try {
      final prefs = await SharedPreferences.getInstance();
      final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
      final sessionToken = prefs.getString('sessionToken');

      if (!isLoggedIn || sessionToken == null || sessionToken.isEmpty) {
        await prefs.clear();
        await _routeToLogin();
        return;
      }

      try {
        final userProfile = await AuthService().restoreSession(sessionToken);

        if (userProfile == null) {
          await prefs.clear();
          await _routeToLogin();
          return;
        }

        final assignedLocationId = userProfile['location_id']?.toString();
        final userId = userProfile['id']?.toString();
        final role = userProfile['role']?.toString();
        if (assignedLocationId == null ||
            assignedLocationId.isEmpty ||
            userId == null ||
            userId.isEmpty ||
            role == null ||
            role.isEmpty) {
          throw const FormatException(
            'Session restoration returned an incomplete profile.',
          );
        }

        widget.controller.setLoggedInUser(
          name: userProfile['name']?.toString() ?? 'User',
          id: userId,
          role: role,
          email: userProfile['email']?.toString(),
          sessionToken: sessionToken,
        );
        widget.controller.setActiveLocation(assignedLocationId);

        if (!mounted) return;
        setState(() => _restoreState = _AuthRestoreState.authenticated);
        if (kDebugMode) {
          debugPrint(
            '[Startup] Restored profile, role, location, and session '
            'elapsed=${stopwatch.elapsedMilliseconds}ms',
          );
        }
        Navigator.pushReplacementNamed(context, '/main');
        if (kDebugMode) {
          debugPrint('[Startup] MainScreen route requested');
        }
      } catch (error, stackTrace) {
        debugPrint('[Startup] Session restore temporarily failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        if (mounted) {
          setState(() => _restoreState = _AuthRestoreState.failed);
        }
      }
    } catch (error, stackTrace) {
      debugPrint('[Startup] Session storage restore failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        setState(() => _restoreState = _AuthRestoreState.failed);
      }
    } finally {
      _restoreInFlight = false;
    }
  }

  Future<void> _routeToLogin() async {
    if (!mounted) return;
    setState(() => _restoreState = _AuthRestoreState.invalid);
    Navigator.pushReplacementNamed(context, '/login');
    if (kDebugMode) debugPrint('[Startup] LoginPage route requested');
  }

  @override
  Widget build(BuildContext context) {
    if (_restoreState == _AuthRestoreState.failed) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.cloud_off_outlined,
                    color: Colors.white70,
                    size: 32,
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Unable to restore your session',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Check your connection and try again. Your saved session '
                    'has not been cleared.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _checkAuth,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return const Scaffold(
      backgroundColor: Color(0xFF0F172A),
      body: Center(
        child: CircularProgressIndicator(color: Colors.orange),
      ),
    );
  }
}

enum _AuthRestoreState { restoring, authenticated, invalid, failed }
