import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart' as auth_provider;
import 'providers/chat_provider.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/home_screen.dart';
import 'services/api_service.dart';
import 'services/auth_service.dart';
import 'services/websocket_service.dart';
import 'utils/constants.dart';
import 'utils/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ConverseApp());
}

class ConverseApp extends StatelessWidget {
  const ConverseApp({super.key});

  @override
  Widget build(BuildContext context) {
    const storage = FlutterSecureStorage();
    final wsService = WebSocketService();

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ));

    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await storage.read(key: AppConstants.tokenKey);
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (error, handler) {
        handler.next(error);
      },
    ));

    final authService = AuthService(dio, storage);
    final apiService = ApiService(dio);

    return MultiProvider(
      providers: [
        Provider<WebSocketService>.value(value: wsService),
        Provider<ApiService>.value(value: apiService),
        ChangeNotifierProvider(
          create: (_) => auth_provider.AuthProvider(authService, wsService),
        ),
        ChangeNotifierProvider(
          create: (_) => ChatProvider(apiService, wsService),
        ),
      ],
      child: MaterialApp(
        title: 'Converse',
        theme: AppTheme.dark,
        debugShowCheckedModeBanner: false,
        home: const _AppEntry(),
      ),
    );
  }
}

class _AppEntry extends StatefulWidget {
  const _AppEntry();

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final authProv = context.read<auth_provider.AuthProvider>();
      authProv.init().then((_) {
        if (authProv.isAuthenticated) {
          context.read<ChatProvider>().init();
        }
        authProv.addListener(() {
          if (authProv.isAuthenticated) {
            context.read<ChatProvider>().init();
          }
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final authState = context.watch<auth_provider.AuthProvider>().state;

    switch (authState) {
      case auth_provider.AuthState.unknown:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case auth_provider.AuthState.unauthenticated:
        return const LoginScreen();
      case auth_provider.AuthState.authenticated:
        return const HomeScreen();
    }
  }
}
