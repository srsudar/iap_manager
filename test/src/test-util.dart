import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

class TestUtil {
  /// Note that if you're calling this in a testWidgets context, you will
  /// need to call it via something like:
  ///   await tester.runAsync<bool>(
  //       () => TestUtil.waitUntilTrue(() => mockedMgr.isLoaded),
  //       additionalTime: Duration(seconds: 5));
  static Future<bool> waitUntilTrue(bool Function() callback,
      {WidgetTester tester,
      Duration timeout: const Duration(seconds: 2),
      Duration pollInterval: const Duration(milliseconds: 50)}) {
    var completer = new Completer<bool>();

    var started = DateTime.now();

    poll() async {
      var now = DateTime.now();
      if (now.difference(started) >= timeout) {
        completer.completeError(Exception('timed out in waitUntilTrue'));
        return;
      }
      if (callback()) {
        completer.complete(true);
      } else {
        if (tester != null) {
          await tester
              .runAsync(() => Future.delayed(pollInterval, () => poll()));
        } else {
          new Timer(pollInterval, () async {
            await poll();
          });
        }
      }
    }

    poll();
    return completer.future;
  }
}
