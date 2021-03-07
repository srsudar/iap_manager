import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_inapp_purchase/modules.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iap_manager/iap_manager.dart';
import 'package:mockito/mockito.dart';

class MockPluginWrapper extends Mock implements IAPPlugin3PWrapper {}

class MockPurchasedItem extends Mock implements PurchasedItem {}

class MockPurchaseResult extends Mock implements PurchaseResult {}

class MockIAPItem extends Mock implements IAPItem {}

class MockResponse extends Mock implements http.Response {}

/// A matcher that matches the OWNED value.
const Matcher isOwned = _IsOwned();

/// A matcher that matches the NOT_OWNED value.
const Matcher isNotOwned = _IsNotOwned();

/// A matcher that matches the UNKNOWN value.
const Matcher isUnknown = _IsUnknown();

class _IsOwned extends Matcher {
  const _IsOwned();
  @override
  bool matches(item, Map matchState) => item == OwnedState.OWNED;
  @override
  Description describe(Description description) => description.add('OWNED');
}

class _IsNotOwned extends Matcher {
  const _IsNotOwned();
  @override
  bool matches(item, Map matchState) => item == OwnedState.NOT_OWNED;
  @override
  Description describe(Description description) => description.add('NOT_OWNED');
}

class _IsUnknown extends Matcher {
  const _IsUnknown();
  @override
  bool matches(item, Map matchState) => item == OwnedState.UNKNOWN;
  @override
  Description describe(Description description) => description.add('UNKNOWN');
}

abstract class PurchaseSKUs {
  String getRemoveAdsForever();
  String getRemoveAdsOneYear();
}

class PurchaseSKUsAndroid implements PurchaseSKUs {
  String getRemoveAdsForever() => 'remove_ads_onetime';
  String getRemoveAdsOneYear() => 'remove_ads_oneyear';
}

class PurchaseSKUsIOS implements PurchaseSKUs {
  String getRemoveAdsForever() => 'remove_ads_onetime';
  String getRemoveAdsOneYear() => 'remove_ads_oneyear';
}

class TestStoreState extends StateFromStore {
  final bool initialShouldShowAds;
  final InAppProduct noAdsForever;
  final InAppProduct noAdsOneYear;

  TestStoreState(this.initialShouldShowAds, this.noAdsForever,
      this.noAdsOneYear, PurchaseResult lastError)
      : super(lastError);

  static TestStoreState defaultState(
      bool initialShouldShowAds, PlatformWrapper platformWrapper) {
    if (platformWrapper.isIOS) {
      PurchaseSKUs ios = PurchaseSKUsIOS();
      InAppProduct noAdsForever =
          InAppProduct.defaultSate(ios.getRemoveAdsForever());
      InAppProduct noAdsOneYear =
          InAppProduct.defaultSate(ios.getRemoveAdsOneYear());
      return TestStoreState(
          initialShouldShowAds, noAdsForever, noAdsOneYear, null);
    }

    PurchaseSKUs android = PurchaseSKUsAndroid();
    InAppProduct noAdsForever =
        InAppProduct.defaultSate(android.getRemoveAdsForever());
    InAppProduct noAdsOneYear =
        InAppProduct.defaultSate(android.getRemoveAdsOneYear());
    TestStoreState androidState =
        TestStoreState(initialShouldShowAds, noAdsForever, noAdsOneYear, null);
    if (platformWrapper.isAndroid) {
      return androidState;
    }
    debugPrint('unrecognized platform: ${platformWrapper.operatingSystem}');
    return androidState;
  }

  /// True if there is something related to products to display. Just a
  /// convenience method to avoid callers having to check null on member
  /// variables.
  bool hasPurchaseState() {
    return noAdsForever != null && noAdsOneYear != null;
  }

  /// True if details have been retrieved from the store. Store details
  /// provide descriptions and titles, so if this is false then we can't
  /// really display anything.
  bool canDisplay() {
    return noAdsForever.canDisplay() || noAdsOneYear.canDisplay();
  }

  StateFromStore dismissError() {
    return TestStoreState(
        initialShouldShowAds, noAdsForever, noAdsOneYear, null);
  }

