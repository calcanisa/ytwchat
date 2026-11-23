import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_session.dart';
import '../../utils/theme.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  bool _obscure = true;

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (_loading || !(_form.currentState?.validate() ?? false)) return;
    setState(() => _loading = true);
    final session = context.read<AppSession>();
    final navigator = Navigator.of(context);
    final error = await session.register(
      username: _username.text,
      displayName: _displayName.text,
      email: _email.text,
      password: _password.text,
    );
    if (!mounted) return;
    setState(() => _loading = false);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error), backgroundColor: AppTheme.error));
      return;
    }
    navigator.popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            children: [
              const Text('Create your account', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                'Your messages are end to end encrypted. Only the people in a chat can read them.',
                style: TextStyle(color: AppTheme.onSurfaceMuted, fontSize: 15),
              ),
              const SizedBox(height: 32),
              TextFormField(
                controller: _displayName,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.name],
                decoration: const InputDecoration(hintText: 'Your name'),
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (t.isEmpty || t.length > 60) return 'Enter a name between 1 and 60 characters.';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _username,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newUsername],
                decoration: const InputDecoration(hintText: 'Username', prefixText: '@'),
                validator: (v) {
                  final t = (v ?? '').trim().toLowerCase();
                  if (!RegExp(r'^[a-z0-9_]{3,30}$').hasMatch(t)) {
                    return 'Use 3 to 30 letters, numbers or underscores.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(hintText: 'Email'),
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t)) return 'Enter a valid email address.';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: _obscure,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  hintText: 'Password (at least 10 characters)',
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, color: AppTheme.onSurfaceMuted),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) {
                  final len = (v ?? '').length;
                  if (len < 10) return 'Use a password of at least 10 characters.';
                  if (len > 256) return 'Passwords can be at most 256 characters.';
                  return null;
                },
                onFieldSubmitted: (_) => _register(),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loading ? null : _register,
                child: _loading
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Create account'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
