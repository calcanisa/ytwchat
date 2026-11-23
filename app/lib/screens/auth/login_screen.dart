import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_session.dart';
import '../../utils/theme.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_loading) return;
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      _show('Enter your email and password.');
      return;
    }
    setState(() => _loading = true);
    final error = await context.read<AppSession>().login(_email.text, _password.text);
    if (!mounted) return;
    setState(() => _loading = false);
    if (error != null) _show(error);
  }

  void _show(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), backgroundColor: AppTheme.error));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            const SizedBox(height: 64),
            const Text('Welcome back', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('Sign in to ytwchat', style: TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 16)),
            const SizedBox(height: 48),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(hintText: 'Email'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: _obscure,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                hintText: 'Password',
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, color: AppTheme.onSurfaceMuted),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onSubmitted: (_) => _login(),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loading ? null : _login,
              child: _loading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Sign in'),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("Don't have an account? ", style: TextStyle(color: AppTheme.onSurfaceMuted)),
                TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterScreen())),
                  child: const Text('Create one'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