  /// Return true if we should show ads. Will return previous state if the ad
  /// state can't be determined by this state alone (eg if purchases have
  /// not yet been fetched.
  bool shouldShowAds() {
    if (noAdsForever.isOwned() || noAdsOneYear.isOwned()) {
      // We own either, so it's ok to return false.
      return false;
    }
    if (noAdsForever.isNotOwned() && noAdsOneYear.isNotOwned()) {
      // We know neither is owned;
      return true;
    }
    if (noAdsForever.isUnknownPurchaseState() ||
        noAdsOneYear.isUnknownPurchaseState()) {
      return initialShouldShowAds;
    }

    // This is an error state.
    debugPrint('impossible ownership state: $noAdsForever, $noAdsOneYear');
    return initialShouldShowAds;
  }

  StateFromStore takeAvailableProduct(IAPItem item) {
    if (item.productId == noAdsForever?.sku) {
      InAppProduct updated = noAdsForever.withProductInfo(item);
      return TestStoreState(
          initialShouldShowAds, updated, noAdsOneYear, lastError);
    }
    if (item.productId == noAdsOneYear?.sku) {
      InAppProduct updated = noAdsOneYear.withProductInfo(item);
      return TestStoreState(
          initialShouldShowAds, noAdsForever, updated, lastError);
    }
    debugPrint('unrecognized item from store: ${item?.productId}');
    return TestStoreState(
        initialShouldShowAds, noAdsForever, noAdsOneYear, lastError);
  }

  StateFromStore takePurchase(PurchasedItem item, {String errMsg = ''}) {
    return _updatePurchaseState(item, OwnedState.OWNED, errMsg);
  }

  StateFromStore removePurchase(PurchasedItem item, {String errMsg = ''}) {
    return _updatePurchaseState(item, OwnedState.NOT_OWNED, errMsg);
  }

  StateFromStore takePurchaseUnknown(PurchasedItem item, {String errMsg = ''}) {
    return _updatePurchaseState(item, OwnedState.UNKNOWN, errMsg);
  }

  /// This is used for setting purchases in a known not purchased state.
  StateFromStore setNotOwnedExcept(Set<String> ignoreTheseIDs) {
    TestStoreState result = TestStoreState(
        initialShouldShowAds, noAdsForever, noAdsOneYear, lastError);
    if (noAdsForever != null && !ignoreTheseIDs.contains(noAdsForever.sku)) {
      // Then we don't own this.
      InAppProduct updated =
          noAdsForever.withOwnedState(OwnedState.NOT_OWNED, '');
      result = TestStoreState(
          initialShouldShowAds, updated, result.noAdsOneYear, result.lastError);
    }
    if (noAdsOneYear != null && !ignoreTheseIDs.contains(noAdsOneYear.sku)) {
      InAppProduct updated =
          noAdsOneYear.withOwnedState(OwnedState.NOT_OWNED, '');
      result = TestStoreState(
          initialShouldShowAds, result.noAdsForever, updated, result.lastError);
    }

    return result;
  }

  StateFromStore _updatePurchaseState(
      PurchasedItem item, OwnedState owned, String errMsg) {
    if (noAdsForever != null && item.productId == noAdsForever.sku) {
      // Nothing changes except the purchase state.
      InAppProduct updated = noAdsForever.withOwnedState(owned, errMsg);
      return TestStoreState(
          initialShouldShowAds, updated, noAdsOneYear, lastError);
    }
    if (noAdsOneYear != null && item.productId == noAdsOneYear.sku) {
      InAppProduct updated = noAdsOneYear.withOwnedState(owned, errMsg);
      return TestStoreState(
          initialShouldShowAds, noAdsForever, updated, lastError);
    }
    debugPrint('unrecognized item from store: ${item?.productId}');
    return TestStoreState(
        initialShouldShowAds, noAdsForever, noAdsOneYear, lastError);
  }

  StateFromStore takeError(PurchaseResult result) {
    return TestStoreState(
        initialShouldShowAds, noAdsForever, noAdsOneYear, result);
  }

  @override
  String toString() {
    return 'StateFromStore{noAdsForever: $noAdsForever, noAdsOneYear: $noAdsOneYear, lastError: $lastError}';
  }

  @override
  List<String> getNonConsumableProductIDs() {
    return [
      'remove_ads_onetime',
    ];
  }

  @override
  List<String> getSubscriptionProductIDs() {
    return [
      'remove_ads_oneyear',
    ];
  }
}

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
