import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iap_manager/iap_manager.dart';
import 'package:iap_manager/src/platform-wrapper.dart';
import 'package:mockito/mockito.dart';

import 'test-util.dart';

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

class _SubValidationFailsTestCase {
  final String label;
  final int respCode;
  final String respBody;
  final bool jsonShouldParse;
  // We're only including this to make sure we don't mess up the test case
  // without realizing it.
  final bool wantShowAds;
  final bool shouldHaveErrorMsg;
  final OwnedState wantOwnedState;

  _SubValidationFailsTestCase({
    this.label,
    this.respCode,
    this.respBody,
    this.jsonShouldParse,
    this.wantShowAds,
    this.shouldHaveErrorMsg,
    this.wantOwnedState,
  });
}

class _MockedIAPItems {
  IAPItem forLife;
  IAPItem forOneYear;

  _MockedIAPItems() {
    forLife = MockIAPItem();
    when(forLife.productId).thenReturn('remove_ads_onetime');
    when(forLife.title).thenReturn('Title One Time');
    when(forLife.description).thenReturn('Description One Time');

    forOneYear = MockIAPItem();
    when(forOneYear.productId).thenReturn('remove_ads_oneyear');
    when(forOneYear.title).thenReturn('Title One Year');
    when(forOneYear.description).thenReturn('Description One Year');
  }
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
  final InAppProduct noAdsForever;
  final InAppProduct noAdsOneYear;
  final PurchaseResult lastError;

  TestStoreState(this.noAdsForever, this.noAdsOneYear, this.lastError)
      : super(lastError);

  static TestStoreState defaultState(PlatformWrapper platformWrapper) {
    if (platformWrapper.isIOS) {
      PurchaseSKUs ios = PurchaseSKUsIOS();
      InAppProduct noAdsForever =
          InAppProduct.defaultSate(ios.getRemoveAdsForever());
      InAppProduct noAdsOneYear =
          InAppProduct.defaultSate(ios.getRemoveAdsOneYear());
      return TestStoreState(noAdsForever, noAdsOneYear, null);
    }

    PurchaseSKUs android = PurchaseSKUsAndroid();
    InAppProduct noAdsForever =
        InAppProduct.defaultSate(android.getRemoveAdsForever());
    InAppProduct noAdsOneYear =
        InAppProduct.defaultSate(android.getRemoveAdsOneYear());
    TestStoreState androidState =
        TestStoreState(noAdsForever, noAdsOneYear, null);
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
    return TestStoreState(noAdsForever, noAdsOneYear, null);
  }

  /// Return true if we should show ads. Will return previous state if the ad
  /// state can't be determined by this state alone (eg if purchases have
  /// not yet been fetched.
  bool shouldShowAds(bool previousState) {
    if (noAdsForever.isOwned() || noAdsOneYear.isOwned()) {
      // We own either, so it's ok to return false.
      return false;
    }
    if (noAdsForever.isNotOwned() && noAdsOneYear.isNotOwned()) {
      // We know either is owned;
      return true;
    }
    if (noAdsForever.isUnknownPurchaseState() ||
        noAdsOneYear.isUnknownPurchaseState()) {
      return previousState;
    }

    // This is an error state.
    debugPrint('impossible ownership state: $noAdsForever, $noAdsOneYear');
    return previousState;
  }

  StateFromStore takeAvailableProduct(IAPItem item) {
    if (item.productId == noAdsForever?.sku) {
      InAppProduct updated = noAdsForever.withProductInfo(item);
      return TestStoreState(updated, noAdsOneYear, lastError);
    }
    if (item.productId == noAdsOneYear?.sku) {
      InAppProduct updated = noAdsOneYear.withProductInfo(item);
      return TestStoreState(noAdsForever, updated, lastError);
    }
    debugPrint('unrecognized item from store: ${item?.productId}');
    return TestStoreState(noAdsForever, noAdsOneYear, lastError);
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
    TestStoreState result =
        TestStoreState(noAdsForever, noAdsOneYear, lastError);
    if (noAdsForever != null && !ignoreTheseIDs.contains(noAdsForever.sku)) {
      // Then we don't own this.
      InAppProduct updated =
          noAdsForever.withOwnedState(OwnedState.NOT_OWNED, '');
      result = TestStoreState(updated, result.noAdsOneYear, result.lastError);
    }
    if (noAdsOneYear != null && !ignoreTheseIDs.contains(noAdsOneYear.sku)) {
      InAppProduct updated =
          noAdsOneYear.withOwnedState(OwnedState.NOT_OWNED, '');
      result = TestStoreState(result.noAdsForever, updated, result.lastError);
    }

    return result;
  }

  StateFromStore _updatePurchaseState(
      PurchasedItem item, OwnedState owned, String errMsg) {
    if (noAdsForever != null && item.productId == noAdsForever.sku) {
      // Nothing changes except the purchase state.
      InAppProduct updated = noAdsForever.withOwnedState(owned, errMsg);
      return TestStoreState(updated, noAdsOneYear, lastError);
    }
    if (noAdsOneYear != null && item.productId == noAdsOneYear.sku) {
      InAppProduct updated = noAdsOneYear.withOwnedState(owned, errMsg);
      return TestStoreState(noAdsForever, updated, lastError);
    }
    debugPrint('unrecognized item from store: ${item?.productId}');
    return TestStoreState(noAdsForever, noAdsOneYear, lastError);
  }

