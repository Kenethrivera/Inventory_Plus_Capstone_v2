import 'package:flutter/foundation.dart';
import 'package:flutter_litert/flutter_litert.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/material.dart';
import 'ui/login_page.dart';
import 'ui/main_screen.dart'; 
import 'logic/inventory_controller.dart'; 
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
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
  } catch (e) {
    print("Initialization Error: $e");
  }

  final inventoryController = InventoryController();

  runApp(InventoryApp(controller: inventoryController));
}

Future<void> initDetectorRuntime() async {
  if (kIsWeb) {
    await initializeWeb(); // loads the LiteRT.js/TFLite.js runtime in-browser
  }
}

class InventoryApp extends StatelessWidget {
  final InventoryController controller;

  const InventoryApp({super.key, required this.controller});

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
        '/main': (context) => MainScreen(controller: controller),
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
    final prefs = await SharedPreferences.getInstance();
    final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
    final userId = prefs.getString('userId');
    
    if (isLoggedIn && userId != null) {
      try {
        // Fetch user profile from the 'profiles' table.
        final userProfile = await Supabase.instance.client
            .from('profiles') 
            .select()
            .eq('id', userId)
            .maybeSingle();

        if (userProfile != null) {
          final String? assignedLocationId = userProfile['location_id'];

          widget.controller.setLoggedInUser(
            name: userProfile['name'] ?? 'User',
            id: userId,
            role: userProfile['role'] ?? 'staff',
          );

          if (assignedLocationId != null && assignedLocationId.isNotEmpty) {
            await widget.controller.loadAppData(assignedLocationId);
            if (mounted) {
              Navigator.pushReplacementNamed(context, '/main');
              return;
            }
          }
        }
      } catch (e) {
        print("Error restoring session: $e");
      }
      // If fetching profile or app data loading fails, clear session and fall back to login
      await prefs.clear();
    }
    
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/login');
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
