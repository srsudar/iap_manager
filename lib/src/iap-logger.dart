import 'package:flutter/cupertino.dart';

class IAPPrinter {
  void printInRelease(String msg) {
    print(msg);
  }

  void printInDebug(String msg) {
    debugPrint(msg);
  }
}

class IAPLogger {
  final String _prefix;
  final bool _logInReleaseMode;
  final IAPPrinter _printer;

  IAPLogger(this._prefix, this._logInReleaseMode, {IAPPrinter printer})
      : _printer = printer ?? IAPPrinter();

  void maybeLog(String msg) {
    if (_logInReleaseMode) {
      _printer.printInRelease('$_prefix: $msg');
    } else {
      _printer.printInDebug('$_prefix: $msg');
    }
  }
}
