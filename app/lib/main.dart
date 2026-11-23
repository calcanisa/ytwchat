import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app/app_session.dart';
import 'app/call_controller.dart';
import 'app/chat_controller.dart';
import 'core/config.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home/home_screen.dart';
import 'src/rust/frb_generated.dart';
import 'utils/theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppConfig.assertSecure(AppConfig.apiUrl);
  await RustLib.init();
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppSession()..init(),
      child: const YtwchatApp(),
    ),
  );
}

class YtwchatApp extends StatelessWidget {
  const YtwchatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    final engine = session.engine;
    final app = MaterialApp(
      navigatorKey: navigatorKey,
      title: 'ytwchat',
      theme: AppTheme.dark,
      debugShowCheckedModeBanner: false,
      home: const _Entry(),
    );
    if (session.status != AuthStatus.signedIn || engine == null) return app;
    return MultiProvider(
      key: ObjectKey(engine),
      providers: [
        ChangeNotifierProvider(create: (_) => ChatController(engine)),
        ChangeNotifierProvider(create: (_) => CallController(engine, navigatorKey)),
      ],
      child: app,
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    switch (session.status) {
      case AuthStatus.loading:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case AuthStatus.signedOut:
        return const LoginScreen();
      case AuthStatus.signedIn:
        return session.engine == null ? const LoginScreen() : const HomeScreen();
    }
  }
}
