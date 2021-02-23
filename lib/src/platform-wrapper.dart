import 'dart:io';

/// Wrapper around Platform to enable stubbing for testing. Without this, we
/// can't easily use Platform.isAndroid, eg, in classes because it would
/// break on tests where we are typically on macos.
class PlatformWrapper {
  bool get isAndroid => Platform.isAndroid;
  bool get isIOS => Platform.isIOS;
  bool get isMacOS => Platform.isMacOS;
  bool get isFuchsia => Platform.isFuchsia;
  bool get isLinux => Platform.isLinux;
  bool get isWindows => Platform.isWindows;
  String get operatingSystem => Platform.operatingSystem;

  static PlatformWrapper android() => _PlatformWrapperAndroid();
  static PlatformWrapper ios() => _PlatformWrapperIOS();
}

class _PlatformWrapperAndroid implements PlatformWrapper {
  bool get isAndroid => true;
  bool get isIOS => false;
  bool get isMacOS => false;
  bool get isFuchsia => false;
  bool get isLinux => false;
  bool get isWindows => false;
  String get operatingSystem => 'android';
}

class _PlatformWrapperIOS implements PlatformWrapper {
  bool get isAndroid => false;
  bool get isIOS => true;
  bool get isMacOS => false;
  bool get isFuchsia => false;
  bool get isLinux => false;
  bool get isWindows => false;
  String get operatingSystem => 'ios';
}
