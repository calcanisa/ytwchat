class AppConfig {
  static const String apiUrl = String.fromEnvironment(
    'YTWCHAT_API_URL',
    defaultValue: 'http://10.0.2.2:8101',
  );

  static const bool isRelease = bool.fromEnvironment('dart.vm.product');

  static const int maxMediaBytes = 60 * 1024 * 1024;
  static const int maxTextLength = 20000;
  static const int keyPackageTarget = 60;
  static const int keyPackageLowWater = 25;

  static void assertSecure(String url) {
    if (isRelease && !url.startsWith('https://')) {
      throw StateError('Release builds must use an https API address.');
    }
  }

  static String apiBase(String url) => '${_trim(url)}/v1';

  static Uri wsUri(String url) {
    final base = Uri.parse(_trim(url));
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/v1/ws',
    );
  }

  static String _trim(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
