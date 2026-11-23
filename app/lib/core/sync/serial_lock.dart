import 'dart:async';

class SerialLock {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() task) {
    final result = Completer<T>();
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    previous.whenComplete(() async {
      try {
        result.complete(await task());
      } catch (e, st) {
        result.completeError(e, st);
      } finally {
        done.complete();
      }
    });
    return result.future;
  }
}