  StateFromStore takeError(PurchaseResult result) {
    return TestStoreState(noAdsForever, noAdsOneYear, result);
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

// The worst case scenario for ads is if we've saved not showing ads, and
// something goes wrong where we show ads. We want to prevent that. This is
// basically what would happen if someone pays to remove ads then can't
// connect to the internet or something and we show them ads. Or I make an
// error in an update and we show them ads.
//
// Here are the cases we care about. Start not showing ads, and then:
//   1. error in initConnection
//   2. error in getPurchaseHistory
//   3. error in getAvailableProducts
//
// I think these are covered in the various cases below.
void main() {
  test('initialize happy path', () async {
    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    // Init the connection.
    var initResult = Completer<String>();

    when(plugin.initConnection()).thenAnswer((_) => initResult.future);

    // Handle the purchase and error streams.
    StreamController<PurchasedItem> purchaseUpdatedStream =
        StreamController<PurchasedItem>();
    StreamController<PurchaseResult> purchaseErrorStream =
        StreamController<PurchaseResult>();

    when(plugin.getPurchaseUpdatedStream())
        .thenAnswer((_) => purchaseUpdatedStream.stream);
    when(plugin.getPurchaseErrorStream())
        .thenAnswer((_) => purchaseErrorStream.stream);

    // getPurchaseHistory. We'll use an acked item so that we don't have to
    // worry about finalizing transactions.
    PurchasedItem alreadyAckedAndroid = MockPurchasedItem();
    when(alreadyAckedAndroid.transactionId)
        .thenReturn('android-txn-id-already-acked');
    when(alreadyAckedAndroid.purchaseStateAndroid)
        .thenReturn(PurchaseState.purchased);
    when(alreadyAckedAndroid.productId).thenReturn('remove_ads_onetime');
    when(alreadyAckedAndroid.isAcknowledgedAndroid).thenReturn(true);

    var pluginGetPurchaseHistoryResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory())
        .thenAnswer((_) => pluginGetPurchaseHistoryResult.future);

    var products = Completer<List<IAPItem>>();
    var subs = Completer<List<IAPItem>>();

    when(plugin.getProducts(any)).thenAnswer((_) => products.future);
    when(plugin.getSubscriptions(any))
        .thenAnswer((realInvocation) => subs.future);

    // let it begin...
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      true,
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    // And now, while we're still blocked on initConnection, add some
    // completers.
    var blockForPurchases = Completer<void>();
    var blockForProducts = Completer<void>();
    mgr.setBlockForTestingAfterInitializeGetPurchaseHistory(
        blockForPurchases.future);
    mgr.setBlockForTestingAfterGetAvailableProducts(blockForProducts.future);

    initResult.complete('cxn is live');
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    pluginGetPurchaseHistoryResult.complete([alreadyAckedAndroid]);

    // What we want to do here is a bit to make sure that the async call
    // completes. Kind of an ugly way to do this, but I'm not sure how else
    // we do it...
    await TestUtil.waitUntilTrue(() {
      return mgr.storeState.noAdsForever.isOwned();
    });

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isFalse);

    blockForPurchases.complete();

    // getAvailableProducts
    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    subs.complete([items.forOneYear]);

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isFalse);

    blockForProducts.complete();

    await mgr.waitForInitialized();

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(mgr.shouldShowAds, isFalse);

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
  });

  test('initialize getProducts succeeds, purchaseHistory errors', () async {
    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    // Init the connection.
    var initResult = Completer<String>();

    when(plugin.initConnection()).thenAnswer((_) => initResult.future);

    // Handle the purchase and error streams.
    StreamController<PurchasedItem> purchaseUpdatedStream =
        StreamController<PurchasedItem>();
    StreamController<PurchaseResult> purchaseErrorStream =
        StreamController<PurchaseResult>();

    when(plugin.getPurchaseUpdatedStream())
        .thenAnswer((_) => purchaseUpdatedStream.stream);
    when(plugin.getPurchaseErrorStream())
        .thenAnswer((_) => purchaseErrorStream.stream);

    // we want this to error.
    var pluginGetPurchaseHistoryResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory())
        .thenAnswer((_) => pluginGetPurchaseHistoryResult.future);

    // getAvailableProducts
    _MockedIAPItems items = _MockedIAPItems();
    when(plugin.getProducts(any)).thenAnswer((_) async {
      return [items.forLife];
    });
    when(plugin.getSubscriptions(any)).thenAnswer((_) async {
      return [items.forOneYear];
    });

    // We start NOT showing ads. This should stay the same, b/c we haven't
    // been able to fetch purchase information.
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      false,
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isFalse);

    initResult.complete('cxn is live');
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isFalse);

    pluginGetPurchaseHistoryResult
        .completeError(Exception('getPurchaseHistory error'));

    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.hasFetchedPurchases, isFalse);
    expect(mgr.shouldShowAds, isFalse);

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(mgr.storeState.noAdsForever.owned, isUnknown);
    expect(mgr.storeState.noAdsOneYear.owned, isUnknown);
    expect(mgr.pluginErrorMsg, contains('getPurchaseHistory error'));
  });

  test('initialize getProducts errors, purchaseHistory succeeds', () async {
    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    // Init the connection.
    var initResult = Completer<String>();

    when(plugin.initConnection()).thenAnswer((_) => initResult.future);

    // Handle the purchase and error streams.
    StreamController<PurchasedItem> purchaseUpdatedStream =
        StreamController<PurchasedItem>();
    StreamController<PurchaseResult> purchaseErrorStream =
        StreamController<PurchaseResult>();

    when(plugin.getPurchaseUpdatedStream())
        .thenAnswer((_) => purchaseUpdatedStream.stream);
    when(plugin.getPurchaseErrorStream())
        .thenAnswer((_) => purchaseErrorStream.stream);

    // getPurchaseHistory. We'll use an acked item so that we don't have to
    // worry about finalizing transactions.
    PurchasedItem alreadyAckedAndroid = MockPurchasedItem();
    when(alreadyAckedAndroid.transactionId)
        .thenReturn('android-txn-id-already-acked');
    when(alreadyAckedAndroid.purchaseStateAndroid)
        .thenReturn(PurchaseState.purchased);
    when(alreadyAckedAndroid.productId).thenReturn('remove_ads_onetime');
    when(alreadyAckedAndroid.isAcknowledgedAndroid).thenReturn(true);

    var pluginGetPurchaseHistoryResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory())
        .thenAnswer((_) => pluginGetPurchaseHistoryResult.future);

    when(plugin.getProducts(any)).thenAnswer((_) async {
      throw Exception('getProducts error');
    });
    when(plugin.getSubscriptions(any)).thenAnswer((realInvocation) async {
      return [];
    });

    // let it begin...
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      true,
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    initResult.complete('cxn is live');

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    pluginGetPurchaseHistoryResult.complete([alreadyAckedAndroid]);

    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.shouldShowAds, isFalse);
    expect(mgr.hasFetchedPurchases, isTrue);

    // Both of these are empty b/c we couldn't get the deets from the store.
    expect(mgr.storeState.noAdsForever.getTitle(), equals(''));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals(''));
    expect(mgr.storeState.noAdsForever.owned, isOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.pluginErrorMsg, contains('getProducts error'));
  });

  test('initialize initConnection error', () async {
    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    // Init the connection.
    var initResult = Completer<String>();

    // We only want one call.
    int numTimesCalledInit = 0;
    when(plugin.initConnection()).thenAnswer((_) {
      if (numTimesCalledInit++ == 0) {
        return initResult.future;
      }
      throw Exception('init called more than once');
    });

    // We want to throw errors on these, b/c they can't be called unless the
    // connection has been initialized. The plugin throws an error otherwise.
    when(plugin.getPurchaseHistory()).thenAnswer(
        (realInvocation) => throw Exception('called get purchase history'));
    when(plugin.getProducts(any))
        .thenAnswer((realInvocation) => throw Exception('called getProducts'));
    when(plugin.requestPurchase(any)).thenAnswer(
        (realInvocation) => throw Exception('called requestPurchase'));

    // let it begin...
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      false,
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isFalse);

    initResult.completeError(Exception('error init cxn'));

    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.shouldShowAds, isFalse);

    expect(mgr.pluginErrorMsg, contains('error init cxn'));

    // And now make sure that calling our other methods doesn't cause a
    // problem. We should be smart enough to not do anything with this if
    // there is a problem.
    await mgr.getPurchaseHistory(true);
    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedPurchases, isFalse);
    expect(mgr.shouldShowAds, isFalse);
    expect(mgr.pluginErrorMsg, contains('error init cxn'));

    await mgr.getAvailableProducts(true);
    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedAvailableProducts, isFalse);
    expect(mgr.shouldShowAds, isFalse);
    expect(mgr.pluginErrorMsg, contains('error init cxn'));

    mgr.requestPurchase('fake-id');
    expect(mgr.isLoaded, isTrue);
    expect(mgr.shouldShowAds, isFalse);
    expect(mgr.pluginErrorMsg, contains('error init cxn'));
  });

  // test('reinits if connection goes dead', () async {
  //   // Maybe should be careful here in handling interleaving calls even? Eg
  //   // call products, still running, and then the next call cancels.
  //   expect(true, isFalse);
  // });

  test('getPurchaseHistory() android: null transactionId', () async {
    PurchasedItem shouldIgnoreNullId = MockPurchasedItem();
    when(shouldIgnoreNullId.transactionId).thenReturn(null);
    when(shouldIgnoreNullId.purchaseStateAndroid)
        .thenReturn(PurchaseState.purchased);
    when(shouldIgnoreNullId.productId).thenReturn('remove_ads_onetime');

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    bool calledFinishTransaction = false;

    when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
      calledFinishTransaction = true;
      return 'acked';
    });

    List<PurchasedItem> purchases = [
      shouldIgnoreNullId,
    ];

    var pluginResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory()).thenAnswer((_) => pluginResult.future);

    // Start showing ads, then make sure we stop showing ads once we have
    // purchases.
    IAPManager<TestStoreState> mgr =
        IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      true,
      PlatformWrapper.android(),
    );

    expect(mgr.isLoaded, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    Future<void> result = mgr.getPurchaseHistory(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getPurchaseHistory with our items.
    pluginResult.complete(purchases);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedPurchases, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.shouldShowAds, isTrue);

    expect(calledFinishTransaction, isFalse);
  });

  test('getPurchaseHistory() android: purchased and acked', () async {
    PurchasedItem acked = MockPurchasedItem();
    when(acked.transactionId).thenReturn('txn-id');
    when(acked.purchaseStateAndroid).thenReturn(PurchaseState.purchased);
    when(acked.isAcknowledgedAndroid).thenReturn(true);
    when(acked.productId).thenReturn('remove_ads_oneyear');

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    bool calledFinishTransaction = false;

    when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
      var purchasedItem = realInvocation.positionalArguments[0];
      if (purchasedItem.transactionId == 'txn-id') {
        calledFinishTransaction = true;
        return 'android-result';
      }
      throw new Exception(
          'unrecognized transaction id: ${purchasedItem.transactionId}');
    });

    List<PurchasedItem> purchases = [
      acked,
    ];

    var pluginResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory()).thenAnswer((_) => pluginResult.future);

    // Start showing ads, then make sure we stop showing ads once we have
    // purchases.
    IAPManager<TestStoreState> mgr =
        IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      true,
      PlatformWrapper.android(),
    );

    expect(mgr.isLoaded, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    Future<void> result = mgr.getPurchaseHistory(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getPurchaseHistory with our items.
    pluginResult.complete(purchases);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedPurchases, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isOwned);
    expect(mgr.shouldShowAds, isFalse);

    expect(calledFinishTransaction, isFalse);
  });

  test('getPurchaseHistory() android: purchased, needs ack', () async {
    PurchasedItem needsAck = MockPurchasedItem();
    when(needsAck.transactionId).thenReturn('txn-id');
    when(needsAck.purchaseStateAndroid).thenReturn(PurchaseState.purchased);
    when(needsAck.isAcknowledgedAndroid).thenReturn(false);
    when(needsAck.productId).thenReturn('remove_ads_onetime');

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    bool calledFinishTransaction = false;

    when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
      var purchasedItem = realInvocation.positionalArguments[0];
      if (purchasedItem.transactionId == 'txn-id') {
        calledFinishTransaction = true;
        return 'android-result';
      }
      throw new Exception(
          'unrecognized transaction id: ${purchasedItem.transactionId}');
    });

    List<PurchasedItem> purchases = [
      needsAck,
    ];

    var pluginResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory()).thenAnswer((_) => pluginResult.future);

    // Start showing ads, then make sure we stop showing ads once we have
    // purchases.
    IAPManager<TestStoreState> mgr =
        IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      true,
      PlatformWrapper.android(),
    );

    expect(mgr.isLoaded, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    Future<void> result = mgr.getPurchaseHistory(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getPurchaseHistory with our items.
    pluginResult.complete(purchases);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedPurchases, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.shouldShowAds, isFalse);

    expect(calledFinishTransaction, isTrue);
  });

  test('getPurchaseHistory() ios: purchased', () async {
    PurchasedItem purchased = MockPurchasedItem();
    when(purchased.transactionId).thenReturn('txn-id');
    when(purchased.transactionStateIOS).thenReturn(TransactionState.purchased);
    when(purchased.productId).thenReturn('remove_ads_onetime');

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    bool calledFinish = false;

    when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
      var purchasedItem = realInvocation.positionalArguments[0];
      if (purchasedItem.transactionId == 'txn-id') {
        calledFinish = true;
        return 'ios-result';
      }
      throw new Exception(
          'unrecognized transaction id: ${purchasedItem.transactionId}');
    });

    List<PurchasedItem> purchases = [
      purchased,
    ];

    var pluginResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory()).thenAnswer((_) => pluginResult.future);

    // Start showing ads, then make sure we stop showing ads once we have
    // purchases.
    IAPManager<TestStoreState> mgr =
        IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.ios()),
      true,
      PlatformWrapper.ios(),
    );

    expect(mgr.isLoaded, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    Future<void> result = mgr.getPurchaseHistory(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getPurchaseHistory with our items.
    pluginResult.complete(purchases);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedPurchases, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.shouldShowAds, isFalse);

    expect(calledFinish, isTrue);
  });

  test('getPurchaseHistory() ios: purchasing', () async {
    PurchasedItem purchasing = MockPurchasedItem();
    when(purchasing.transactionId).thenReturn('txn-id');
    when(purchasing.transactionStateIOS)
        .thenReturn(TransactionState.purchasing);
    when(purchasing.productId).thenReturn('remove_ads_onetime');

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    bool calledFinish = false;

    when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
      var purchasedItem = realInvocation.positionalArguments[0];
      if (purchasedItem.transactionId == 'txn-id') {
        calledFinish = true;
        return 'ios-result';
      }
      throw new Exception(
          'unrecognized transaction id: ${purchasedItem.transactionId}');
    });

    List<PurchasedItem> purchases = [
      purchasing,
    ];

    var pluginResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory()).thenAnswer((_) => pluginResult.future);

    // Start showing ads, then make sure we stop showing ads once we have
    // purchases.
    IAPManager<TestStoreState> mgr =
        IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.ios()),
      true,
      PlatformWrapper.ios(),
    );

    expect(mgr.isLoaded, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    Future<void> result = mgr.getPurchaseHistory(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getPurchaseHistory with our items.
    pluginResult.complete(purchases);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedPurchases, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.shouldShowAds, isTrue);

    expect(calledFinish, isFalse);
  });

  test('getPurchaseHistory() ios: purchased subs', () async {
    PurchasedItem sub1 = MockPurchasedItem();
    when(sub1.transactionId).thenReturn('txn-id-1');
    when(sub1.transactionStateIOS).thenReturn(TransactionState.purchased);
    when(sub1.productId).thenReturn('remove_ads_oneyear');
    when(sub1.transactionReceipt).thenReturn('sub1-txn-receipt');

    PurchasedItem sub2 = MockPurchasedItem();
    when(sub2.transactionId).thenReturn('txn-id-2');
    when(sub2.transactionStateIOS).thenReturn(TransactionState.purchased);
    when(sub2.productId).thenReturn('remove_ads_oneyear');
    when(sub2.transactionReceipt).thenReturn('sub2-txn-receipt');

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    bool calledFinishSub1 = false;
    bool calledFinishSub2 = false;

    when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
      var purchasedItem = realInvocation.positionalArguments[0];
      if (purchasedItem.transactionId == 'txn-id-1') {
        calledFinishSub1 = true;
        return 'ios-result-1';
      }
      if (purchasedItem.transactionId == 'txn-id-2') {
        calledFinishSub2 = true;
        return 'ios-result-2';
      }
      throw new Exception(
          'unrecognized transaction id: ${purchasedItem.transactionId}');
    });

    // We're going to behave as if this is a sandbox purchase, b/c we don't
    // know until we get a response from the server (and therefore we're not
    // testing the implementation over the API TOO much), and also this is
    // the most natural place to ensure we call it twice.
    int numTimesValidateTxn = 0;
    when(plugin.validateTransactionIOS(any, any))
        .thenAnswer((realInvocation) async {
      numTimesValidateTxn++;
      Map<String, dynamic> reqBody = realInvocation.positionalArguments[0];
      String txnReceipt = reqBody['receipt-data'] as String;
      String pwd = reqBody['password'] as String;
      String exclude = reqBody['exclude-old-transactions'] as String;

      if (txnReceipt != 'sub1-txn-receipt' &&
          txnReceipt != 'sub2-txn-receipt') {
        throw Exception('unrecognized txn receipt: $txnReceipt');
      }

      if (pwd != 'app-secret-key') {
        throw Exception('unrecognized password: $pwd');
      }

      if (exclude != 'true') {
        // afaict a string true is all that's accepted.
        throw Exception('we should be exlucding old txns: $exclude');
      }

      bool useSandbox = realInvocation.positionalArguments[1];
      http.Response resp = MockResponse();
      when(resp.statusCode).thenReturn(200);
      if (!useSandbox) {
        // We return a magic status here.
        when(resp.body).thenReturn('{"status":21007}');
      } else {
        String rawBody = '{"status":0, "pending_renewal_info": [ { "original_'
            'transaction_id": "foo" } ] }';
        when(resp.body).thenReturn(rawBody);
      }
      return resp;
    });

    // On iOS subs come via purchases.
    List<PurchasedItem> purchases = [
      sub1,
      sub2,
    ];

    var pluginResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory()).thenAnswer((_) => pluginResult.future);

    // Start showing ads, then make sure we stop showing ads once we have
    // purchases.
    IAPManager<TestStoreState> mgr =
        IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
      plugin,
      'app-secret-key',
      TestStoreState.defaultState(PlatformWrapper.ios()),
      true,
      PlatformWrapper.ios(),
    );

    expect(mgr.isLoaded, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    Future<void> result = mgr.getPurchaseHistory(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getPurchaseHistory with our items.
    pluginResult.complete(purchases);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedPurchases, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isOwned);
    expect(mgr.shouldShowAds, isFalse);
    // We accept either, but we should only ever call once for a given batch.
    expect(numTimesValidateTxn, equals(2));

    expect(calledFinishSub1, isTrue);
    expect(calledFinishSub2, isTrue);
  });

  test('getPurchaseHistory() ios: expired subs', () async {
    PurchasedItem sub = MockPurchasedItem();
    when(sub.transactionId).thenReturn('txn-id');
    when(sub.transactionStateIOS).thenReturn(TransactionState.purchased);
    when(sub.productId).thenReturn('remove_ads_oneyear');
    when(sub.transactionReceipt).thenReturn('sub-txn-receipt');

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    bool calledFinishTxn = false;

    when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
      var purchasedItem = realInvocation.positionalArguments[0];
      if (purchasedItem.transactionId == 'txn-id') {
        calledFinishTxn = true;
        return 'ios-result';
      }
      throw new Exception(
          'unrecognized transaction id: ${purchasedItem.transactionId}');
    });

    // We're going to behave as if this is a sandbox purchase, b/c we don't
    // know until we get a response from the server (and therefore we're not
    // testing the implementation over the API TOO much), and also this is
    // the most natural place to ensure we call it twice.
    int numTimesValidateTxn = 0;
    when(plugin.validateTransactionIOS(any, any))
        .thenAnswer((realInvocation) async {
      numTimesValidateTxn++;
      Map<String, dynamic> reqBody = realInvocation.positionalArguments[0];
      String txnReceipt = reqBody['receipt-data'] as String;
      String pwd = reqBody['password'] as String;
      String exclude = reqBody['exclude-old-transactions'] as String;

      if (txnReceipt != 'sub-txn-receipt') {
        throw Exception('unrecognized txn receipt: $txnReceipt');
      }

      if (pwd != 'app-secret-key') {
        throw Exception('unrecognized password: $pwd');
      }

      if (exclude != 'true') {
        // afaict a string true is all that's accepted.
        throw Exception('we should be excluding old txns: $exclude');
      }

      bool useSandbox = realInvocation.positionalArguments[1];
      http.Response resp = MockResponse();
      when(resp.statusCode).thenReturn(200);
      if (!useSandbox) {
        // We return a magic status here.
        String rawBody = '{"status":0, "pending_renewal_info": [ { "'
            'expiration_intent": "1" } ] }';
        when(resp.body).thenReturn(rawBody);
      } else {
        throw Exception('calling sandbox, should not');
      }
      return resp;
    });

    // On iOS subs come via purchases.
    List<PurchasedItem> purchases = [
      sub,
    ];

    var pluginResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory()).thenAnswer((_) => pluginResult.future);

    // Start NOT showing ads, and make sure we remove for an expired sub.
    IAPManager<TestStoreState> mgr =
        IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
      plugin,
      'app-secret-key',
      TestStoreState.defaultState(PlatformWrapper.ios()),
      false,
      PlatformWrapper.ios(),
    );

    expect(mgr.isLoaded, isTrue);
    expect(mgr.shouldShowAds, isFalse);

    Future<void> result = mgr.getPurchaseHistory(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getPurchaseHistory with our items.
    pluginResult.complete(purchases);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedPurchases, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    // We should show ads--started without ads, expired sub removed it.
    expect(mgr.shouldShowAds, isTrue);
    // We should only call once--for prod.
    expect(numTimesValidateTxn, equals(1));

    expect(calledFinishTxn, isTrue);
  });

  test('getPurchaseHistory() ios: multiple expired subs', () async {
    // This was a case that came up in the wild and behaved strangely.
    List<PurchasedItem> subs = [];

    for (int i = 0; i < 5; i++) {
      PurchasedItem sub = MockPurchasedItem();
      when(sub.transactionId).thenReturn('txn-id-$i');
      when(sub.transactionStateIOS).thenReturn(TransactionState.purchased);
      when(sub.productId).thenReturn('remove_ads_oneyear');
      when(sub.transactionReceipt).thenReturn('sub-txn-receipt');

      subs.add(sub);
    }

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    int numTimesCalledFinish = 0;
    when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
      numTimesCalledFinish++;
      return 'ios-result';
    });

    // We're going to behave as if this is a sandbox purchase, b/c we don't
    // know until we get a response from the server (and therefore we're not
    // testing the implementation over the API TOO much), and also this is
    // the most natural place to ensure we call it twice.
    int numTimesValidateTxn = 0;
    when(plugin.validateTransactionIOS(any, any))
        .thenAnswer((realInvocation) async {
      numTimesValidateTxn++;
      Map<String, dynamic> reqBody = realInvocation.positionalArguments[0];
      String txnReceipt = reqBody['receipt-data'] as String;
      String pwd = reqBody['password'] as String;
      String exclude = reqBody['exclude-old-transactions'] as String;

      if (txnReceipt != 'sub-txn-receipt') {
        throw Exception('unrecognized txn receipt: $txnReceipt');
      }

      if (pwd != 'app-secret-key') {
        throw Exception('unrecognized password: $pwd');
      }

      if (exclude != 'true') {
        // afaict a string true is all that's accepted.
        throw Exception('we should be excluding old txns: $exclude');
      }

      bool useSandbox = realInvocation.positionalArguments[1];
      http.Response resp = MockResponse();
      when(resp.statusCode).thenReturn(200);
      if (!useSandbox) {
        // We return a magic status here.
        String rawBody = '{"status":0, "pending_renewal_info": [ { "'
            'expiration_intent": "1" } ] }';
        when(resp.body).thenReturn(rawBody);
      } else {
        throw Exception('calling sandbox, should not');
      }
      return resp;
    });

    // On iOS subs come via purchases.
    List<PurchasedItem> purchases = subs;

    var pluginResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory()).thenAnswer((_) => pluginResult.future);

    // Start NOT showing ads, and make sure we remove for an expired sub.
    IAPManager<TestStoreState> mgr =
        IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
      plugin,
      'app-secret-key',
      TestStoreState.defaultState(PlatformWrapper.ios()),
      false,
      PlatformWrapper.ios(),
    );

    expect(mgr.isLoaded, isTrue);
    expect(mgr.shouldShowAds, isFalse);

    Future<void> result = mgr.getPurchaseHistory(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getPurchaseHistory with our items.
    pluginResult.complete(purchases);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedPurchases, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    // We should show ads--started without ads, expired sub removed it.
    expect(mgr.shouldShowAds, isTrue);
    // We should only call once--for prod.
    expect(numTimesValidateTxn, equals(1));

    expect(numTimesCalledFinish, equals(5));
  });

  <_SubValidationFailsTestCase>[
    _SubValidationFailsTestCase(
      label: 'validation parses, sub is expired',
      respCode: 200,
      respBody: '{"status":0, "pending_renewal_info": [ { "'
          'expiration_intent": "1" } ] }',
      jsonShouldParse: true,
      shouldHaveErrorMsg: false,
      wantShowAds: true,
      wantOwnedState: OwnedState.NOT_OWNED,
    ),
    _SubValidationFailsTestCase(
      label: 'HTTP 404 code',
      respCode: 404,
      respBody: 'not home right now',
      jsonShouldParse: true,
      shouldHaveErrorMsg: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.UNKNOWN,
    ),
    _SubValidationFailsTestCase(
      label: 'non-ok server status',
      respCode: 200,
      respBody: '{"status":100}',
      jsonShouldParse: true,
      shouldHaveErrorMsg: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.UNKNOWN,
    ),
    _SubValidationFailsTestCase(
      label: 'bad json',
      respCode: 200,
      respBody: '{"status_is_broken',
      jsonShouldParse: false,
      shouldHaveErrorMsg: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.UNKNOWN,
    ),
    _SubValidationFailsTestCase(
      label: 'missing pending_renewal_info',
      respCode: 200,
      respBody: '{"status":0}',
      shouldHaveErrorMsg: false,
      jsonShouldParse: true,
      wantShowAds: true,
      wantOwnedState: OwnedState.NOT_OWNED,
    ),
    _SubValidationFailsTestCase(
      label: 'pending_renewal_info is string, not array',
      respCode: 200,
      respBody: '{"status":0, "pending_renewal_info": "trubs" }',
      shouldHaveErrorMsg: false,
      jsonShouldParse: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.UNKNOWN,
    ),
    _SubValidationFailsTestCase(
      label: 'pending_renewal_info is object, not array',
      respCode: 200,
      respBody: '{"status":0, "pending_renewal_info": {"cat": "dog" } }',
      shouldHaveErrorMsg: false,
      jsonShouldParse: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.UNKNOWN,
    ),
    _SubValidationFailsTestCase(
      label: 'pending_renewal_info empty array',
      respCode: 200,
      respBody: '{"status":0, "pending_renewal_info": [ ] }',
      shouldHaveErrorMsg: false,
      jsonShouldParse: true,
      wantShowAds: true,
      wantOwnedState: OwnedState.NOT_OWNED, // should be one if active
    ),
    _SubValidationFailsTestCase(
      label: 'pending_renewal_info array of wrong objs',
      respCode: 200,
      respBody: '{"status":0, "pending_renewal_info": [ { "cat": "dog" } ] }',
      shouldHaveErrorMsg: false,
      jsonShouldParse: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.OWNED, // b/c missing expired thing
    ),
  ].forEach((testCase) {
    test('SubValidationFailsTest: ${testCase.label}', () async {
      PurchasedItem sub = MockPurchasedItem();
      when(sub.transactionId).thenReturn('txn-id');
      when(sub.transactionStateIOS).thenReturn(TransactionState.purchased);
      when(sub.productId).thenReturn('remove_ads_oneyear');
      when(sub.transactionReceipt).thenReturn('sub-txn-receipt');

      IAPPlugin3PWrapper plugin = MockPluginWrapper();

      bool calledFinishTxn = false;

      when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
        var purchasedItem = realInvocation.positionalArguments[0];
        if (purchasedItem.transactionId == 'txn-id') {
          calledFinishTxn = true;
          return 'ios-result';
        }
        throw new Exception(
            'unrecognized transaction id: ${purchasedItem.transactionId}');
      });

      // We're going to behave as if this is a sandbox purchase, b/c we don't
      // know until we get a response from the server (and therefore we're not
      // testing the implementation over the API TOO much), and also this is
      // the most natural place to ensure we call it twice.
      int numTimesValidateTxn = 0;
      when(plugin.validateTransactionIOS(any, any))
          .thenAnswer((realInvocation) async {
        numTimesValidateTxn++;
        Map<String, dynamic> reqBody = realInvocation.positionalArguments[0];
        String txnReceipt = reqBody['receipt-data'] as String;
        String pwd = reqBody['password'] as String;
        String exclude = reqBody['exclude-old-transactions'] as String;

        if (txnReceipt != 'sub-txn-receipt') {
          throw Exception('unrecognized txn receipt: $txnReceipt');
        }

        if (pwd != 'app-secret-key') {
          throw Exception('unrecognized password: $pwd');
        }

        if (exclude != 'true') {
          // afaict a string true is all that's accepted.
          throw Exception('we should be excluding old txns: $exclude');
        }

        bool useSandbox = realInvocation.positionalArguments[1];
        http.Response resp = MockResponse();
        when(resp.statusCode).thenReturn(testCase.respCode);
        if (!useSandbox) {
          when(resp.body).thenReturn(testCase.respBody);
        } else {
          throw Exception('calling sandbox, should not');
        }
        return resp;
      });

      // On iOS subs come via purchases.
      List<PurchasedItem> purchases = [
        sub,
      ];

      var pluginResult = Completer<List<PurchasedItem>>();
      when(plugin.getPurchaseHistory()).thenAnswer((_) => pluginResult.future);

      // Start NOT showing ads, and make sure we remove for an expired sub.
      IAPManager<TestStoreState> mgr =
          IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
        plugin,
        'app-secret-key',
        TestStoreState.defaultState(PlatformWrapper.ios()),
        false,
        PlatformWrapper.ios(),
      );

      expect(mgr.isLoaded, isTrue);
      expect(mgr.shouldShowAds, isFalse);

      if (testCase.respCode == 404) {
        PlatformWrapper.ios();
      }

      Future<void> result = mgr.getPurchaseHistory(true);

      expect(mgr.isLoaded, isFalse);

      // And now return the getPurchaseHistory with our items.
      pluginResult.complete(purchases);

      // Let everything complete.
      await result;

      expect(mgr.isLoaded, isTrue);
      expect(mgr.hasFetchedPurchases, true);
      expect(mgr.storeState.noAdsForever.owned, isNotOwned);
      expect(
          mgr.storeState.noAdsOneYear.owned, equals(testCase.wantOwnedState));
      // We started not showing ads--bad validation (as opposed to validating
      // an expired sub) shouldn't remove the validation.
      expect(mgr.shouldShowAds, equals(testCase.wantShowAds));

      expect(mgr.pluginErrorMsg, isNull);

      if (testCase.shouldHaveErrorMsg) {
        expect(mgr.storeState.noAdsOneYear.errMsg, isNotNull);
        expect(mgr.storeState.noAdsOneYear.errMsg, isNotEmpty);
      }

      if (!testCase.jsonShouldParse) {
        expect(mgr.storeState.noAdsOneYear.errMsg, isNotNull);
        expect(mgr.storeState.noAdsOneYear.errMsg, isNotEmpty);
        expect(mgr.storeState.noAdsOneYear.errMsg.contains('FormatException'),
            isTrue);
      }

      // We should only call once--for prod.
      expect(numTimesValidateTxn, equals(1));

      expect(calledFinishTxn, isTrue);
    });
  });

  test('getPurchaseHistory() returns no purchases, reverts ads', () async {
    PurchasedItem shouldIgnoreNullId = MockPurchasedItem();
    when(shouldIgnoreNullId.transactionId).thenReturn(null);

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    List<PurchasedItem> purchases = [];

    var pluginResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory()).thenAnswer((_) => pluginResult.future);

    // Start without ads. We should revert b/c no purchases.
    IAPManager<TestStoreState> mgr =
        IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      false,
      PlatformWrapper.android(),
    );

    expect(mgr.isLoaded, isTrue);
    expect(mgr.shouldShowAds, isFalse);

    Future<void> result = mgr.getPurchaseHistory(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getPurchaseHistory with our items.
    pluginResult.complete(purchases);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedPurchases, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.shouldShowAds, isTrue);
  });

  test('getPurchaseHistory() purchaseHistoryError error', () async {
    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    when(plugin.getPurchaseHistory()).thenAnswer((realInvocation) async {
      throw Exception('expected error');
    });

    // Start now showing ads, and make sure we still don't show ads if we had
    // an error.
    IAPManager<TestStoreState> mgr =
        IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      false,
      PlatformWrapper.android(),
    );

    await mgr.getPurchaseHistory(true);

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedPurchases, isFalse);
    expect(mgr.pluginErrorMsg, contains('expected error'));
    expect(mgr.storeState.noAdsForever.owned, isUnknown);
    expect(mgr.storeState.noAdsOneYear.owned, isUnknown);
    expect(mgr.shouldShowAds, isFalse);
  });

  test('getAvailableProducts() happy path', () async {
    var products = Completer<List<IAPItem>>();
    var subs = Completer<List<IAPItem>>();

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    when(plugin.getProducts(any)).thenAnswer((_) => products.future);
    when(plugin.getSubscriptions(any))
        .thenAnswer((realInvocation) => subs.future);

    IAPManager<TestStoreState> mgr =
        IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      true,
      PlatformWrapper.android(),
    );

    expect(mgr.isLoaded, isTrue);

    Future<void> result = mgr.getAvailableProducts(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getPurchaseHistory with our items.
    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    expect(mgr.isLoaded, isFalse);
    subs.complete([items.forOneYear]);
    expect(mgr.isLoaded, isFalse);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedAvailableProducts, isTrue);

    TestStoreState got = mgr.storeState;

    expect(got.noAdsForever.getTitle(), equals('Title One Time'));
    expect(
        got.noAdsForever.product.description,
        equals('Description One '
            'Time'));
    expect(got.noAdsForever.owned, isUnknown);

    expect(got.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(
        got.noAdsOneYear.product.description,
        equals('Description One '
            'Year'));
    expect(got.noAdsOneYear.owned, isUnknown);
  });

  test('getAvailableProducts() getProducts error', () async {
    var products = Completer<List<IAPItem>>();
    var subs = Completer<List<IAPItem>>();

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    when(plugin.getProducts(any)).thenAnswer((_) => products.future);
    when(plugin.getSubscriptions(any)).thenAnswer((_) => subs.future);

    IAPManager<TestStoreState> mgr =
        IAPManager<TestStoreState>.forTestingDoNotCallInitialize(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      true,
      PlatformWrapper.android(),
    );

    expect(mgr.isLoaded, isTrue);

    Future<void> result = mgr.getAvailableProducts(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getPurchaseHistory with our items.
    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    expect(mgr.isLoaded, isFalse);
    subs.completeError(Exception('error in subs'));

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedAvailableProducts, isFalse);
    expect(mgr.pluginErrorMsg, contains('error in subs'));
    expect(mgr.storeState.noAdsForever.owned, isUnknown);
    expect(mgr.storeState.noAdsOneYear.owned, isUnknown);
  });

  test('tryToRecoverFromError() for initialization', () async {
    // A lot of this is duped from the initializeHappyPath test case

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    // Init the connection.
    var initResult = Completer<String>();

    int numTimesInitialized = 0;
    when(plugin.initConnection()).thenAnswer((_) {
      numTimesInitialized++;
      // Make an error in initialization.
      if (numTimesInitialized == 1) {
        throw Exception('error on first initConnection');
      }
      if (numTimesInitialized == 2) {
        debugPrint('returning initResult future');
        return initResult.future;
      }
      throw Exception('initConnection() called more than twice');
    });

    // Handle the purchase and error streams.
    StreamController<PurchasedItem> purchaseUpdatedStream =
        StreamController<PurchasedItem>();
    StreamController<PurchaseResult> purchaseErrorStream =
        StreamController<PurchaseResult>();

    var pluginGetPurchaseHistoryResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory())
        .thenAnswer((_) => pluginGetPurchaseHistoryResult.future);

    when(plugin.getPurchaseUpdatedStream())
        .thenAnswer((_) => purchaseUpdatedStream.stream);
    when(plugin.getPurchaseErrorStream())
        .thenAnswer((_) => purchaseErrorStream.stream);

    var products = Completer<List<IAPItem>>();
    var subs = Completer<List<IAPItem>>();

    when(plugin.getProducts(any)).thenAnswer((_) => products.future);
    when(plugin.getSubscriptions(any))
        .thenAnswer((realInvocation) => subs.future);

    bool initialShouldShowAds = false;
    // let it begin...
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      initialShouldShowAds,
      null,
      PlatformWrapper.android(),
    );

    TestUtil.waitUntilTrue(() => !mgr.isStillInitializing);
    // Now we should have had an error.
    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.shouldShowAds, initialShouldShowAds);
    expect(mgr.pluginErrorMsg, contains('error on first initConnection'));

    Future<void> recoveredFromError = mgr.tryToRecoverFromError();

    TestUtil.waitUntilTrue(() => mgr.isStillInitializing);
    TestUtil.waitUntilTrue(() => !mgr.isLoaded);

    // We're blocked on init cxn. Complete this.
    initResult.complete('cxn is live');

    pluginGetPurchaseHistoryResult.complete([]);
    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    subs.complete([items.forOneYear]);

    await recoveredFromError;

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(mgr.shouldShowAds, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.pluginErrorMsg, isNull);
  });

  test('tryToRecoverFromError() for getProducts, cxn is bad', () async {
    // One time I saw a cxn seemingly die. I assume this was because the app
    // was never killed and the cxn died out or something. The error seemed
    // to be persistent until I swiped away the app and re-opened, and it was:
    //
    // PlatformException(getPurchaseHistoryByType, E_NETWORK_ERROR, The service
    // is disconnected (check your internet connection.), null)
    //
    // I don't think it was actually the internet, but I'm not positive.
    // Either way, recovering from error should reset the connection state.

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    int numTimesInitialized = 0;
    when(plugin.initConnection()).thenAnswer((_) async {
      numTimesInitialized++;
      if (numTimesInitialized <= 2) {
        return 'init cxn';
      }
      throw Exception('initConnection() called more than twice');
    });

    bool calledDismissCxn = false;
    when(plugin.endConnection()).thenAnswer((realInvocation) async {
      calledDismissCxn = true;
      return 'dismissed';
    });

    PurchasedItem alreadyAckedAndroid = MockPurchasedItem();
    when(alreadyAckedAndroid.transactionId)
        .thenReturn('android-txn-id-already-acked');
    when(alreadyAckedAndroid.purchaseStateAndroid)
        .thenReturn(PurchaseState.purchased);
    when(alreadyAckedAndroid.productId).thenReturn('remove_ads_onetime');
    when(alreadyAckedAndroid.isAcknowledgedAndroid).thenReturn(true);

    int numTimesCalledGetPurchaseHistory = 0;
    when(plugin.getPurchaseHistory()).thenAnswer((_) async {
      numTimesCalledGetPurchaseHistory++;
      if (numTimesCalledGetPurchaseHistory == 1) {
        throw Exception('error on purchase history');
      }
      return [
        alreadyAckedAndroid,
      ];
    });

    _MockedIAPItems items = _MockedIAPItems();

    when(plugin.getPurchaseUpdatedStream()).thenAnswer((_) {
      return StreamController<PurchasedItem>().stream;
    });
    when(plugin.getPurchaseErrorStream()).thenAnswer((_) {
      return StreamController<PurchaseResult>().stream;
    });

    when(plugin.getProducts(any)).thenAnswer((_) async {
      return [
        items.forLife,
      ];
    });
    when(plugin.getSubscriptions(any)).thenAnswer((realInvocation) async {
      return [
        items.forOneYear,
      ];
    });

    bool initialShouldShowAds = false;
    // let it begin...
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      initialShouldShowAds,
      null,
      PlatformWrapper.android(),
    );

    await mgr.waitForInitialized();
    // Now we should have had an error.
    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.shouldShowAds, initialShouldShowAds);
    expect(mgr.pluginErrorMsg, contains('error on purchase history'));

    await mgr.tryToRecoverFromError();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(mgr.shouldShowAds, isFalse);
    expect(mgr.storeState.noAdsForever.owned, isOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    // Once on the first time, once after reinitializing.
    expect(numTimesInitialized, equals(2));
    expect(calledDismissCxn, isTrue);

    expect(mgr.pluginErrorMsg, isNull);
  });

  test('requestPurchase() android: happy path', () async {
    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    // Init the connection.
    var initResult = Completer<String>();

    when(plugin.initConnection()).thenAnswer((_) => initResult.future);

    // Handle the purchase and error streams.
    StreamController<PurchasedItem> purchaseUpdatedStream =
        StreamController<PurchasedItem>();
    StreamController<PurchaseResult> purchaseErrorStream =
        StreamController<PurchaseResult>();

    when(plugin.getPurchaseUpdatedStream())
        .thenAnswer((_) => purchaseUpdatedStream.stream);
    when(plugin.getPurchaseErrorStream())
        .thenAnswer((_) => purchaseErrorStream.stream);

    // getPurchaseHistory. We'll use an acked item so that we don't have to
    // worry about finalizing transactions.
    var pluginGetPurchaseHistoryResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory())
        .thenAnswer((_) => pluginGetPurchaseHistoryResult.future);

    PurchasedItem needsAckAndroid = MockPurchasedItem();
    when(needsAckAndroid.productId).thenReturn('remove_ads_onetime');
    when(needsAckAndroid.transactionId).thenReturn('txn-id');
    when(needsAckAndroid.purchaseStateAndroid)
        .thenReturn(PurchaseState.purchased);
    when(needsAckAndroid.isAcknowledgedAndroid).thenReturn(false);

    var products = Completer<List<IAPItem>>();
    var subs = Completer<List<IAPItem>>();

    when(plugin.getProducts(any)).thenAnswer((_) => products.future);
    when(plugin.getSubscriptions(any))
        .thenAnswer((realInvocation) => subs.future);

    when(plugin.requestPurchase(any)).thenAnswer((realInovcation) async {
      String sku = realInovcation.positionalArguments[0];
      if (sku == 'remove_ads_onetime') {
        purchaseUpdatedStream.add(needsAckAndroid);
      } else {
        throw Exception('unrecognized sku: $sku');
      }
    });

    bool calledFinish = false;
    when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
      var purchasedItem = realInvocation.positionalArguments[0];
      if (purchasedItem.transactionId == 'txn-id') {
        calledFinish = true;
        return 'android-result';
      }
      throw new Exception(
          'unrecognized transaction id: ${purchasedItem.transactionId}');
    });

    // let it begin...
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      true,
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    initResult.complete('cxn is live');
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    pluginGetPurchaseHistoryResult.complete([]);

    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    subs.complete([items.forOneYear]);

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    await mgr.waitForInitialized();

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(mgr.shouldShowAds, isTrue);

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);

    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    mgr.requestPurchase(items.forLife.productId);
    await TestUtil.waitUntilTrue(() => mgr.storeState.noAdsForever.isOwned());
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.shouldShowAds, isFalse);
    expect(calledFinish, isTrue);
  });

  test('requestPurchase() ios: non-consumable happy path', () async {
    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    // Init the connection.
    var initResult = Completer<String>();

    when(plugin.initConnection()).thenAnswer((_) => initResult.future);

    // Handle the purchase and error streams.
    StreamController<PurchasedItem> purchaseUpdatedStream =
        StreamController<PurchasedItem>();
    StreamController<PurchaseResult> purchaseErrorStream =
        StreamController<PurchaseResult>();

    when(plugin.getPurchaseUpdatedStream())
        .thenAnswer((_) => purchaseUpdatedStream.stream);
    when(plugin.getPurchaseErrorStream())
        .thenAnswer((_) => purchaseErrorStream.stream);

    // getPurchaseHistory. We'll use an acked item so that we don't have to
    // worry about finalizing transactions.
    var pluginGetPurchaseHistoryResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory())
        .thenAnswer((_) => pluginGetPurchaseHistoryResult.future);

    PurchasedItem needsAckIOS = MockPurchasedItem();
    when(needsAckIOS.productId).thenReturn('remove_ads_onetime');
    when(needsAckIOS.transactionId).thenReturn('txn-id');
    when(needsAckIOS.transactionStateIOS)
        .thenReturn(TransactionState.purchased);

    var products = Completer<List<IAPItem>>();
    var subs = Completer<List<IAPItem>>();

    when(plugin.getProducts(any)).thenAnswer((_) => products.future);
    when(plugin.getSubscriptions(any))
        .thenAnswer((realInvocation) => subs.future);

    when(plugin.requestPurchase(any)).thenAnswer((realInovcation) async {
      String sku = realInovcation.positionalArguments[0];
      if (sku == 'remove_ads_onetime') {
        purchaseUpdatedStream.add(needsAckIOS);
      } else {
        throw Exception('unrecognized sku: $sku');
      }
    });

    bool calledFinish = false;
    when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
      var purchasedItem = realInvocation.positionalArguments[0];
      if (purchasedItem.transactionId == 'txn-id') {
        calledFinish = true;
        return 'android-result';
      }
      throw new Exception(
          'unrecognized transaction id: ${purchasedItem.transactionId}');
    });

    // let it begin...
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.ios()),
      true,
      null,
      PlatformWrapper.ios(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    initResult.complete('cxn is live');
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    pluginGetPurchaseHistoryResult.complete([]);

    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    subs.complete([items.forOneYear]);

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    await mgr.waitForInitialized();

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(mgr.shouldShowAds, isTrue);

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);

    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    mgr.requestPurchase(items.forLife.productId);
    await TestUtil.waitUntilTrue(() => mgr.storeState.noAdsForever.isOwned());
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.shouldShowAds, isFalse);
    expect(calledFinish, isTrue);
  });

  test('requestPurchase() get error and dismiss', () async {
    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    // Init the connection.
    var initResult = Completer<String>();

    when(plugin.initConnection()).thenAnswer((_) => initResult.future);

    // Handle the purchase and error streams.
    StreamController<PurchasedItem> purchaseUpdatedStream =
        StreamController<PurchasedItem>();
    StreamController<PurchaseResult> purchaseErrorStream =
        StreamController<PurchaseResult>();

    when(plugin.getPurchaseUpdatedStream())
        .thenAnswer((_) => purchaseUpdatedStream.stream);
    when(plugin.getPurchaseErrorStream())
        .thenAnswer((_) => purchaseErrorStream.stream);

    // getPurchaseHistory. We'll use an acked item so that we don't have to
    // worry about finalizing transactions.
    var pluginGetPurchaseHistoryResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory())
        .thenAnswer((_) => pluginGetPurchaseHistoryResult.future);

    PurchaseResult forLifeError = MockPurchaseResult();
    when(forLifeError.message).thenReturn('error purchasing');

    var products = Completer<List<IAPItem>>();
    var subs = Completer<List<IAPItem>>();

    when(plugin.getProducts(any)).thenAnswer((_) => products.future);
    when(plugin.getSubscriptions(any))
        .thenAnswer((realInvocation) => subs.future);

    when(plugin.requestPurchase(any)).thenAnswer((realInovcation) async {
      String sku = realInovcation.positionalArguments[0];
      if (sku == 'remove_ads_onetime') {
        purchaseErrorStream.add(forLifeError);
      } else {
        throw Exception('unrecognized sku: $sku');
      }
    });

    // let it begin...
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      true,
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    initResult.complete('cxn is live');
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    pluginGetPurchaseHistoryResult.complete([]);

    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    subs.complete([]);

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    await mgr.waitForInitialized();

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.shouldShowAds, isTrue);

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);

    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    mgr.requestPurchase(items.forLife.productId);
    await TestUtil.waitUntilTrue(() => mgr.storeState.hasError());
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.lastError.message, equals('error purchasing'));

    mgr.dismissPurchaseError();
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.hasError(), isFalse);
    expect(mgr.storeState.lastError, isNull);
    expect(mgr.shouldShowAds, isTrue);
  });

  test('requestPurchase() throws error', () async {
    // This is unlike the case where the plugin successfully returns an error.
    // In this case we instead are in the situation where the plugin itself
    // throws an error. The plugin is a bit easy with errors, so we need to
    // be careful and handle these.
    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    // Init the connection.
    var initResult = Completer<String>();

    when(plugin.initConnection()).thenAnswer((_) => initResult.future);

    // Handle the purchase and error streams.
    StreamController<PurchasedItem> purchaseUpdatedStream =
        StreamController<PurchasedItem>();
    StreamController<PurchaseResult> purchaseErrorStream =
        StreamController<PurchaseResult>();

    when(plugin.getPurchaseUpdatedStream())
        .thenAnswer((_) => purchaseUpdatedStream.stream);
    when(plugin.getPurchaseErrorStream())
        .thenAnswer((_) => purchaseErrorStream.stream);

    // getPurchaseHistory. We'll use an acked item so that we don't have to
    // worry about finalizing transactions.
    var pluginGetPurchaseHistoryResult = Completer<List<PurchasedItem>>();
    when(plugin.getPurchaseHistory())
        .thenAnswer((_) => pluginGetPurchaseHistoryResult.future);

    var products = Completer<List<IAPItem>>();
    var subs = Completer<List<IAPItem>>();

    when(plugin.getProducts(any)).thenAnswer((_) => products.future);
    when(plugin.getSubscriptions(any))
        .thenAnswer((realInvocation) => subs.future);

    when(plugin.requestPurchase(any)).thenAnswer((realInvocation) async {
      throw Exception('expected error');
    });

    // let it begin...
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      true,
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.shouldShowAds, isTrue);

    initResult.complete('cxn is live');
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    pluginGetPurchaseHistoryResult.complete([]);

    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    subs.complete([]);

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    await mgr.waitForInitialized();

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.shouldShowAds, isTrue);

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);

    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    await mgr.requestPurchase(items.forLife.productId);
    await TestUtil.waitUntilTrue(() => mgr.hasPluginError);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.pluginErrorMsg, contains('expected err'));
  });

  test('handles purchase slow android', () async {
    // This comes from the fact that we got this state but applied it
    // immediately, ignoring pending.
    //     //  immediately applied as owned, even though it is not owned:
    //     // I/flutter (27673): XXX   purchaseState: PurchaseState.pending
    //     // I/flutter (27673): XXX   isAcked: false
    //     // I/flutter (27673): XXX purchaseStateAndroid: PurchaseState.pending
    //     // I/flutter (27673): XXX do not need to ack purchase
    //     // I/flutter (27673): XXX iap updated, setting lastKnownAds: false

    PurchasedItem pending = MockPurchasedItem();
    when(pending.transactionId).thenReturn('txn-id');
    when(pending.productId).thenReturn('remove_ads_oneyear');
    when(pending.purchaseStateAndroid).thenReturn(PurchaseState.pending);
    when(pending.isAcknowledgedAndroid).thenReturn(false);

    PurchasedItem needsAck = MockPurchasedItem();
    when(needsAck.transactionId).thenReturn('txn-id');
    when(needsAck.productId).thenReturn('remove_ads_oneyear');
    when(needsAck.purchaseStateAndroid).thenReturn(PurchaseState.purchased);
    when(needsAck.isAcknowledgedAndroid).thenReturn(false);

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    when(plugin.initConnection()).thenAnswer((_) async {
      return 'initialized';
    });

    _MockedIAPItems items = _MockedIAPItems();
    when(plugin.getProducts(any)).thenAnswer((realInvocation) async {
      return [items.forLife];
    });
    when(plugin.getSubscriptions(any)).thenAnswer((realInvocation) async {
      return [items.forOneYear];
    });

    // Handle the purchase and error streams.
    StreamController<PurchasedItem> purchaseUpdatedStream =
        StreamController<PurchasedItem>();
    StreamController<PurchaseResult> purchaseErrorStream =
        StreamController<PurchaseResult>();

    when(plugin.getPurchaseUpdatedStream())
        .thenAnswer((_) => purchaseUpdatedStream.stream);
    when(plugin.getPurchaseErrorStream())
        .thenAnswer((_) => purchaseErrorStream.stream);

    bool ackedAndroid = false;
    when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
      var purchasedItem = realInvocation.positionalArguments[0];
      if (purchasedItem.transactionId == 'txn-id') {
        ackedAndroid = true;
        return 'android-result';
      }
      throw new StateError(
          'unrecognized transaction id: ${purchasedItem.transactionId}');
    });

    bool calledPurchaseHistory = false;
    when(plugin.getPurchaseHistory()).thenAnswer((_) async {
      if (calledPurchaseHistory) {
        throw Exception('getPurchaseHistory called more than once');
      }
      calledPurchaseHistory = true;
      return [pending];
    });

    bool notifyListenersCalled = false;
    var notifyListenersCallback = () {
      notifyListenersCalled = true;
    };

    // Start showing ads, then make sure we stop showing ads once we have
    // purchases.
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      'foo',
      TestStoreState.defaultState(PlatformWrapper.android()),
      true,
      notifyListenersCallback,
      PlatformWrapper.android(),
    );

    await mgr.waitForInitialized();
    expect(calledPurchaseHistory, isTrue);

    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    // So now we should have received a pending purchase. Let's complete with
    // the completed purchase that needs an ack.
    notifyListenersCalled = false;
    purchaseUpdatedStream.add(needsAck);
    await TestUtil.waitUntilTrue(() => notifyListenersCalled);

    // Let everything complete.
    expect(ackedAndroid, true);

    expect(mgr.isLoaded, isTrue);
    expect(mgr.hasFetchedPurchases, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isOwned);
    expect(mgr.shouldShowAds, isFalse);
  });
}
