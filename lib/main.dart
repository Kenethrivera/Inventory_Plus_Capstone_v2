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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAuth();
    });
  }

  Future<void> _checkAuth() async {
    final stopwatch = Stopwatch()..start();
    if (kDebugMode) debugPrint('[Startup] Auth restore started');

    final prefs = await SharedPreferences.getInstance();
    final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
    final sessionToken = prefs.getString('sessionToken');
    
    if (isLoggedIn && sessionToken != null && sessionToken.isNotEmpty) {
      try {
        final userProfile = await AuthService().restoreSession(sessionToken);

        if (userProfile != null) {
          final String? assignedLocationId = userProfile['location_id'];
          final userId = userProfile['id'].toString();

          widget.controller.setLoggedInUser(
            name: userProfile['name'] ?? 'User',
            id: userId,
            role: userProfile['role'] ?? 'staff',
            email: userProfile['email']?.toString(),
            sessionToken: sessionToken,
          );

          if (assignedLocationId != null && assignedLocationId.isNotEmpty) {
            widget.controller.setActiveLocation(assignedLocationId);
            if (kDebugMode) {
              debugPrint(
                '[Startup] Restored profile and location '
                'elapsed=${stopwatch.elapsedMilliseconds}ms',
              );
            }
            if (mounted) {
              Navigator.pushReplacementNamed(context, '/main');
              if (kDebugMode) {
                debugPrint('[Startup] MainScreen route requested');
              }
              return;
            }
          }
        }
      } catch (e) {
        debugPrint("Error restoring session: $e");
      }
      // If profile restoration fails, clear the session and fall back to login.
      await prefs.clear();
    }
    
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/login');
      if (kDebugMode) {
        debugPrint(
          '[Startup] LoginPage route requested '
          'elapsed=${stopwatch.elapsedMilliseconds}ms',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0F172A),
      body: Center(
        child: CircularProgressIndicator(color: Colors.orange),
      ),
    );
  }
}
