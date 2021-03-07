import 'package:flutter_test/flutter_test.dart';
import 'package:iap_manager/src/iap-logger.dart';

class _TestPrinter extends IAPPrinter {
  final List<String> release = [];
  final List<String> debug = [];

  @override
  void printInRelease(String msg) {
    release.add(msg);
  }

  @override
  void printInDebug(String msg) {
    debug.add(msg);
  }
}

void main() {
  test('log in release mode', () {
    _TestPrinter printer = _TestPrinter();
    IAPLogger logger = IAPLogger(
      'foo',
      true,
      printer: printer,
    );

    logger.maybeLog('one');
    logger.maybeLog('two');

    expect(printer.release.length, equals(2));
    expect(printer.debug.length, equals(0));

    expect(printer.release[0], equals('foo: one'));
    expect(printer.release[1], equals('foo: two'));
  });

  test('log in debug mode', () {
    _TestPrinter printer = _TestPrinter();
    IAPLogger logger = IAPLogger(
      'bar',
      false,
      printer: printer,
    );

    logger.maybeLog('one');
    logger.maybeLog('two');

    expect(printer.release.length, equals(0));
    expect(printer.debug.length, equals(2));

    expect(printer.debug[0], equals('bar: one'));
    expect(printer.debug[1], equals('bar: two'));
  });
}
