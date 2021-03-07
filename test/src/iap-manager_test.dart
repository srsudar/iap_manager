import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:iap_manager/iap_manager.dart';
import 'package:iap_manager/src/iap-logger.dart';
import 'package:iap_manager/src/ios-subscription-helper.dart';
import 'package:iap_manager/src/platform-wrapper.dart';
import 'package:iap_manager/src/store-state.dart';
import 'package:mockito/mockito.dart';

import 'test-util.dart';

class _IOSSubscriptionVerifier extends PurchaseVerifier {
  final IOSSubscriptionHelper helper;

  _IOSSubscriptionVerifier(this.helper);

  @override
  Future<PurchaseVerificationResult> verifyPurchase(PurchasedItem item) async {
    return await helper.verifyIOSSubscription(item);
  }
}

class _TestPurchaseVerifier extends PurchaseVerifier {
  bool _didVerify = false;
  final PurchaseVerificationResult result;

  _TestPurchaseVerifier({this.result});

  bool get didVerify => _didVerify;

  @override
  Future<PurchaseVerificationResult> verifyPurchase(PurchasedItem item) async {
    _didVerify = true;
    return result;
  }
}

class _IOSNativeSubValidationFailsTestCase {
  final String label;
  final int respCode;
  final String respBody;
  final bool jsonShouldParse;

  // We're only including this to make sure we don't mess up the test case
  // without realizing it.
  final bool wantShowAds;
  final bool shouldHaveErrorMsg;
  final OwnedState wantOwnedState;

  _IOSNativeSubValidationFailsTestCase({
    this.label,
    this.respCode,
    this.respBody,
    this.jsonShouldParse,
    this.wantShowAds,
    this.shouldHaveErrorMsg,
    this.wantOwnedState,
  });
}

class _IOSNativeSubValidationSucceedsTestCase {
  final String label;
  final List<PurchasedItem> subs;
  final List<bool> isExpired;
  final List<bool> wantCalledFinishTransaction;
  final bool wantSubOwned;

  _IOSNativeSubValidationSucceedsTestCase({
    this.label,
    this.isExpired,
    this.subs,
    this.wantCalledFinishTransaction,
    this.wantSubOwned,
  }) {
    if (subs.length != isExpired.length) {
      throw Exception('setup error, subs must equal length of isExpired');
    }
    if (subs.length != wantCalledFinishTransaction.length) {
      throw Exception('setup error, subs must equal length of bools');
    }
  }
}

class _AndroidSubscriptionTestCase {
  final String label;
  final PurchasedItem item;
  final PurchaseVerificationResult verificationResult;

  final bool wantDidAck;
  final bool wantOwned;

  _AndroidSubscriptionTestCase({
    this.label,
    this.item,
    this.verificationResult,
    this.wantDidAck,
    this.wantOwned,
  });
}

class _AndroidNonConsumableTestCase {
  final String label;
  final bool isAcked;
  final PurchaseState purchaseState;
  final _TestPurchaseVerifier purchaseVerifier;

  final bool wantDidVerify;
  final bool wantDidFinishTransaction;
  final OwnedState wantNoAdsForeverOwned;

  _AndroidNonConsumableTestCase({
    this.label,
    this.isAcked,
    this.purchaseVerifier,
    this.purchaseState,
    this.wantDidVerify,
    this.wantDidFinishTransaction,
    this.wantNoAdsForeverOwned,
  });
}

class _IOSGetAvailableNonConsumableTestCase {
  final String label;
  final PurchasedItem item;
  final _TestPurchaseVerifier purchaseVerifier;

  final bool wantDidVerify;
  final bool wantDidFinishTransaction;
  final OwnedState wantOwned;

  _IOSGetAvailableNonConsumableTestCase({
    this.label,
    this.item,
    this.purchaseVerifier,
    this.wantDidVerify,
    this.wantDidFinishTransaction,
    this.wantOwned,
  });
}

class _InitializeHitsNetworkTestCase {
  final String label;
  final PlatformWrapper platform;
  final bool wantHitsNetwork;

  _InitializeHitsNetworkTestCase(
      {this.label, this.platform, this.wantHitsNetwork});
}

class _RefreshStateTestCase {
  final String label;
  final PlatformWrapper platform;
  final bool wantFetchedProducts;
  final bool wantFetchedPurchases;

  _RefreshStateTestCase({
    this.label,
    this.platform,
    this.wantFetchedProducts,
    this.wantFetchedPurchases,
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

class TestIAPManager extends IAPManager<TestStoreState> {
  TestIAPManager(
      IAPPlugin3PWrapper plugin,
      TestStoreState storeState,
      void Function() notifyListenersInvokedCallback,
      PlatformWrapper platformWrapper,
      {PurchaseVerifier purchaseVerifier})
      : super(
          plugin,
          storeState,
          notifyListenersInvokedCallback,
          platformWrapper,
          purchaseVerifier: purchaseVerifier,
        );
}

/// This builds a TestIAPManager where the immediate calls to initialize are
/// provided by the caller. If answerGetSubscriptions() throws an error, eg,
/// the manager returned by this method will never initialize.
TestIAPManager _buildNeedsInitializeIAPManager({
  IAPPlugin3PWrapper mockedPlugin,
  TestStoreState initialState,
  // We only call these three methods b/c these three methods are what we
  // need in initialize for a bare load.
  Future<List<IAPItem>> Function() answerGetProducts,
  Future<List<IAPItem>> Function() answerGetSubscriptions,
  Future<List<PurchasedItem>> Function() answerGetAvailablePurchases,
  PlatformWrapper platformWrapper,
  PurchaseVerifier purchaseVerifier,
}) {
  when(mockedPlugin.initConnection()).thenAnswer((_) async {
    return 'connected';
  });

  // Handle the purchase and error streams.
  StreamController<PurchasedItem> purchaseUpdatedStream =
      StreamController<PurchasedItem>();
  StreamController<PurchaseResult> purchaseErrorStream =
      StreamController<PurchaseResult>();

  when(mockedPlugin.getPurchaseUpdatedStream())
      .thenAnswer((_) => purchaseUpdatedStream.stream);
  when(mockedPlugin.getPurchaseErrorStream())
      .thenAnswer((_) => purchaseErrorStream.stream);

  when(mockedPlugin.getAvailablePurchases()).thenAnswer((_) async {
    return answerGetAvailablePurchases();
  });

  when(mockedPlugin.getProducts(any)).thenAnswer((_) async {
    return answerGetProducts();
  });

  when(mockedPlugin.getSubscriptions(any)).thenAnswer((_) async {
    return answerGetSubscriptions();
  });

  return TestIAPManager(
    mockedPlugin,
    initialState,
    null,
    platformWrapper,
    purchaseVerifier: purchaseVerifier,
  );
}

/// This builds a TestIAPManager that initializes immediately, without
/// recovering any state. It allows initialization to complete and then
/// callers can test other state.
TestIAPManager _buildInitializingIAPManager({
  IAPPlugin3PWrapper mockedPlugin,
  TestStoreState initialState,
  // We only call these three methods b/c these three methods are what we
  // need in initialize for a bare load.
  Future<List<IAPItem>> Function() answerGetProducts,
  Future<List<IAPItem>> Function() answerGetSubscriptions,
  Future<List<PurchasedItem>> Function() answerGetAvailablePurchases,
  PlatformWrapper platformWrapper,
  PurchaseVerifier purchaseVerifier,
}) {
  when(mockedPlugin.initConnection()).thenAnswer((_) async {
    return 'connected';
  });

  // Handle the purchase and error streams.
  StreamController<PurchasedItem> purchaseUpdatedStream =
      StreamController<PurchasedItem>();
  StreamController<PurchaseResult> purchaseErrorStream =
      StreamController<PurchaseResult>();

  when(mockedPlugin.getPurchaseUpdatedStream())
      .thenAnswer((_) => purchaseUpdatedStream.stream);
  when(mockedPlugin.getPurchaseErrorStream())
      .thenAnswer((_) => purchaseErrorStream.stream);

  int numTimesGetAvailablePurchasesInvoked = 0;
  when(mockedPlugin.getAvailablePurchases()).thenAnswer((_) async {
    numTimesGetAvailablePurchasesInvoked++;
    if (numTimesGetAvailablePurchasesInvoked == 1) {
      return [];
    }
    return answerGetAvailablePurchases();
  });

  int numTimesGetProductsInvoked = 0;
  when(mockedPlugin.getProducts(any)).thenAnswer((_) async {
    numTimesGetProductsInvoked++;
    if (numTimesGetProductsInvoked == 1) {
      return [];
    }
    return answerGetProducts();
  });

  int numTimesGetSubscriptionsInvoked = 0;
  when(mockedPlugin.getSubscriptions(any)).thenAnswer((_) async {
    numTimesGetSubscriptionsInvoked++;
    if (numTimesGetSubscriptionsInvoked == 1) {
      return [];
    }
    return answerGetSubscriptions();
  });

  return TestIAPManager(
    mockedPlugin,
    initialState,
    null,
    platformWrapper,
    purchaseVerifier: purchaseVerifier,
  );
}

/// A note on subscriptions, at least on Android. This is more complicated than
/// you might expect, because the plugin doesn't populate the fields that I
/// think it should.
///
/// It generally looks like there are two shapes to these. IMMEDIATE, where
/// the IAPManager gets the result right away after subscribing. And DELAYED,
/// where the result comes from getAvailablePurchases(). Values are set
/// differently, irritatingly.
///
/// Some weird state here where the plugin doesn't seem to be extracting
/// information as I would expect. Here is a response from the Java side,
/// before being converted to "PurchasedItem" (ignoring the long strings,
/// which I replaced with bar/baz/foo. Note that purchaseStateAndroid: 1 is
/// set, while isAcknowledgedAndroid is missing.
///
/// In transactionReceipt, meanwhile, we do have an acknowledged value. But
/// in transactionReceipt purchaseState is 0, which is UNSPECIFIED_STATE!
///
/// https://developer.android.com/reference/com/android/billingclient/api/Purchase.PurchaseState
///
/// So it looks as if the transactionReceipt purchasedState is NOT to be
/// trusted, but we DO need transactionReceipt for the acknowledged value.
/// [
///   {
///     "productId": "remove_ads_oneyear",
///     "transactionId": "GPA.3352-2258-5711-46566",
///     "transactionDate": 1614641767049,
///     "transactionReceipt": "{\"orderId\":\"GPA.3352-2258-5711-46566\",\"packageName\":\"com.foobar.baz\",\"productId\":\"remove_ads_oneyear\",\"purchaseTime\":1614641767049,\"purchaseState\":0,\"purchaseToken\":\"baz.baz-baz-baz\",\"autoRenewing\":true,\"acknowledged\":true}",
///     "orderId": "GPA.3352-2258-5711-46566",
///     "purchaseToken": "bar.bar-bar-bar",
///     "signatureAndroid": "foo+foo/foo/foo/foo+foo+foo+foo/foo/foo/foo/foo==",
///     "purchaseStateAndroid": 1,
///     "autoRenewingAndroid": true
///   }
/// ]
///
/// And that is then parsed to (note the long string values are truncated). Note
/// here that again we have purchaseState correct but isAcknowledgedAndroid is
/// null, which means bool==null, which is disallowed and throws an error.
///
/// productId = "remove_ads_oneyear"
/// transactionId = "GPA.3352-2258-5711-46566"
/// transactionDate = {DateTime} 2021-03-01 15:36:07.049
/// transactionReceipt = {"orderId":"GPA.3352-2258-5711-46566","packageName":"com.foobar.baz","productId":"remove_ads_oneyear","purchaseTime":1614641767049,"purchaseState":0,"purchaseToken":"mkcbjipefcdpbibelncopbcj.AO-J1OwXHcEI8esZ7VmKzqFxoaL3reG39QxACoV-z7I48UHIvsVBhCvDQQhAlzeCvsK4Rl5SxN5wRr7YOLgENkIwCpIxGcKOwA","autoRenewing":true,"acknowledged":true}
/// purchaseToken = "mkcbjipefcdpbibelncopbcj.AO-J1OwXHcEI8esZ7VmKzqFxoaL3reG39QxACoV-z7I48UHIvsVBhCvDQQhAlzeCvsK4Rl5SxN5wRr7YOLgENkIwCpIxGcKOwA"
/// orderId = "GPA.3352-2258-5711-46566"
/// dataAndroid = null
/// signatureAndroid = "g7aIIY1qwVlDPmt48FEVyHu46Woake2BIiUmsmzopDQ3f7Wkco9EZt8+dES3sBiRXGQx7LVCiQEToE/HEAf4MQDZE6S0msYMiIo/cD2z9SrSTwI/V8V51aSHmNozXTnR"
/// autoRenewingAndroid = true
/// isAcknowledgedAndroid = null
/// purchaseStateAndroid = {PurchaseState} PurchaseState.purchased
/// originalJsonAndroid = null
/// originalTransactionDateIOS = null
/// originalTransactionIdentifierIOS = null
/// transactionStateIOS = null
///
/// For completeness, here is a transactionReceipt IMMEDIATELY AFTER purchasee:
///
/// {
///   "orderId": "GPA.3346-7233-6440-37884",
///   "packageName": "com.foobar.baz",
///   "productId": "remove_ads_oneyear",
///   "purchaseTime": 1614662207908,
///   "purchaseState": 0,
///   "purchaseToken": "hlellpbfbgegifomeliljehj.AO-J1Oznd-atro1NtWuwvQaEPsELOIQEfnDiqnoHwnXlbUG8_dqUMmYg7lKhLb2pk1EWN4RXKVvaXUsvaznJqg--bxx3_kqyuQ",
///   "autoRenewing": true,
///   "acknowledged": false
/// }
///
/// And somehow that then becomes this. Note that here for some reason
/// isAcknowledgedAndroid is false, i.e. non-null! (NB that for all of these
/// values, the maps that should be strings were in fact strings in the
/// plugin. The escaping was just lost when I was copy-pasting.)
///
/// productId = "remove_ads_oneyear"
/// transactionId = "GPA.3346-7233-6440-37884"
/// transactionDate = {DateTime} 2021-03-01 21:16:47.908
/// transactionReceipt = {"orderId":"GPA.3346-7233-6440-37884","packageName":"com.foobar.baz","productId":"remove_ads_oneyear","purchaseTime":1614662207908,"purchaseState":0,"purchaseToken":"hlellpbfbgegifomeliljehj.AO-J1Oznd-atro1NtWuwvQaEPsELOIQEfnDiqnoHwnXlbUG8_dqUMmYg7lKhLb2pk1EWN4RXKVvaXUsvaznJqg--bxx3_kqyuQ","autoRenewing":true,"acknowledged":false}
/// purchaseToken = "hlellpbfbgegifomeliljehj.AO-J1Oznd-atro1NtWuwvQaEPsELOIQEfnDiqnoHwnXlbUG8_dqUMmYg7lKhLb2pk1EWN4RXKVvaXUsvaznJqg--bxx3_kqyuQ"
/// orderId = "GPA.3346-7233-6440-37884"
/// dataAndroid = {"orderId":"GPA.3346-7233-6440-37884","packageName":"com.foobar.baz","productId":"remove_ads_oneyear","purchaseTime":1614662207908,"purchaseState":0,"purchaseToken":"hlellpbfbgegifomeliljehj.AO-J1Oznd-atro1NtWuwvQaEPsELOIQEfnDiqnoHwnXlbUG8_dqUMmYg7lKhLb2pk1EWN4RXKVvaXUsvaznJqg--bxx3_kqyuQ","autoRenewing":true,"acknowledged":false}
/// signatureAndroid = "eauL7K0VTvHJJau/S+bB3snJME6/I3RYZmozvO3dmhHcngOrP1mEBvRMu/GMFRR+nexXB6RwScAIcrwxM6tElG7/Be8aNIJAbCA3eyDH7sQdFTAcXksW7BeER0D4KEuF"
/// autoRenewingAndroid = true
/// isAcknowledgedAndroid = false
/// purchaseStateAndroid = {PurchaseState} PurchaseState.purchased
/// originalJsonAndroid = {"orderId":"GPA.3346-7233-6440-37884","packageName":"com.foobar.baz","productId":"remove_ads_oneyear","purchaseTime":1614662207908,"purchaseState":0,"purchaseToken":"hlellpbfbgegifomeliljehj.AO-J1Oznd-atro1NtWuwvQaEPsELOIQEfnDiqnoHwnXlbUG8_dqUMmYg7lKhLb2pk1EWN4RXKVvaXUsvaznJqg--bxx3_kqyuQ","autoRenewing":true,"acknowledged":false}
/// originalTransactionDateIOS = null
/// originalTransactionIdentifierIOS = null
/// transactionStateIOS = null

/// See long comment above about what Delayed means.
PurchasedItem _getDelayedAndroidSubscription(
    PurchaseState purchaseState, bool acked) {
  String ackedStr = acked ? 'true' : 'false';
  PurchasedItem result = MockPurchasedItem();
  when(result.productId).thenReturn('remove_ads_oneyear');
  when(result.transactionId).thenReturn('GPA.3352-2258-5711-46566');
  when(result.transactionDate).thenReturn(DateTime(2021, 03, 01, 15, 36, 07));
  when(result.transactionReceipt).thenReturn(
      "{\"orderId\":\"GPA.3352-2258-5711-46566\",\"packageName\":\"com"
      ".foobar.baz\",\"productId\":\"remove_ads_oneyear\","
      "\"purchaseTime\":1614641767049,\"purchaseState\":0,\"purchaseToken"
      "\":\"baz.baz-baz-baz\",\"autoRenewing\":true,\"acknowledged"
      "\":$ackedStr}");
  when(result.purchaseToken).thenReturn('fake-purchase-token');
  when(result.orderId).thenReturn('GPA.3352-2258-5711-46566');
  when(result.dataAndroid).thenReturn(null);
  when(result.signatureAndroid).thenReturn('fake-signature-android');
  when(result.autoRenewingAndroid).thenReturn(true);
  when(result.isAcknowledgedAndroid).thenReturn(null);
  when(result.purchaseStateAndroid).thenReturn(purchaseState);
  when(result.originalJsonAndroid).thenReturn(null);
  when(result.originalTransactionDateIOS).thenReturn(null);
  when(result.originalTransactionIdentifierIOS).thenReturn(null);
  when(result.transactionStateIOS).thenReturn(null);

  return result;
}

/// See long comment above about what Immediate means.
PurchasedItem _getImmediateAndroidSubscription(
    PurchaseState purchaseState, bool acked) {
  String ackedStr = acked ? 'true' : 'false';
  PurchasedItem result = MockPurchasedItem();
  when(result.productId).thenReturn('remove_ads_oneyear');
  when(result.transactionId).thenReturn('GPA.3346-7233-6440-37884');
  when(result.transactionDate).thenReturn(DateTime(2021, 03, 01, 21, 16, 47));
  when(result.transactionReceipt).thenReturn(
      "{\"orderId\":\"GPA.3346-7233-6440-37884\",\"packageName\":\"com"
      ".foobar.baz\",\"productId\":\"remove_ads_oneyear\","
      "\"purchaseTime\":1614641767049,\"purchaseState\":0,\"purchaseToken"
      "\":\"baz.baz-baz-baz\",\"autoRenewing\":true,\"acknowledged"
      "\":$ackedStr}");
  when(result.purchaseToken).thenReturn('fake-purchase-token');
  when(result.orderId).thenReturn('GPA.3346-7233-6440-37884');
  when(result.dataAndroid).thenReturn('{"orderId":"GPA.3346-7233-6440-37884",'
      '"packageName":"com.foobar.baz","productId":"remove_ads_oneyear","p'
      'urchaseTime":1614662207908,"purchaseState":0,"purchaseToken":"hlellpbf'
      'foo.AO-J1Oznd-foo--foo","autoRenewing":true,"acknowledged":false'
      '}');
  when(result.signatureAndroid).thenReturn('fake-signature-android');
  when(result.autoRenewingAndroid).thenReturn(true);
  when(result.isAcknowledgedAndroid).thenReturn(acked);
  when(result.purchaseStateAndroid).thenReturn(purchaseState);
  when(result.originalJsonAndroid).thenReturn('{"orderId":"GPA'
      '.3346-7233-6440-37884","packageName":"com.foobar.baz","productId":"rem'
      'ove_ads_oneyear","purchaseTime":1614662207908,"purchaseState":0,"purchaseT'
      'oken":"foo.AO-J1Oznd-foo--bxx3_kqyuQ","autoRenewing":true,"acknowledged"'
      ':false}');
  when(result.originalTransactionDateIOS).thenReturn(null);
  when(result.originalTransactionIdentifierIOS).thenReturn(null);
  when(result.transactionStateIOS).thenReturn(null);

  return result;
}

/// Get an immediate purchase, as is seen directly after the purchase is made.
/// This is taken straight from the app. Oh shoot, I missed the long strings
/// on these ones.
///
/// json = {_InternalLinkedHashMap} size = 12
///  0 = {map entry} "productId" -> "remove_ads_onetime"
///  1 = {map entry} "transactionId" -> "GPA.3317-3224-8880-76256"
///  2 = {map entry} "transactionDate" -> 1615004426071
///  3 = {map entry} "transactionReceipt" -> "{\"orderId\":\"GPA
///  .3317-3224-8880-76256\",\"packageName\":\"com.foobar.baz\",\"productId\":\"remove_ads_one..."
///  4 = {map entry} "purchaseToken" -> "dgjdeghlfoaokbhhpbklnbhk
///  .AO-J1OwHDr5-EMVP6t1THm-2aY5QUAutjAogg653iQEDN0_db5Y1-tudQ8pS7S-_Oz_MIphN8xv..."
///  5 = {map entry} "orderId" -> "GPA.3317-3224-8880-76256"
///  6 = {map entry} "dataAndroid" -> "{\"orderId\":\"GPA
///  .3317-3224-8880-76256\",\"packageName\":\"com.foobar.baz\",\"productId\":\"remove_ads_one..."
///  7 = {map entry} "signatureAndroid" -> "ELr3Ovutt5ZdfsIZXSCbXOjsSy0W0ZFxc
///  LLBOGnurlRjLxJRAPGIkP2Sf6nAXJuYg+22dvo5zoS5c0iGI+AdQ0MsqZbHhAUT94vO..."
///  8 = {map entry} "autoRenewingAndroid" -> false
///  9 = {map entry} "isAcknowledgedAndroid" -> false
///  10 = {map entry} "purchaseStateAndroid" -> 1
///  11 = {map entry} "originalJsonAndroid" -> "{\"orderId\":\"GPA
///  .3317-3224-8880-76256\",\"packageName\":\"com.foobar.baz\",\"productId\":\"remove_ads_one..."
///
/// item = {PurchasedItem} productId: remove_ads_onetime, transactionId: GPA
/// .3317-3224-8880-76256, transactionDate: 2021-03-05T20:20:26.071, transactionRec
///  productId = "remove_ads_onetime"
///  transactionId = "GPA.3317-3224-8880-76256"
///  transactionDate = {DateTime} 2021-03-05 20:20:26.071
///  transactionReceipt = "{\"orderId\":\"GPA.3317-3224-8880-76256\",
///  \"packageName\":\"com.foobar.baz\",\"productId\":\"remove_ads_onetime\",\"purchaseTime\":1615004"
///  purchaseToken = "dgjdeghlfoaokbhhpbklnbhk
///  .AO-J1OwHDr5-EMVP6t1THm-2aY5QUAutjAogg653iQEDN0_db5Y1-tudQ8pS7S-_Oz_MIphN8xv6dBc8C0yissNZ_FRfIkfu6Q"
///  orderId = "GPA.3317-3224-8880-76256"
///  dataAndroid = "{\"orderId\":\"GPA.3317-3224-8880-76256\",\"packageName
///  \":\"com.foobar.baz\",\"productId\":\"remove_ads_onetime\",\"purchaseTime\":1615004"
///  signatureAndroid = "ELr3Ovutt5ZdfsIZXSCbXOjsSy0W0ZFxcLLBOGnurlRjLxJRAPGI
///  kP2Sf6nAXJuYg+22dvo5zoS5c0iGI+AdQ0MsqZbHhAUT94vOz0HiOburadT2fkf6rzkhkLD3/DDJ"
///  autoRenewingAndroid = false
///  isAcknowledgedAndroid = false
///  purchaseStateAndroid = {PurchaseState} PurchaseState.purchased
///  originalJsonAndroid = "{\"orderId\":\"GPA.3317-3224-8880-76256\",
///  \"packageName\":\"com.foobar.baz\",\"productId\":\"remove_ads_onetime\",\"purchaseTime\":1615004"
///  originalTransactionDateIOS = null
///  originalTransactionIdentifierIOS = null
///  transactionStateIOS = null
PurchasedItem _getImmediateAndroidNonConsumable(
    PurchaseState purchaseState, bool acked) {
  PurchasedItem result = MockPurchasedItem();
  when(result.productId).thenReturn('remove_ads_onetime');
  when(result.transactionId).thenReturn('GPA.3317-3224-8880-76256');
  when(result.transactionDate).thenReturn(DateTime(2021, 03, 05, 20, 20, 26));
  when(result.transactionReceipt).thenReturn('fake-txn-receipt');
  when(result.purchaseToken).thenReturn('fake-purchase-token');
  when(result.orderId).thenReturn('GPA.3317-3224-8880-76256');
  when(result.dataAndroid).thenReturn('fake-data-android');
  when(result.signatureAndroid).thenReturn('fake-signature-android');
  when(result.autoRenewingAndroid).thenReturn(false);
  when(result.isAcknowledgedAndroid).thenReturn(acked);
  when(result.purchaseStateAndroid).thenReturn(purchaseState);
  when(result.originalJsonAndroid).thenReturn('fake-json-android');
  when(result.originalTransactionDateIOS).thenReturn(null);
  when(result.originalTransactionIdentifierIOS).thenReturn(null);
  when(result.transactionStateIOS).thenReturn(null);

  return result;
}

/// Get a purchase that was recovered from the play store, rather than
/// returned immediately after being purchased.
///
/// json = {_InternalLinkedHashMap} size = 9
///  0 = {map entry} "productId" -> "remove_ads_onetime"
///  1 = {map entry} "transactionId" -> "GPA.3317-3224-8880-76256"
///  2 = {map entry} "transactionDate" -> 1615004426071
///  3 = {map entry} "transactionReceipt" -> "{\"orderId\":\"GPA
///  .3317-3224-8880-76256\",\"packageName\":\"com.foobar.baz\",\"productId\":\"remove_ads_one..."
///  4 = {map entry} "orderId" -> "GPA.3317-3224-8880-76256"
///  5 = {map entry} "purchaseToken" -> "dgjdeghlfoaokbhhpbklnbhk
///  .AO-J1OwHDr5-EMVP6t1THm-2aY5QUAutjAogg653iQEDN0_db5Y1-tudQ8pS7S-_Oz_MIphN8xv..."
///  6 = {map entry} "signatureAndroid" -> "TElDJvEQA0PFHDfaC1Mrh0hkisXkCU7Ot
///  /OWZ32SaTtqcICxD6zZR3ltIBulzqXJzTQiZZ0hJKc3RfPCEXEqq0yeHDpk2BSrVR1U..."
///  7 = {map entry} "purchaseStateAndroid" -> 1
///  8 = {map entry} "isAcknowledgedAndroid" -> true
///
///
///  item = {PurchasedItem} productId: remove_ads_onetime, transactionId: GPA
///  .3317-3224-8880-76256, transactionDate: 2021-03-05T20:20:26.071, transactionRec
///  productId = "remove_ads_onetime"
///  transactionId = "GPA.3317-3224-8880-76256"
///  transactionDate = {DateTime} 2021-03-05 20:20:26.071
///  transactionReceipt = "{\"orderId\":\"GPA.3317-3224-8880-76256\",
///  \"packageName\":\"com.foobar.baz\",\"productId\":\"remove_ads_onetime\",\"purchaseTime\":1615004"
///  purchaseToken = "dgjdeghlfoaokbhhpbklnbhk
///  .AO-J1OwHDr5-EMVP6t1THm-2aY5QUAutjAogg653iQEDN0_db5Y1-tudQ8pS7S-_Oz_MIphN8xv6dBc8C0yissNZ_FRfIkfu6Q"
///  orderId = "GPA.3317-3224-8880-76256"
///  dataAndroid = null
///  signatureAndroid = "TElDJvEQA0PFHDfaC1Mrh0hkisXkCU7Ot/OWZ32SaTtqcICxD6zZ
///  R3ltIBulzqXJzTQiZZ0hJKc3RfPCEXEqq0yeHDpk2BSrVR1UsDL4tjJHzTO3woCaIgbLGXxSEvRV"
///  autoRenewingAndroid = null
///  isAcknowledgedAndroid = true
///  purchaseStateAndroid = {PurchaseState} PurchaseState.purchased
///  originalJsonAndroid = null
///  originalTransactionDateIOS = null
///  originalTransactionIdentifierIOS = null
PurchasedItem _getDelayedAndroidNonConsumable(
    PurchaseState purchaseState, bool acked) {
  PurchasedItem result = MockPurchasedItem();
  when(result.productId).thenReturn('remove_ads_onetime');
  when(result.transactionId).thenReturn('GPA.3317-3224-8880-76256');
  when(result.transactionDate).thenReturn(DateTime(2021, 03, 05, 20, 20, 26));
  when(result.transactionReceipt).thenReturn('fake-txn-receipt');
  when(result.purchaseToken).thenReturn('fake-purchase-token');
  when(result.orderId).thenReturn('GPA.3317-3224-8880-76256');
  when(result.dataAndroid).thenReturn(null);
  when(result.signatureAndroid).thenReturn('fake-signature-android');
  when(result.autoRenewingAndroid).thenReturn(null);
  when(result.isAcknowledgedAndroid).thenReturn(acked);
  when(result.purchaseStateAndroid).thenReturn(purchaseState);
  when(result.originalJsonAndroid).thenReturn(null);
  when(result.originalTransactionDateIOS).thenReturn(null);
  when(result.originalTransactionIdentifierIOS).thenReturn(null);
  when(result.transactionStateIOS).thenReturn(null);

  return result;
}

/// This is as pulled from a log immediately after hitting purchase, by way
/// of the listener:
/// # IMMEDIATELY after purchase, before processed by app
///
/// 0 = {map entry} "transactionReceipt" -> "MIIT9QYJKoZIhvcNAQcCoIIT5jCCE+IC
/// AQExCzAJBgUrDgMCGgUAMIIDlgYJKoZIhvcNAQcBoIIDhwSCA4MxggN/MAoCAQgCAQEE..."
/// 1 = {map entry} "transactionStateIOS" -> 1
/// 2 = {map entry} "transactionDate" -> 1614827976000
/// 3 = {map entry} "productId" -> "remove_ads_oneyear"
/// 4 = {map entry} "transactionId" -> "1000000784255972"
///
///
/// item = {PurchasedItem} productId: remove_ads_oneyear, transactionId:
/// 1000000784255972, transactionDate: 2021-03-03T19:19:36.000, transactionReceipt: MI
///  productId = "remove_ads_oneyear"
///  transactionId = "1000000784255972"
///  transactionDate = {DateTime} 2021-03-03 19:19:36.000
///  transactionReceipt = "MIIT9QYJKoZIhvcNAQcCoIIT5jCCE+ICAQExCzAJBgUrDgMCGg
///  UAMIIDlgYJKoZIhvcNAQcBoIIDhwSCA4MxggN/MAoCAQgCAQEEAhYAMAoCARQCAQEEAgwAMAsCAQEC"
///  purchaseToken = null
///  orderId = null
///  dataAndroid = null
///  signatureAndroid = null
///  autoRenewingAndroid = null
///  isAcknowledgedAndroid = null
///  purchaseStateAndroid = null
///  originalJsonAndroid = null
///  originalTransactionDateIOS = null
///  originalTransactionIdentifierIOS = null
///  transactionStateIOS = {TransactionState} TransactionState.purchased
PurchasedItem _getImmediateIOSNonConsumable(TransactionState txnState) {
  PurchasedItem result = MockPurchasedItem();
  when(result.productId).thenReturn('remove_ads_onetime');
  when(result.transactionId).thenReturn('1000000784255972');
  when(result.transactionDate).thenReturn(DateTime(2021, 03, 03, 19, 19, 36));
  when(result.transactionReceipt).thenReturn(
      'MIIT9QYJKoZIhvcNAQcCoIIT5jCCE+ICAQExCzAJBgUrDgMCGgUAMIIDlgYJKoZIhvcNAQcBoIIDhwSCA4MxggN/MAoCAQgCAQEEAhYAMAoCARQCAQEEAgwAMAsCAQEC');
  when(result.purchaseToken).thenReturn(null);
  when(result.orderId).thenReturn(null);
  when(result.dataAndroid).thenReturn(null);
  when(result.signatureAndroid).thenReturn(null);
  when(result.autoRenewingAndroid).thenReturn(null);
  when(result.isAcknowledgedAndroid).thenReturn(null);
  when(result.purchaseStateAndroid).thenReturn(null);
  when(result.originalJsonAndroid).thenReturn(null);
  when(result.originalTransactionDateIOS).thenReturn(null);
  when(result.originalTransactionIdentifierIOS).thenReturn(null);
  when(result.transactionStateIOS).thenReturn(txnState);

  return result;
}

PurchasedItem _getImmediateIOSSubscription(TransactionState txnState) {
  PurchasedItem result = MockPurchasedItem();
  when(result.productId).thenReturn('remove_ads_oneyear');
  when(result.transactionId).thenReturn('1000000784255972');
  when(result.transactionDate).thenReturn(DateTime(2021, 03, 03, 19, 19, 36));
  when(result.transactionReceipt).thenReturn(
      'MIIT9QYJKoZIhvcNAQcCoIIT5jCCE+ICAQExCzAJBgUrDgMCGgUAMIIDlgYJKoZIhvcNAQcBoIIDhwSCA4MxggN/MAoCAQgCAQEEAhYAMAoCARQCAQEEAgwAMAsCAQEC');
  when(result.purchaseToken).thenReturn(null);
  when(result.orderId).thenReturn(null);
  when(result.dataAndroid).thenReturn(null);
  when(result.signatureAndroid).thenReturn(null);
  when(result.autoRenewingAndroid).thenReturn(null);
  when(result.isAcknowledgedAndroid).thenReturn(null);
  when(result.purchaseStateAndroid).thenReturn(null);
  when(result.originalJsonAndroid).thenReturn(null);
  when(result.originalTransactionDateIOS).thenReturn(null);
  when(result.originalTransactionIdentifierIOS).thenReturn(null);
  when(result.transactionStateIOS).thenReturn(txnState);

  return result;
}

/// This is from getAvailablePurchaseHistory(), the equivalent of restoring a
/// transaction. I've only ever seen `restored` state here, but there could
/// be others.
///  product = {_InternalLinkedHashMap} size = 7
///  0 = {map entry} "transactionReceipt" -> "MIIUEgYJKoZIhvcNAQcCoIIUAzCCE/8
///  CAQExCzAJBgUrDgMCGgUAMIIDswYJKoZIhvcNAQcBoIIDpASCA6AxggOcMAoCAQgCAQEE..."
///  1 = {map entry} "productId" -> "remove_ads_oneyear"
///  2 = {map entry} "transactionId" -> "1000000784257330"
///  3 = {map entry} "originalTransactionDateIOS" -> 1614827978000.0
///  4 = {map entry} "originalTransactionIdentifierIOS" -> "1000000784255972"
///  5 = {map entry} "transactionStateIOS" -> 3
///  6 = {map entry} "transactionDate" -> 1614827976000.0
///
///
///  item = {PurchasedItem} productId: remove_ads_oneyear, transactionId:
///  1000000784257330, transactionDate: 2021-03-03T19:19:36.000, transactionReceipt: MI
///  productId = "remove_ads_oneyear"
///  transactionId = "1000000784257330"
///  transactionDate = {DateTime} 2021-03-03 19:19:36.000
///  transactionReceipt = "MIIUEgYJKoZIhvcNAQcCoIIUAzCCE/8CAQExCzAJBgUrDgMCGg
///  UAMIIDswYJKoZIhvcNAQcBoIIDpASCA6AxggOcMAoCAQgCAQEEAhYAMAoCARQCAQEEAgwAMAsCAQEC"
///  purchaseToken = null
///  orderId = null
///  dataAndroid = null
///  signatureAndroid = null
///  autoRenewingAndroid = null
///  isAcknowledgedAndroid = null
///  purchaseStateAndroid = null
///  originalJsonAndroid = null
///  originalTransactionDateIOS = {DateTime} 2021-03-03 19:19:38.000
///  originalTransactionIdentifierIOS = "1000000784255972"
///  transactionStateIOS = {TransactionState} TransactionState.restored
PurchasedItem _getRestoredIOSNonConsumable() {
  PurchasedItem result = MockPurchasedItem();
  when(result.productId).thenReturn('remove_ads_onetime');
  when(result.transactionId).thenReturn('1000000784257330');
  when(result.transactionDate).thenReturn(DateTime(2021, 03, 03, 19, 19, 36));
  when(result.transactionReceipt).thenReturn(
      'MIIUEgYJKoZIhvcNAQcCoIIUAzCCE/8CAQExCzAJBgUrDgMCGgUAMIIDswYJKoZIhvcNAQcBoIIDpASCA6AxggOcMAoCAQgCAQEEAhYAMAoCARQCAQEEAgwAMAsCAQEC');
  when(result.purchaseToken).thenReturn(null);
  when(result.orderId).thenReturn(null);
  when(result.dataAndroid).thenReturn(null);
  when(result.signatureAndroid).thenReturn(null);
  when(result.autoRenewingAndroid).thenReturn(null);
  when(result.isAcknowledgedAndroid).thenReturn(null);
  when(result.purchaseStateAndroid).thenReturn(null);
  when(result.originalJsonAndroid).thenReturn(null);
  when(result.originalTransactionDateIOS)
      .thenReturn(DateTime(2021, 03, 03, 19, 19, 38));
  when(result.originalTransactionIdentifierIOS).thenReturn('1000000784255972');
  when(result.transactionStateIOS).thenReturn(TransactionState.restored);

  return result;
}

PurchasedItem _getRestoredIOSSubscription() {
  PurchasedItem result = MockPurchasedItem();
  when(result.productId).thenReturn('remove_ads_oneyear');
  when(result.transactionId).thenReturn('1000000784257330');
  when(result.transactionDate).thenReturn(DateTime(2021, 03, 03, 19, 19, 36));
  when(result.transactionReceipt).thenReturn(
      'MIIUEgYJKoZIhvcNAQcCoIIUAzCCE/8CAQExCzAJBgUrDgMCGgUAMIIDswYJKoZIhvcNAQcBoIIDpASCA6AxggOcMAoCAQgCAQEEAhYAMAoCARQCAQEEAgwAMAsCAQEC');
  when(result.purchaseToken).thenReturn(null);
  when(result.orderId).thenReturn(null);
  when(result.dataAndroid).thenReturn(null);
  when(result.signatureAndroid).thenReturn(null);
  when(result.autoRenewingAndroid).thenReturn(null);
  when(result.isAcknowledgedAndroid).thenReturn(null);
  when(result.purchaseStateAndroid).thenReturn(null);
  when(result.originalJsonAndroid).thenReturn(null);
  when(result.originalTransactionDateIOS)
      .thenReturn(DateTime(2021, 03, 03, 19, 19, 38));
  when(result.originalTransactionIdentifierIOS).thenReturn('1000000784255972');
  when(result.transactionStateIOS).thenReturn(TransactionState.restored);

  return result;
}

Future<void> _runAndroidNonConsumableTestCase(
    _AndroidNonConsumableTestCase testCase, bool isImmediate) async {
  PurchasedItem item = isImmediate
      ? _getImmediateAndroidNonConsumable(
          testCase.purchaseState, testCase.isAcked)
      : _getDelayedAndroidNonConsumable(
          testCase.purchaseState, testCase.isAcked);

  IAPPlugin3PWrapper plugin = MockPluginWrapper();

  bool calledFinishTransaction = false;

  when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
    calledFinishTransaction = true;
    return 'finished-txn';
  });

  List<PurchasedItem> purchases = [
    item,
  ];

  var availablePurchasesResult = Completer<List<PurchasedItem>>();

  TestIAPManager mgr = _buildInitializingIAPManager(
    mockedPlugin: plugin,
    initialState: TestStoreState.defaultState(true, PlatformWrapper.android()),
    answerGetAvailablePurchases: () => availablePurchasesResult.future,
    answerGetProducts: () => Future.value([]),
    answerGetSubscriptions: () => Future.value([]),
    platformWrapper: PlatformWrapper.android(),
    purchaseVerifier: testCase.purchaseVerifier,
  );

  await mgr.waitForInitialized();

  expect(mgr.isLoaded, isTrue);
  expect(mgr.pluginErrorMsg, isNull);
  expect(mgr.storeState.shouldShowAds(), isTrue);
  expect(mgr.storeState.noAdsForever.owned, isNotOwned);
  expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

  Future<void> result = mgr.getAvailablePurchases(true);

  expect(mgr.isLoaded, isFalse);

  // And now return the getAvailablePurchases with our items.
  availablePurchasesResult.complete(purchases);

  // Let everything complete.
  await result;

  expect(mgr.isLoaded, isTrue);
  expect(mgr.pluginErrorMsg, isNull);

  if (testCase.wantDidVerify != null && testCase.wantDidVerify) {
    expect(testCase.purchaseVerifier.didVerify, isTrue);
  }
  if (testCase.wantDidVerify != null && !testCase.wantDidVerify) {
    expect(testCase.purchaseVerifier.didVerify, isFalse);
  }

  if (testCase.wantNoAdsForeverOwned == OwnedState.OWNED) {
    expect(mgr.storeState.noAdsForever.owned, isOwned);
    expect(mgr.storeState.shouldShowAds(), isFalse);
  } else if (testCase.wantNoAdsForeverOwned == OwnedState.NOT_OWNED) {
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.shouldShowAds(), isTrue);
  } else {
    expect(mgr.storeState.noAdsForever.owned, isUnknown);
    // isTrue b/c that is the start state.
    expect(mgr.storeState.shouldShowAds(), isTrue);
  }

  expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

  expect(calledFinishTransaction, equals(testCase.wantDidFinishTransaction));
}

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

    // getAvailablePurchases. We'll use an acked item so that we don't have to
    // worry about finalizing transactions.
    PurchasedItem alreadyAckedAndroid = MockPurchasedItem();
    when(alreadyAckedAndroid.transactionId)
        .thenReturn('android-txn-id-already-acked');
    when(alreadyAckedAndroid.purchaseStateAndroid)
        .thenReturn(PurchaseState.purchased);
    when(alreadyAckedAndroid.productId).thenReturn('remove_ads_onetime');
    when(alreadyAckedAndroid.isAcknowledgedAndroid).thenReturn(true);

    var pluginGetAvailablePurchasesResult = Completer<List<PurchasedItem>>();
    when(plugin.getAvailablePurchases())
        .thenAnswer((_) => pluginGetAvailablePurchasesResult.future);

    var products = Completer<List<IAPItem>>();
    var subs = Completer<List<IAPItem>>();

    when(plugin.getProducts(any)).thenAnswer((_) => products.future);
    when(plugin.getSubscriptions(any))
        .thenAnswer((realInvocation) => subs.future);

    // let it begin...
    TestIAPManager mgr = TestIAPManager(
      plugin,
      TestStoreState.defaultState(true, PlatformWrapper.android()),
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    // Default should be false.
    expect(mgr.logInReleaseMode, isFalse);

    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);

    initResult.complete('cxn is live');
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);

    pluginGetAvailablePurchasesResult.complete([alreadyAckedAndroid]);

    // What we want to do here is a bit to make sure that the async call
    // completes. Kind of an ugly way to do this, but I'm not sure how else
    // we do it...
    await TestUtil.waitUntilTrue(() {
      return mgr.storeState.noAdsForever.isOwned();
    });

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isFalse);

    // getAvailableProducts
    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    subs.complete([items.forOneYear]);

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isFalse);

    await mgr.waitForInitialized();

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(mgr.storeState.shouldShowAds(), isFalse);

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
  });

  test('initialize getProducts succeeds, availablePurchases errors', () async {
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
    var pluginGetAvailablePurchasesResult = Completer<List<PurchasedItem>>();
    when(plugin.getAvailablePurchases())
        .thenAnswer((_) => pluginGetAvailablePurchasesResult.future);

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
      TestStoreState.defaultState(false, PlatformWrapper.android()),
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isFalse);

    initResult.complete('cxn is live');
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isFalse);

    pluginGetAvailablePurchasesResult
        .completeError(Exception('getAvailablePurchases error'));

    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.storeState.shouldShowAds(), isFalse);

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(mgr.storeState.noAdsForever.owned, isUnknown);
    expect(mgr.storeState.noAdsOneYear.owned, isUnknown);
    expect(mgr.pluginErrorMsg, contains('getAvailablePurchases error'));
  });

  test('initialize getProducts errors, availablePurchases succeeds', () async {
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

    // getAvailablePurchases. We'll use an acked item so that we don't have to
    // worry about finalizing transactions.
    PurchasedItem alreadyAckedAndroid = MockPurchasedItem();
    when(alreadyAckedAndroid.transactionId)
        .thenReturn('android-txn-id-already-acked');
    when(alreadyAckedAndroid.purchaseStateAndroid)
        .thenReturn(PurchaseState.purchased);
    when(alreadyAckedAndroid.productId).thenReturn('remove_ads_onetime');
    when(alreadyAckedAndroid.isAcknowledgedAndroid).thenReturn(true);

    var pluginGetAvailablePurchasesResult = Completer<List<PurchasedItem>>();
    when(plugin.getAvailablePurchases())
        .thenAnswer((_) => pluginGetAvailablePurchasesResult.future);

    when(plugin.getProducts(any)).thenAnswer((_) async {
      throw Exception('getProducts error');
    });
    when(plugin.getSubscriptions(any)).thenAnswer((realInvocation) async {
      return [];
    });

    // let it begin...
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      TestStoreState.defaultState(true, PlatformWrapper.android()),
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);

    initResult.complete('cxn is live');

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);

    pluginGetAvailablePurchasesResult.complete([alreadyAckedAndroid]);

    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.storeState.shouldShowAds(), isFalse);

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
    when(plugin.getAvailablePurchases()).thenAnswer(
        (realInvocation) => throw Exception('called get available purchases'));
    when(plugin.getProducts(any))
        .thenAnswer((realInvocation) => throw Exception('called getProducts'));
    when(plugin.requestPurchase(any)).thenAnswer(
        (realInvocation) => throw Exception('called requestPurchase'));

    // let it begin...
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      TestStoreState.defaultState(false, PlatformWrapper.android()),
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isFalse);

    initResult.completeError(Exception('error init cxn'));

    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.storeState.shouldShowAds(), isFalse);

    expect(mgr.pluginErrorMsg, contains('error init cxn'));

    // And now make sure that calling our other methods doesn't cause a
    // problem. We should be smart enough to not do anything with this if
    // there is a problem.
    await mgr.getAvailablePurchases(true);
    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.shouldShowAds(), isFalse);
    expect(mgr.pluginErrorMsg, contains('error init cxn'));

    await mgr.getAvailableProducts(true);
    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.shouldShowAds(), isFalse);
    expect(mgr.pluginErrorMsg, contains('error init cxn'));

    mgr.requestPurchase('fake-id');
    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.shouldShowAds(), isFalse);
    expect(mgr.pluginErrorMsg, contains('error init cxn'));
  });

  test('getAvailablePurchases() android: missing purchase state', () async {
    PurchasedItem shouldIgnore = MockPurchasedItem();
    when(shouldIgnore.transactionId).thenReturn('foo');
    // We're including this because in the first pass of the plugin, when I
    // was erroneously calling "getPurchaseHistory", the purchase state was
    // returning null. This apparently means we shouldn't own it, although I
    // had managed to be confused based on how the library is working.
    when(shouldIgnore.purchaseStateAndroid).thenReturn(null);
    when(shouldIgnore.productId).thenReturn('remove_ads_onetime');

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    bool calledFinishTransaction = false;
    when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
      calledFinishTransaction = true;
      return 'acked';
    });

    List<PurchasedItem> purchases = [
      shouldIgnore,
    ];

    var pluginResult = Completer<List<PurchasedItem>>();

    TestIAPManager mgr = _buildInitializingIAPManager(
      mockedPlugin: plugin,
      initialState:
          TestStoreState.defaultState(true, PlatformWrapper.android()),
      answerGetAvailablePurchases: () => pluginResult.future,
      answerGetProducts: () => Future.value([]),
      answerGetSubscriptions: () => Future.value([]),
      platformWrapper: PlatformWrapper.android(),
    );

    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    Future<void> result = mgr.getAvailablePurchases(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getAvailablePurchases with our items.
    pluginResult.complete(purchases);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.storeState.shouldShowAds(), isTrue);

    expect(calledFinishTransaction, isFalse);
  });

  <_AndroidNonConsumableTestCase>[
    _AndroidNonConsumableTestCase(
      label: 'purchased, acked',
      purchaseState: PurchaseState.purchased,
      isAcked: true,
      purchaseVerifier: _TestPurchaseVerifier(),
      wantDidFinishTransaction: false,
      wantDidVerify: false,
      wantNoAdsForeverOwned: OwnedState.OWNED,
    ),
    _AndroidNonConsumableTestCase(
      label: 'purchased, unacked, no verification',
      purchaseState: PurchaseState.purchased,
      isAcked: false,
      wantDidFinishTransaction: true,
      wantNoAdsForeverOwned: OwnedState.OWNED,
    ),
    _AndroidNonConsumableTestCase(
      label: 'purchased, unacked, WITH successful verification',
      purchaseState: PurchaseState.purchased,
      isAcked: false,
      purchaseVerifier: _TestPurchaseVerifier(
        result:
            PurchaseVerificationResult(PurchaseVerificationStatus.VALID, ''),
      ),
      wantDidFinishTransaction: true,
      wantDidVerify: true,
      wantNoAdsForeverOwned: OwnedState.OWNED,
    ),
    _AndroidNonConsumableTestCase(
      label: 'purchased, unacked, WITH invalid verification',
      purchaseState: PurchaseState.purchased,
      isAcked: false,
      purchaseVerifier: _TestPurchaseVerifier(
        result:
            PurchaseVerificationResult(PurchaseVerificationStatus.INVALID, ''),
      ),
      wantDidFinishTransaction: false,
      wantDidVerify: true,
      wantNoAdsForeverOwned: OwnedState.NOT_OWNED,
    ),
    _AndroidNonConsumableTestCase(
      label: 'purchased, unacked, WITH unknown verification',
      purchaseState: PurchaseState.purchased,
      isAcked: false,
      purchaseVerifier: _TestPurchaseVerifier(
        result: PurchaseVerificationResult(
            PurchaseVerificationStatus.UNKNOWN, 'something went wrong'),
      ),
      wantDidFinishTransaction: false,
      wantDidVerify: true,
      wantNoAdsForeverOwned: OwnedState.UNKNOWN,
    ),
    _AndroidNonConsumableTestCase(
      label: 'pending, acked',
      purchaseState: PurchaseState.pending,
      isAcked: true,
      wantDidFinishTransaction: false,
      wantNoAdsForeverOwned: OwnedState.NOT_OWNED,
    ),
    _AndroidNonConsumableTestCase(
      label: 'pending, unacked',
      purchaseState: PurchaseState.pending,
      isAcked: false,
      wantDidFinishTransaction: false,
      wantNoAdsForeverOwned: OwnedState.NOT_OWNED,
    ),
    _AndroidNonConsumableTestCase(
      label: 'unspecified, acked',
      purchaseState: PurchaseState.unspecified,
      isAcked: true,
      wantDidFinishTransaction: false,
      wantNoAdsForeverOwned: OwnedState.NOT_OWNED,
    ),
    _AndroidNonConsumableTestCase(
      label: 'unspecified, unacked',
      purchaseState: PurchaseState.unspecified,
      isAcked: false,
      wantDidFinishTransaction: false,
      wantNoAdsForeverOwned: OwnedState.NOT_OWNED,
    ),
  ].forEach((testCase) {
    test('android getAvailableNonConsumable DELAYED: ${testCase.label}',
        () async {
      await _runAndroidNonConsumableTestCase(testCase, false);
    });

    test('android getAvailableNonConsumable IMMEDIATE: ${testCase.label}',
        () async {
      await _runAndroidNonConsumableTestCase(testCase, true);
    });
  });

  <_AndroidSubscriptionTestCase>[
    _AndroidSubscriptionTestCase(
      label: 'sub IMMEDIATE pending is not owned',
      // Note: not actually sure here if pending sub means acked is falsed.
      // Could also be null with how the plugin works.
      item: _getImmediateAndroidSubscription(PurchaseState.pending, false),
      wantDidAck: false,
      wantOwned: false,
    ),
    _AndroidSubscriptionTestCase(
      label: 'sub IMMEDIATE is owned needs ack',
      item: _getImmediateAndroidSubscription(PurchaseState.purchased, false),
      wantDidAck: true,
      wantOwned: true,
    ),
    _AndroidSubscriptionTestCase(
      label: 'android: sub DELAYED is now owned needs ack',
      item: _getDelayedAndroidSubscription(PurchaseState.pending, false),
      wantDidAck: false,
      wantOwned: false,
    ),
    _AndroidSubscriptionTestCase(
      label: 'android: sub DELAYED is owned needs ack',
      item: _getDelayedAndroidSubscription(PurchaseState.purchased, false),
      wantDidAck: true,
      wantOwned: true,
    ),
    _AndroidSubscriptionTestCase(
      label: 'sub DELAYED purchased and acked',
      item: _getDelayedAndroidSubscription(PurchaseState.purchased, true),
      wantDidAck: false,
      wantOwned: true,
    ),
  ].forEach((testCase) {
    test('getAvailablePurchases() android: ${testCase.label}', () async {
      IAPPlugin3PWrapper plugin = MockPluginWrapper();

      bool calledFinishTransaction = false;

      when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
        calledFinishTransaction = true;
        return 'android-result';
      });

      List<PurchasedItem> purchases = [
        testCase.item,
      ];

      var availablePurchasesResult = Completer<List<PurchasedItem>>();

      // Start showing ads, then make sure we stop showing ads once we have
      // purchases.
      TestIAPManager mgr = _buildInitializingIAPManager(
        mockedPlugin: plugin,
        initialState:
            TestStoreState.defaultState(true, PlatformWrapper.android()),
        answerGetAvailablePurchases: () => availablePurchasesResult.future,
        answerGetProducts: () => Future.value([]),
        answerGetSubscriptions: () => Future.value([]),
        platformWrapper: PlatformWrapper.android(),
      );

      await mgr.waitForInitialized();

      expect(mgr.isLoaded, isTrue);
      expect(mgr.pluginErrorMsg, isNull);
      expect(mgr.storeState.shouldShowAds(), isTrue);
      expect(mgr.storeState.noAdsForever.owned, isNotOwned);
      expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

      Future<void> result = mgr.getAvailablePurchases(true);

      expect(mgr.isLoaded, isFalse);

      // And now return the getAvailablePurchases with our items.
      availablePurchasesResult.complete(purchases);

      // Let everything complete.
      await result;

      expect(mgr.isLoaded, isTrue);
      expect(mgr.pluginErrorMsg, isNull);

      expect(mgr.storeState.noAdsForever.owned, isNotOwned);
      if (testCase.wantOwned) {
        expect(mgr.storeState.noAdsOneYear.owned, isOwned);
        expect(mgr.storeState.shouldShowAds(), isFalse);
      } else {
        expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
        expect(mgr.storeState.shouldShowAds(), isTrue);
      }

      expect(calledFinishTransaction, equals(testCase.wantDidAck));
    });
  });

  <_RefreshStateTestCase>[
    _RefreshStateTestCase(
      label: 'android refreshes both',
      platform: PlatformWrapper.android(),
    ),
    _RefreshStateTestCase(
      label: 'ios refreshes only products',
      platform: PlatformWrapper.ios(),
    ),
  ].forEach((testCase) {
    test('refreshState: ${testCase.label}', () async {
      IAPPlugin3PWrapper plugin = MockPluginWrapper();

      int numTimesCalledGetPurchases = 0;
      var answerGetAvailablePurchases = () async {
        numTimesCalledGetPurchases++;
        return <PurchasedItem>[];
      };

      int numTimesCalledGetProducts = 0;
      var answerGetProducts = () async {
        numTimesCalledGetProducts++;
        return <IAPItem>[];
      };

      int numTimesCalledGetSubscriptions = 0;
      var answerGetSubscriptions = () async {
        numTimesCalledGetSubscriptions++;
        return <IAPItem>[];
      };

      // Start showing ads, then make sure we stop showing ads once we have
      // purchases.
      TestIAPManager mgr = _buildNeedsInitializeIAPManager(
        mockedPlugin: plugin,
        initialState: TestStoreState.defaultState(true, testCase.platform),
        answerGetAvailablePurchases: answerGetAvailablePurchases,
        answerGetProducts: answerGetProducts,
        answerGetSubscriptions: answerGetSubscriptions,
        platformWrapper: testCase.platform,
      );

      await mgr.waitForInitialized();
      expect(mgr.isLoaded, isTrue);
      expect(mgr.pluginErrorMsg, isNull);

      expect(mgr.storeState.shouldShowAds(), isTrue);

      await mgr.refreshState();

      if (testCase.platform.isAndroid) {
        // we call once in init, and once after refresh state
        expect(numTimesCalledGetSubscriptions, equals(2));
        expect(numTimesCalledGetProducts, equals(2));
        expect(numTimesCalledGetPurchases, equals(2));
      }

      if (testCase.platform.isIOS) {
        expect(numTimesCalledGetSubscriptions, equals(1));
        expect(numTimesCalledGetProducts, equals(1));
        expect(numTimesCalledGetPurchases, equals(0));
      }
    });
  });

  <_InitializeHitsNetworkTestCase>[
    _InitializeHitsNetworkTestCase(
      label: 'android hits network',
      platform: PlatformWrapper.android(),
      wantHitsNetwork: true,
    ),
    _InitializeHitsNetworkTestCase(
      label: 'ios does not network',
      platform: PlatformWrapper.ios(),
      wantHitsNetwork: false,
    ),
  ].forEach((testCase) {
    test('initialize hits network: ${testCase.label}', () async {
      IAPPlugin3PWrapper plugin = MockPluginWrapper();

      bool calledGetAvailablePurchases = false;
      var answerGetAvailablePurchases = () async {
        calledGetAvailablePurchases = true;
        return <PurchasedItem>[];
      };

      bool calledGetProducts = false;
      var answerGetProducts = () async {
        calledGetProducts = true;
        return <IAPItem>[];
      };

      bool calledGetSubscriptions = false;
      var answerGetSubscriptions = () async {
        calledGetSubscriptions = true;
        return <IAPItem>[];
      };

      // Start showing ads, then make sure we stop showing ads once we have
      // purchases.
      TestIAPManager mgr = _buildNeedsInitializeIAPManager(
        mockedPlugin: plugin,
        initialState: TestStoreState.defaultState(true, testCase.platform),
        answerGetAvailablePurchases: answerGetAvailablePurchases,
        answerGetProducts: answerGetProducts,
        answerGetSubscriptions: answerGetSubscriptions,
        platformWrapper: testCase.platform,
      );

      await mgr.waitForInitialized();
      expect(mgr.isLoaded, isTrue);
      expect(mgr.pluginErrorMsg, isNull);

      expect(mgr.storeState.shouldShowAds(), isTrue);

      if (testCase.wantHitsNetwork) {
        expect(calledGetSubscriptions, isTrue);
        expect(calledGetProducts, isTrue);
        expect(calledGetAvailablePurchases, isTrue);
        expect(mgr.storeState.noAdsForever.owned, isNotOwned);
        expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
      } else {
        expect(calledGetSubscriptions, isFalse);
        expect(calledGetProducts, isFalse);
        expect(calledGetAvailablePurchases, isFalse);
        expect(mgr.storeState.noAdsForever.owned, isUnknown);
        expect(mgr.storeState.noAdsOneYear.owned, isUnknown);
      }
    });
  });

  <_IOSGetAvailableNonConsumableTestCase>[
    _IOSGetAvailableNonConsumableTestCase(
      label: 'purchased, no verification',
      wantOwned: OwnedState.OWNED,
      wantDidFinishTransaction: true,
      item: _getImmediateIOSNonConsumable(TransactionState.purchased),
    ),
    _IOSGetAvailableNonConsumableTestCase(
      label: 'purchased, verification VALID',
      wantOwned: OwnedState.OWNED,
      purchaseVerifier: _TestPurchaseVerifier(
        result:
            PurchaseVerificationResult(PurchaseVerificationStatus.VALID, ''),
      ),
      wantDidFinishTransaction: true,
      wantDidVerify: true,
      item: _getImmediateIOSNonConsumable(TransactionState.purchased),
    ),
    _IOSGetAvailableNonConsumableTestCase(
      label: 'purchased, verification INVALID',
      wantOwned: OwnedState.NOT_OWNED,
      purchaseVerifier: _TestPurchaseVerifier(
        result:
            PurchaseVerificationResult(PurchaseVerificationStatus.INVALID, ''),
      ),
      wantDidFinishTransaction: true,
      wantDidVerify: true,
      item: _getImmediateIOSNonConsumable(TransactionState.purchased),
    ),
    _IOSGetAvailableNonConsumableTestCase(
      label: 'purchased, verification UNKNOWN',
      wantOwned: OwnedState.UNKNOWN,
      purchaseVerifier: _TestPurchaseVerifier(
        result:
            PurchaseVerificationResult(PurchaseVerificationStatus.UNKNOWN, ''),
      ),
      wantDidFinishTransaction: true,
      wantDidVerify: true,
      item: _getImmediateIOSNonConsumable(TransactionState.purchased),
    ),
    _IOSGetAvailableNonConsumableTestCase(
      label: 'restored, no verification',
      wantOwned: OwnedState.OWNED,
      wantDidFinishTransaction: true,
      item: _getRestoredIOSNonConsumable(),
    ),
    _IOSGetAvailableNonConsumableTestCase(
      label: 'restored, verification VALID',
      wantOwned: OwnedState.OWNED,
      wantDidFinishTransaction: true,
      purchaseVerifier: _TestPurchaseVerifier(
        result:
            PurchaseVerificationResult(PurchaseVerificationStatus.VALID, ''),
      ),
      wantDidVerify: true,
      item: _getRestoredIOSNonConsumable(),
    ),
    _IOSGetAvailableNonConsumableTestCase(
      label: 'restored, verification INVALID',
      wantOwned: OwnedState.NOT_OWNED,
      wantDidFinishTransaction: true,
      purchaseVerifier: _TestPurchaseVerifier(
        result:
            PurchaseVerificationResult(PurchaseVerificationStatus.INVALID, ''),
      ),
      wantDidVerify: true,
      item: _getRestoredIOSNonConsumable(),
    ),
    _IOSGetAvailableNonConsumableTestCase(
      label: 'restored, verification UNKNOWN',
      wantOwned: OwnedState.UNKNOWN,
      wantDidFinishTransaction: true,
      purchaseVerifier: _TestPurchaseVerifier(
        result:
            PurchaseVerificationResult(PurchaseVerificationStatus.UNKNOWN, ''),
      ),
      wantDidVerify: true,
      item: _getRestoredIOSNonConsumable(),
    ),
    _IOSGetAvailableNonConsumableTestCase(
      label: 'purchasing',
      wantOwned: OwnedState.NOT_OWNED,
      wantDidFinishTransaction: false,
      purchaseVerifier: _TestPurchaseVerifier(
        result:
            PurchaseVerificationResult(PurchaseVerificationStatus.VALID, ''),
      ),
      wantDidVerify: false,
      item: _getImmediateIOSNonConsumable(TransactionState.purchasing),
    ),
    _IOSGetAvailableNonConsumableTestCase(
      label: 'deferred',
      wantOwned: OwnedState.NOT_OWNED,
      wantDidFinishTransaction: false,
      item: _getImmediateIOSNonConsumable(TransactionState.deferred),
    ),
    _IOSGetAvailableNonConsumableTestCase(
      label: 'failed',
      wantOwned: OwnedState.NOT_OWNED,
      wantDidFinishTransaction: true,
      item: _getImmediateIOSNonConsumable(TransactionState.failed),
    ),
  ].forEach((testCase) {
    test('ios getAvailableProducts: ${testCase.label}', () async {
      IAPPlugin3PWrapper plugin = MockPluginWrapper();

      bool calledFinish = false;

      when(plugin.finishTransaction(any)).thenAnswer((_) async {
        calledFinish = true;
        return 'finished';
      });

      List<PurchasedItem> purchases = [
        testCase.item,
      ];

      var availablePurchasesResult = Completer<List<PurchasedItem>>();
      bool calledGetAvailablePurchases = false;
      var answerGetAvailablePurchases = () {
        calledGetAvailablePurchases = true;
        return availablePurchasesResult.future;
      };

      // Start showing ads, then make sure we stop showing ads once we have
      // purchases. We use needsInitializing version here since this is iOS
      // and thus we don't want a bare call on the first load.
      TestIAPManager mgr = _buildNeedsInitializeIAPManager(
        mockedPlugin: plugin,
        initialState: TestStoreState.defaultState(true, PlatformWrapper.ios()),
        answerGetAvailablePurchases: answerGetAvailablePurchases,
        answerGetProducts: () => Future.value([]),
        answerGetSubscriptions: () => Future.value([]),
        platformWrapper: PlatformWrapper.ios(),
        purchaseVerifier: testCase.purchaseVerifier,
      );

      await mgr.waitForInitialized();
      expect(calledGetAvailablePurchases, isFalse);
      expect(mgr.isLoaded, isTrue);
      expect(mgr.pluginErrorMsg, isNull);

      expect(mgr.storeState.shouldShowAds(), isTrue);
      expect(mgr.storeState.noAdsForever.owned, isUnknown);
      expect(mgr.storeState.noAdsOneYear.owned, isUnknown);

      Future<void> result = mgr.getAvailablePurchases(true);

      expect(mgr.isLoaded, isFalse);

      // And now return the getAvailablePurchases with our items.
      availablePurchasesResult.complete(purchases);

      // Let everything complete.
      await result;

      expect(mgr.isLoaded, isTrue);
      expect(mgr.pluginErrorMsg, isNull);
      expect(calledGetAvailablePurchases, isTrue);

      if (testCase.wantDidVerify != null && testCase.wantDidVerify) {
        expect(testCase.purchaseVerifier.didVerify, isTrue);
      }
      if (testCase.wantDidVerify != null && !testCase.wantDidVerify) {
        expect(testCase.purchaseVerifier.didVerify, isFalse);
      }

      if (testCase.wantOwned == OwnedState.OWNED) {
        expect(mgr.storeState.noAdsForever.owned, isOwned);
        expect(mgr.storeState.shouldShowAds(), isFalse);
      } else if (testCase.wantOwned == OwnedState.NOT_OWNED) {
        expect(mgr.storeState.noAdsForever.owned, isNotOwned);
        expect(mgr.storeState.shouldShowAds(), isTrue);
      } else {
        expect(mgr.storeState.noAdsForever.owned, isUnknown);
        expect(mgr.storeState.shouldShowAds(), isTrue); // b/c start showing
      }

      expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

      expect(calledFinish, equals(testCase.wantDidFinishTransaction));
    });
  });

  <_IOSNativeSubValidationSucceedsTestCase>[
    _IOSNativeSubValidationSucceedsTestCase(
      label: 'purchased, valid',
      subs: [
        _getImmediateIOSSubscription(TransactionState.purchased),
      ],
      isExpired: [false],
      wantCalledFinishTransaction: [true],
      wantSubOwned: true,
    ),
    _IOSNativeSubValidationSucceedsTestCase(
      label: 'restored, valid',
      subs: [
        _getImmediateIOSSubscription(TransactionState.restored),
      ],
      isExpired: [false],
      wantCalledFinishTransaction: [true],
      wantSubOwned: true,
    ),
    _IOSNativeSubValidationSucceedsTestCase(
      label: 'purchase, valid',
      subs: [
        _getImmediateIOSSubscription(TransactionState.purchasing),
      ],
      isExpired: [false],
      wantCalledFinishTransaction: [false],
      wantSubOwned: false,
    ),
    _IOSNativeSubValidationSucceedsTestCase(
      label: 'purchased, expired',
      subs: [
        _getImmediateIOSSubscription(TransactionState.purchased),
      ],
      isExpired: [true],
      wantCalledFinishTransaction: [true],
      wantSubOwned: false,
    ),
    _IOSNativeSubValidationSucceedsTestCase(
      // We're including this because this caused an error in the wild.
      label: 'purchased, multiple expired',
      subs: [
        _getImmediateIOSSubscription(TransactionState.purchased),
        _getImmediateIOSSubscription(TransactionState.purchased),
      ],
      isExpired: [true, true],
      wantCalledFinishTransaction: [true, true],
      wantSubOwned: false,
    ),
    _IOSNativeSubValidationSucceedsTestCase(
      // We're including this because this caused an error in the wild.
      label: 'failed and purchased expired',
      subs: [
        _getImmediateIOSSubscription(TransactionState.failed),
        _getImmediateIOSSubscription(TransactionState.purchased),
      ],
      isExpired: [true, true],
      wantCalledFinishTransaction: [true, true],
      wantSubOwned: false,
    ),
  ].forEach((testCase) {
    test('getAvailablePurchases() ios subscription: ${testCase.label}',
        () async {
      IAPPlugin3PWrapper plugin = MockPluginWrapper();

      List<bool> calledFinishArr = [];
      testCase.wantCalledFinishTransaction.forEach((_) {
        calledFinishArr.add(false);
      });
      expect(calledFinishArr.length,
          equals(testCase.wantCalledFinishTransaction.length));

      var getIndexOfItem = (PurchasedItem item) {
        int index = testCase.subs.indexOf(item);
        if (index < 0) {
          throw Exception("could not find index of item");
        }

        return index;
      };

      when(plugin.finishTransaction(any)).thenAnswer((realInvocation) async {
        var purchasedItem = realInvocation.positionalArguments[0];
        int index = getIndexOfItem(purchasedItem);
        calledFinishArr[index] = true;

        return 'finished';
      });

      // Generates the response from the server.
      var getResponseStr = (bool isExpired, bool isSandbox) {
        String statusStr = isSandbox ? '21007' : '0';
        String expired = '{"status":$statusStr, "pending_renewal_info": [ '
            '{ "'
            'expiration_intent": "1" } ] }';

        String valid = '{"status":$statusStr, "pending_renewal_info": [ '
            '{ "'
            'original_transaction_id": "foo" } ] }';

        return isExpired ? expired : valid;
      };

      // We're just going to assume that they all have the same txn receipt.
      String wantTxnReceipt = testCase.subs[0].transactionReceipt;

      // We're going to behave as if this is a sandbox purchase, b/c we don't
      // know until we get a response from the server (and therefore we're not
      // testing the implementation over the API TOO much), and also this is
      // the most natural place to ensure we call it twice.
      int numTimesValidateTxn = 0;
      when(plugin.validateTransactionIOS(any, any))
          .thenAnswer((realInvocation) async {
        bool isExpired = testCase.isExpired[numTimesValidateTxn];
        numTimesValidateTxn++;

        Map<String, dynamic> reqBody = realInvocation.positionalArguments[0];
        String txnReceipt = reqBody['receipt-data'] as String;
        String pwd = reqBody['password'] as String;
        String exclude = reqBody['exclude-old-transactions'] as String;

        if (txnReceipt != wantTxnReceipt) {
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
        String rawBody = getResponseStr(isExpired, useSandbox);
        when(resp.body).thenReturn(rawBody);

        return resp;
      });

      // On iOS subs come via purchases.
      List<PurchasedItem> purchases = testCase.subs;

      var availablePurchasesResult = Completer<List<PurchasedItem>>();

      // Start NOT showing ads, and make sure we remove for an expired sub.
      // We use needsInitialize here b/c iOS doesn't call any of the store
      // methods on load.
      TestIAPManager mgr = _buildNeedsInitializeIAPManager(
        mockedPlugin: plugin,
        initialState: TestStoreState.defaultState(false, PlatformWrapper.ios()),
        answerGetAvailablePurchases: () => availablePurchasesResult.future,
        answerGetProducts: () => Future.value([]),
        answerGetSubscriptions: () => Future.value([]),
        platformWrapper: PlatformWrapper.ios(),
        purchaseVerifier: _IOSSubscriptionVerifier(IOSSubscriptionHelper(
            plugin, 'app-secret-key', IAPLogger('subhelper', false))),
      );

      await mgr.waitForInitialized();

      expect(mgr.isLoaded, isTrue);
      expect(mgr.pluginErrorMsg, isNull);
      expect(mgr.storeState.shouldShowAds(), isFalse);
      expect(mgr.storeState.noAdsForever.owned, isUnknown);
      expect(mgr.storeState.noAdsOneYear.owned, isUnknown);

      Future<void> result = mgr.getAvailablePurchases(true);

      expect(mgr.isLoaded, isFalse);

      // And now return the getAvailablePurchases with our items.
      availablePurchasesResult.complete(purchases);

      // Let everything complete.
      await result;

      expect(mgr.isLoaded, isTrue);

      if (testCase.isExpired.any((element) => element)) {
        expect(mgr.storeState.noAdsOneYear.errMsg, isNotNull);
      } else {
        expect(mgr.storeState.noAdsOneYear.errMsg, isEmpty);
      }

      expect(mgr.storeState.noAdsForever.owned, isNotOwned);

      if (testCase.wantSubOwned) {
        expect(mgr.storeState.noAdsOneYear.owned, isOwned);
        expect(mgr.storeState.shouldShowAds(), isFalse);
      } else {
        expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
        expect(mgr.storeState.shouldShowAds(), isTrue);
      }

      for (int i = 0; i < testCase.wantCalledFinishTransaction.length; i++) {
        bool want = testCase.wantCalledFinishTransaction[i];
        bool got = calledFinishArr[i];
        expect(want, equals(got));
      }
    });
  });

  <_IOSNativeSubValidationFailsTestCase>[
    _IOSNativeSubValidationFailsTestCase(
      label: 'validation parses, sub is expired',
      respCode: 200,
      respBody: '{"status":0, "pending_renewal_info": [ { "'
          'expiration_intent": "1" } ] }',
      jsonShouldParse: true,
      shouldHaveErrorMsg: false,
      wantShowAds: true,
      wantOwnedState: OwnedState.NOT_OWNED,
    ),
    _IOSNativeSubValidationFailsTestCase(
      label: 'HTTP 404 code',
      respCode: 404,
      respBody: 'not home right now',
      jsonShouldParse: true,
      shouldHaveErrorMsg: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.UNKNOWN,
    ),
    _IOSNativeSubValidationFailsTestCase(
      label: 'non-ok server status',
      respCode: 200,
      respBody: '{"status":100}',
      jsonShouldParse: true,
      shouldHaveErrorMsg: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.UNKNOWN,
    ),
    _IOSNativeSubValidationFailsTestCase(
      label: 'bad json',
      respCode: 200,
      respBody: '{"status_is_broken',
      jsonShouldParse: false,
      shouldHaveErrorMsg: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.UNKNOWN,
    ),
    _IOSNativeSubValidationFailsTestCase(
      label: 'missing pending_renewal_info',
      respCode: 200,
      respBody: '{"status":0}',
      shouldHaveErrorMsg: false,
      jsonShouldParse: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.UNKNOWN, // should always be present
    ),
    _IOSNativeSubValidationFailsTestCase(
      label: 'pending_renewal_info is string, not array',
      respCode: 200,
      respBody: '{"status":0, "pending_renewal_info": "trubs" }',
      shouldHaveErrorMsg: false,
      jsonShouldParse: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.UNKNOWN,
    ),
    _IOSNativeSubValidationFailsTestCase(
      label: 'pending_renewal_info is object, not array',
      respCode: 200,
      respBody: '{"status":0, "pending_renewal_info": {"cat": "dog" } }',
      shouldHaveErrorMsg: false,
      jsonShouldParse: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.UNKNOWN,
    ),
    _IOSNativeSubValidationFailsTestCase(
      label: 'pending_renewal_info empty array',
      respCode: 200,
      respBody: '{"status":0, "pending_renewal_info": [ ] }',
      shouldHaveErrorMsg: false,
      jsonShouldParse: true,
      wantShowAds: false,
      wantOwnedState: OwnedState.UNKNOWN, // should be one if active
    ),
    _IOSNativeSubValidationFailsTestCase(
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

      var availablePurchasesResult = Completer<List<PurchasedItem>>();

      // needs initialize b/c iOS doesn't call initialize.
      TestIAPManager mgr = _buildNeedsInitializeIAPManager(
        mockedPlugin: plugin,
        initialState: TestStoreState.defaultState(false, PlatformWrapper.ios()),
        answerGetAvailablePurchases: () => availablePurchasesResult.future,
        answerGetProducts: () => Future.value([]),
        answerGetSubscriptions: () => Future.value([]),
        platformWrapper: PlatformWrapper.ios(),
        purchaseVerifier: _IOSSubscriptionVerifier(
          IOSSubscriptionHelper(
            plugin,
            'app-secret-key',
            IAPLogger('foo', true),
          ),
        ),
      );

      await mgr.waitForInitialized();

      expect(mgr.isLoaded, isTrue);
      expect(mgr.pluginErrorMsg, isNull);
      expect(mgr.storeState.shouldShowAds(), isFalse);
      expect(mgr.storeState.noAdsForever.owned, isUnknown);
      expect(mgr.storeState.noAdsOneYear.owned, isUnknown);

      Future<void> result = mgr.getAvailablePurchases(true);

      expect(mgr.isLoaded, isFalse);

      // And now return the getAvailablePurchases with our items.
      availablePurchasesResult.complete(purchases);

      // Let everything complete.
      await result;

      expect(mgr.isLoaded, isTrue);
      expect(mgr.storeState.noAdsForever.owned, isNotOwned);
      expect(
          mgr.storeState.noAdsOneYear.owned, equals(testCase.wantOwnedState));
      // We started not showing ads--bad validation (as opposed to validating
      // an expired sub) shouldn't remove the validation.
      expect(mgr.storeState.shouldShowAds(), equals(testCase.wantShowAds));

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

  test('getAvailablePurchases() returns no purchases, reverts ads', () async {
    PurchasedItem shouldIgnoreNullId = MockPurchasedItem();
    when(shouldIgnoreNullId.transactionId).thenReturn(null);

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    List<PurchasedItem> purchases = [];

    var availablePurchasesResult = Completer<List<PurchasedItem>>();

    // Start without ads. We should revert b/c no purchases.
    TestIAPManager mgr = _buildInitializingIAPManager(
      mockedPlugin: plugin,
      initialState:
          TestStoreState.defaultState(false, PlatformWrapper.android()),
      answerGetAvailablePurchases: () => availablePurchasesResult.future,
      answerGetProducts: () => Future.value([]),
      answerGetSubscriptions: () => Future.value([]),
      platformWrapper: PlatformWrapper.android(),
    );

    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    Future<void> result = mgr.getAvailablePurchases(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getAvailablePurchases with our items.
    availablePurchasesResult.complete(purchases);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.storeState.shouldShowAds(), isTrue);
  });

  test('getAvailablePurchases() error', () async {
    // This is if we fetch it once the first time, and then we have an error
    // on the second time.
    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    // Start now showing ads, and make sure we still don't show ads if we had
    // an error.
    TestIAPManager mgr = _buildNeedsInitializeIAPManager(
      mockedPlugin: plugin,
      initialState:
          TestStoreState.defaultState(false, PlatformWrapper.android()),
      answerGetAvailablePurchases: () {
        throw Exception('expected error');
      },
      answerGetProducts: () => Future.value([]),
      answerGetSubscriptions: () => Future.value([]),
      platformWrapper: PlatformWrapper.android(),
    );

    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.shouldShowAds(), isFalse);
    expect(mgr.storeState.noAdsForever.owned, isUnknown);
    expect(mgr.storeState.noAdsOneYear.owned, isUnknown);

    expect(mgr.pluginErrorMsg, contains('expected error'));
  });

  test('getAvailableProducts() happy path', () async {
    var products = Completer<List<IAPItem>>();
    var subs = Completer<List<IAPItem>>();

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    TestIAPManager mgr = _buildInitializingIAPManager(
      mockedPlugin: plugin,
      initialState:
          TestStoreState.defaultState(true, PlatformWrapper.android()),
      answerGetAvailablePurchases: () => Future.value([]),
      answerGetProducts: () => products.future,
      answerGetSubscriptions: () => subs.future,
      platformWrapper: PlatformWrapper.android(),
    );

    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    Future<void> result = mgr.getAvailableProducts(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getAvailablePurchases with our items.
    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    expect(mgr.isLoaded, isFalse);
    subs.complete([items.forOneYear]);
    expect(mgr.isLoaded, isFalse);

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);

    TestStoreState got = mgr.storeState;

    expect(got.noAdsForever.getTitle(), equals('Title One Time'));
    expect(
        got.noAdsForever.product.description,
        equals('Description One '
            'Time'));
    expect(got.noAdsForever.owned, isNotOwned);

    expect(got.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(
        got.noAdsOneYear.product.description,
        equals('Description One '
            'Year'));
    expect(got.noAdsOneYear.owned, isNotOwned);
  });

  test('getAvailableProducts() getProducts error', () async {
    var products = Completer<List<IAPItem>>();
    var subs = Completer<List<IAPItem>>();

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    when(plugin.getProducts(any)).thenAnswer((_) => products.future);
    when(plugin.getSubscriptions(any)).thenAnswer((_) => subs.future);

    TestIAPManager mgr = _buildInitializingIAPManager(
      mockedPlugin: plugin,
      initialState:
          TestStoreState.defaultState(true, PlatformWrapper.android()),
      answerGetAvailablePurchases: () => Future.value([]),
      answerGetProducts: () => products.future,
      answerGetSubscriptions: () => subs.future,
      platformWrapper: PlatformWrapper.android(),
    );

    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    Future<void> result = mgr.getAvailableProducts(true);

    expect(mgr.isLoaded, isFalse);

    // And now return the getAvailablePurchases with our items.
    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    expect(mgr.isLoaded, isFalse);
    subs.completeError(Exception('error in subs'));

    // Let everything complete.
    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.pluginErrorMsg, contains('error in subs'));
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
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

    var pluginGetAvailablePurchasesResult = Completer<List<PurchasedItem>>();
    when(plugin.getAvailablePurchases())
        .thenAnswer((_) => pluginGetAvailablePurchasesResult.future);

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
      TestStoreState.defaultState(
          initialShouldShowAds, PlatformWrapper.android()),
      null,
      PlatformWrapper.android(),
    );

    TestUtil.waitUntilTrue(() => !mgr.isStillInitializing);
    // Now we should have had an error.
    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.storeState.shouldShowAds(), initialShouldShowAds);
    expect(mgr.pluginErrorMsg, contains('error on first initConnection'));

    Future<void> recoveredFromError = mgr.tryToRecoverFromError();

    TestUtil.waitUntilTrue(() => mgr.isStillInitializing);
    TestUtil.waitUntilTrue(() => !mgr.isLoaded);

    // We're blocked on init cxn. Complete this.
    initResult.complete('cxn is live');

    pluginGetAvailablePurchasesResult.complete([]);
    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    subs.complete([items.forOneYear]);

    await recoveredFromError;

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(mgr.storeState.shouldShowAds(), isTrue);
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
    // PlatformException(getAvailablePurchasesByType, E_NETWORK_ERROR, The service
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

    int numTimesCalledGetAvailablePurchases = 0;
    when(plugin.getAvailablePurchases()).thenAnswer((_) async {
      numTimesCalledGetAvailablePurchases++;
      if (numTimesCalledGetAvailablePurchases == 1) {
        throw Exception('error on get available purchases');
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
      TestStoreState.defaultState(
          initialShouldShowAds, PlatformWrapper.android()),
      null,
      PlatformWrapper.android(),
    );

    await mgr.waitForInitialized();
    // Now we should have had an error.
    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.storeState.shouldShowAds(), initialShouldShowAds);
    expect(mgr.pluginErrorMsg, contains('error on get available purchases'));

    await mgr.tryToRecoverFromError();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);
    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(mgr.storeState.shouldShowAds(), isFalse);
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

    // getAvailablePurchases. We'll use an acked item so that we don't have to
    // worry about finalizing transactions.
    var pluginGetAvailablePurchasesResult = Completer<List<PurchasedItem>>();
    when(plugin.getAvailablePurchases())
        .thenAnswer((_) => pluginGetAvailablePurchasesResult.future);

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
      TestStoreState.defaultState(true, PlatformWrapper.android()),
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);

    initResult.complete('cxn is live');
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    pluginGetAvailablePurchasesResult.complete([]);

    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    subs.complete([items.forOneYear]);

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    await mgr.waitForInitialized();

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(mgr.storeState.shouldShowAds(), isTrue);

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);

    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    mgr.requestPurchase(items.forLife.productId);
    await TestUtil.waitUntilTrue(() => mgr.storeState.noAdsForever.isOwned());
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.storeState.shouldShowAds(), isFalse);
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

    // getAvailablePurchases. We'll use an acked item so that we don't have to
    // worry about finalizing transactions.
    var pluginGetAvailablePurchasesResult = Completer<List<PurchasedItem>>();
    when(plugin.getAvailablePurchases())
        .thenAnswer((_) => pluginGetAvailablePurchasesResult.future);

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
      TestStoreState.defaultState(true, PlatformWrapper.ios()),
      null,
      PlatformWrapper.ios(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);

    initResult.complete('cxn is live');

    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);

    var result = mgr.getAvailablePurchases(true);

    expect(mgr.isLoaded, isFalse);

    pluginGetAvailablePurchasesResult.complete([]);

    await result;

    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    subs.complete([items.forOneYear]);
    await mgr.getAvailableProducts(true);

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.getTitle(), equals('Title One Year'));
    expect(mgr.storeState.shouldShowAds(), isTrue);

    expect(mgr.isLoaded, isTrue);
    expect(mgr.isStillInitializing, isFalse);

    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    mgr.requestPurchase(items.forLife.productId);
    await TestUtil.waitUntilTrue(() => mgr.storeState.noAdsForever.isOwned());
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.storeState.shouldShowAds(), isFalse);
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

    // getAvailablePurchases. We'll use an acked item so that we don't have to
    // worry about finalizing transactions.
    var pluginGetAvailablePurchasesResult = Completer<List<PurchasedItem>>();
    when(plugin.getAvailablePurchases())
        .thenAnswer((_) => pluginGetAvailablePurchasesResult.future);

    PurchaseResult forLifeError = MockPurchaseResult();
    when(forLifeError.message).thenReturn('error purchasing');

    var products = Completer<List<IAPItem>>();
    var subs = Completer<List<IAPItem>>();

    when(plugin.getProducts(any)).thenAnswer((_) => products.future);
    when(plugin.getSubscriptions(any))
        .thenAnswer((realInvocation) => subs.future);

    when(plugin.requestPurchase(any)).thenAnswer((realInvocation) async {
      String sku = realInvocation.positionalArguments[0];
      if (sku == 'remove_ads_onetime') {
        purchaseErrorStream.add(forLifeError);
      } else {
        throw Exception('unrecognized sku: $sku');
      }
    });

    // let it begin...
    IAPManager<TestStoreState> mgr = IAPManager<TestStoreState>(
      plugin,
      TestStoreState.defaultState(true, PlatformWrapper.android()),
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);

    initResult.complete('cxn is live');
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    pluginGetAvailablePurchasesResult.complete([]);

    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    subs.complete([]);

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    await mgr.waitForInitialized();

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.shouldShowAds(), isTrue);

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
    expect(mgr.storeState.shouldShowAds(), isTrue);
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

    // getAvailablePurchases. We'll use an acked item so that we don't have to
    // worry about finalizing transactions.
    var pluginGetAvailablePurchasesResult = Completer<List<PurchasedItem>>();
    when(plugin.getAvailablePurchases())
        .thenAnswer((_) => pluginGetAvailablePurchasesResult.future);

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
      TestStoreState.defaultState(true, PlatformWrapper.android()),
      null,
      PlatformWrapper.android(),
    );
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);
    expect(mgr.storeState.shouldShowAds(), isTrue);

    initResult.complete('cxn is live');
    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    pluginGetAvailablePurchasesResult.complete([]);

    _MockedIAPItems items = _MockedIAPItems();
    products.complete([items.forLife]);
    subs.complete([]);

    expect(mgr.isLoaded, isFalse);
    expect(mgr.isStillInitializing, isTrue);

    await mgr.waitForInitialized();

    expect(mgr.storeState.noAdsForever.getTitle(), equals('Title One Time'));
    expect(mgr.storeState.shouldShowAds(), isTrue);

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

    bool calledAvailablePurchases = false;
    when(plugin.getAvailablePurchases()).thenAnswer((_) async {
      if (calledAvailablePurchases) {
        throw Exception('getAvailablePurchases called more than once');
      }
      calledAvailablePurchases = true;
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
      TestStoreState.defaultState(true, PlatformWrapper.android()),
      notifyListenersCallback,
      PlatformWrapper.android(),
    );

    await mgr.waitForInitialized();
    expect(calledAvailablePurchases, isTrue);

    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);

    // So now we should have received a pending purchase. Let's complete with
    // the completed purchase that needs an ack.
    notifyListenersCalled = false;
    purchaseUpdatedStream.add(needsAck);
    await TestUtil.waitUntilTrue(() => notifyListenersCalled);

    // Let everything complete.
    expect(ackedAndroid, true);

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isOwned);
    expect(mgr.storeState.shouldShowAds(), isFalse);
  });

  test('no duplicate calls to getAvailablePurchases', () async {
    // We need this test because the plugin behaves in a weird way when
    // receiving multiple calls, at least on iOS. We ran into a situation
    // where, if call A is in flight and call B is made, the plugin returns
    // the results on call B. Call A is then left hanging and never returns.
    // This is bad news. It also suggests that perhaps we should have a
    // timeout property at some point...
    PurchasedItem oneYear = MockPurchasedItem();
    when(oneYear.transactionId).thenReturn('txn-id-1');
    when(oneYear.purchaseStateAndroid).thenReturn(PurchaseState.purchased);
    when(oneYear.isAcknowledgedAndroid).thenReturn(true);
    when(oneYear.productId).thenReturn('remove_ads_oneyear');

    PurchasedItem forever = MockPurchasedItem();
    when(forever.transactionId).thenReturn('txn-id-1');
    when(forever.purchaseStateAndroid).thenReturn(PurchaseState.purchased);
    when(forever.isAcknowledgedAndroid).thenReturn(true);
    when(forever.productId).thenReturn('remove_ads_onetime');

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    var availablePurchasesResultDuringInit = Completer<List<PurchasedItem>>();
    // We need to make sure we release the lock.
    var availablePurchasesResultAfterInit = Completer<List<PurchasedItem>>();

    int numTimesCalledgetAvailablePurchases = 0;
    bool doneInitializing = false;
    var answergetAvailablePurchases = () async {
      numTimesCalledgetAvailablePurchases++;
      if (numTimesCalledgetAvailablePurchases == 1) {
        return availablePurchasesResultDuringInit.future;
      }
      if (doneInitializing) {
        return availablePurchasesResultAfterInit.future;
      }
      throw Exception('called availablePurchases > 1 time');
    };

    // Start showing ads, then make sure we stop showing ads once we have
    // purchases.
    TestIAPManager mgr = _buildNeedsInitializeIAPManager(
      mockedPlugin: plugin,
      initialState:
          TestStoreState.defaultState(true, PlatformWrapper.android()),
      answerGetAvailablePurchases: answergetAvailablePurchases,
      answerGetProducts: () => Future.value([]),
      answerGetSubscriptions: () => Future.value([]),
      platformWrapper: PlatformWrapper.android(),
    );

    // Now, initialize has called getAvailablePurchases. We are blocked on that
    // completing.
    await TestUtil.waitUntilTrue(
        () => numTimesCalledgetAvailablePurchases == 1);

    expect(mgr.isLoaded, isFalse);
    expect(mgr.storeState.shouldShowAds(), isTrue);
    expect(mgr.storeState.noAdsForever.owned, isUnknown);
    expect(mgr.storeState.noAdsOneYear.owned, isUnknown);
    expect(mgr.pluginErrorMsg, isNull);

    // This should return immediately. It's a no-op b/c we are already
    // waiting for a getAvailablePurchases request.
    await mgr.getAvailablePurchases(true);
    expect(mgr.pluginErrorMsg, isNull);

    // And now return the getAvailablePurchases with our items.
    availablePurchasesResultDuringInit.complete([oneYear]);

    // Let everything complete.
    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isOwned);
    expect(mgr.storeState.shouldShowAds(), isFalse);
    expect(mgr.pluginErrorMsg, isNull);

    doneInitializing = true;

    // And now we make sure we have released the lock on getAvailablePurchases.
    var result = mgr.getAvailablePurchases(true);
    expect(mgr.isLoaded, isFalse);
    expect(mgr.pluginErrorMsg, isNull);

    availablePurchasesResultAfterInit.complete([forever]);

    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isOwned);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.storeState.shouldShowAds(), isFalse);
    expect(mgr.pluginErrorMsg, isNull);
  });

  test('during initialize no duplicate calls to products', () async {
    var items = _MockedIAPItems();

    IAPPlugin3PWrapper plugin = MockPluginWrapper();

    var getProductsResultDuringInit = Completer<List<IAPItem>>();
    // We need to make sure we release the lock.
    var getProductsResultAfterInit = Completer<List<IAPItem>>();

    int numTimesCalledGetProducts = 0;
    bool doneInitializing = false;
    var answerGetProducts = () async {
      numTimesCalledGetProducts++;
      if (numTimesCalledGetProducts == 1) {
        return getProductsResultDuringInit.future;
      }
      if (doneInitializing) {
        return getProductsResultAfterInit.future;
      }
      throw Exception('called getProducts > 1 time');
    };

    // Start showing ads, then make sure we stop showing ads once we have
    // purchases.
    TestIAPManager mgr = _buildNeedsInitializeIAPManager(
      mockedPlugin: plugin,
      initialState:
          TestStoreState.defaultState(false, PlatformWrapper.android()),
      answerGetAvailablePurchases: () => Future.value([]),
      answerGetProducts: answerGetProducts,
      answerGetSubscriptions: () => Future.value([]),
      platformWrapper: PlatformWrapper.android(),
    );

    // Now, initialize has called getAvailablePurchases. We are blocked on that
    // completing.
    await TestUtil.waitUntilTrue(() => numTimesCalledGetProducts == 1);

    expect(mgr.isLoaded, isFalse);
    expect(mgr.storeState.shouldShowAds(), isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsForever.product, isNull);
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.product, isNull);
    expect(mgr.pluginErrorMsg, isNull);

    // This should return immediately. It's a no-op b/c we are already
    // waiting for a getAvailablePurchases request.
    await mgr.getAvailableProducts(true);
    expect(mgr.pluginErrorMsg, isNull);

    // And now return the getAvailablePurchases with our items.
    getProductsResultDuringInit.complete([items.forLife]);

    // Let everything complete.
    await mgr.waitForInitialized();

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsForever.product, isNotNull);
    expect(mgr.storeState.noAdsForever.product.title, equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.product, isNull);
    expect(mgr.storeState.shouldShowAds(), isTrue);
    expect(mgr.pluginErrorMsg, isNull);

    doneInitializing = true;

    // And now we make sure we have released the lock on getAvailablePurchases.
    var result = mgr.getAvailableProducts(true);
    expect(mgr.isLoaded, isFalse);
    expect(mgr.pluginErrorMsg, isNull);

    getProductsResultAfterInit.complete([items.forOneYear]);

    await result;

    expect(mgr.isLoaded, isTrue);
    expect(mgr.storeState.noAdsForever.owned, isNotOwned);
    expect(mgr.storeState.noAdsForever.product, isNotNull);
    expect(mgr.storeState.noAdsForever.product.title, equals('Title One Time'));
    expect(mgr.storeState.noAdsOneYear.owned, isNotOwned);
    expect(mgr.storeState.noAdsOneYear.product, isNotNull);
    expect(mgr.storeState.noAdsOneYear.product.title, equals('Title One Year'));
    expect(mgr.storeState.shouldShowAds(), isTrue);
    expect(mgr.pluginErrorMsg, isNull);
  });
}
