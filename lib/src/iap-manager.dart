library iap_manager;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:http/http.dart' as http;
import 'package:iap_manager/src/platform-wrapper.dart';
import 'package:iap_manager/src/store-state.dart';

import 'iap-plugin-3p-wrapper.dart';

const int _IOS_STATUS_IS_SANDBOX = 21007;
const int _IOS_STATUS_IS_OK = 0;

extension IAPManagerUtil on PurchasedItem {
  String logFriendlyToString() {
    return 'PurchasedItem{'
        '  productId: ${this.productId},'
        '  transactionId: ${this.transactionId},'
        '  isAcknowledgeAndroid: ${this.isAcknowledgedAndroid},'
        '  purchaseStateAndroid: ${this.purchaseStateAndroid},'
        '  transactionStateIOS: ${this.transactionStateIOS},'
        '}';
  }

  /// Return true if the item is acknowledged. This is safer than the default
  /// property, because this can never return null. It also is smart enough
  /// to check in transactionReceipt for acknowledged, which is set at least
  /// on subscriptions.
  bool isAcknowledgedAndroidSafe() {
    if (this.isAcknowledgedAndroid != null) {
      return this.isAcknowledgedAndroid;
    }

    // Otherwise, try to get state from the transactionReceipt. See the test
    // files for examples of responses from the plugin that makes this
    // necessary, as well as this blogpost:
    //
    // https://medium.com/bosc-tech-labs-private-limited/how-to-implement-subscriptions-in-app-purchase-in-flutter-7ce8906e608a
    //
    // And this PR:
    //
    // https://github.com/dooboolab/flutter_inapp_purchase/issues/234
    if (this.transactionReceipt == null || this.transactionReceipt == '') {
      throw Exception('cannot determine if purchase is acknowledged, no '
          'transactionReceipt');
    }

    Map<String, dynamic> parsed = json.decode(this.transactionReceipt);
    if (!parsed.containsKey('acknowledged')) {
      throw Exception('cannot determine if purchase is acknowledged, no '
          'acknowledged key transactionReceipt');
    }

    return parsed['acknowledged'];
  }
}

/// Manages in-app purchases. This is essentially a wrapper around the
/// libraries that we are using, hoping to abstract away any issues so that
/// future decisions to swap them should be easy.
class IAPManager<T extends StateFromStore> extends ChangeNotifier {
  IAPPlugin3PWrapper _plugin;
  PlatformWrapper _platformWrapper;

  StreamSubscription<PurchasedItem> _purchaseUpdatedSubscription;
  StreamSubscription<PurchaseResult> _purchaseErrorSubscription;
  // An error message that we get from the plugin. This should be expected to
  // be things like network errors or unsupported devices, as opposed to
  // something going wrong with a purchase itself, which we would expect in a
  // case where everything is working but we get an error, like for a
  // declined card.
  String _pluginErrorMsg;

  /// This comes via the AppstoreConnect screen and is used for validating
  /// subscriptions.
  final String _iosSharedSecret;
  T _storeState;
  bool _isLoaded = false;
  bool _subscribedToStreams = false;
  bool _isStillInitializing = false;

  /// True if a getAvailablePurchases request is in flight.
  bool _isFetchingAvailablePurchases = false;

  /// True if a getAvailableProducts request is in flight.
  bool _isFetchingProducts = false;

  // Used to facilitate waiting on initialize() to complete, which is kind of
  // tricky since we call it async in a sync constructor.
  Completer<void> _doneInitializingCompleter;

  /// This can optionally be provided to callers, typically for testing, and
  /// is invoked when notifyListeners is invoked.
  void Function() _notifyListenersInvokedCallback;

  /// If this is false, then the plugin can't be used. The plugin throws
  /// errors if initConnection didn't complete.
  bool _cxnIsInitialized = false;

  /// True if IAPManager should log verbosely even in release mode. Normally
  /// logging is suppressed in release mode. This can be useful if you are
  /// debugging store interactions.
  final bool logInReleaseMode;

  T get storeState => _storeState;
  bool get isLoaded => _isLoaded;
  bool get isStillInitializing => _isStillInitializing;
  bool get hasPluginError => _pluginErrorMsg != null;
  String get pluginErrorMsg => _pluginErrorMsg;

  IAPManager(
      this._plugin,
      this._iosSharedSecret,
      this._storeState,
      void Function() notifyListenersInvokedCallback,
      PlatformWrapper platformWrapper,
      {this.logInReleaseMode = false}) {
    _notifyListenersInvokedCallback = notifyListenersInvokedCallback;
    _platformWrapper = platformWrapper ?? PlatformWrapper();

    initialize();
  }

  void _maybeLog(String msg) {
    if (logInReleaseMode) {
      print('IAPManager: $msg');
    } else {
      debugPrint('IAPManager: $msg');
    }
  }

  /// This calls notifyListeners and also informs callers when
  /// notifyListeners has been invoked. This facilitates testing, eg. In
  /// general, we should avoid calls to notifyListners() in this class and
  /// wrap everything in this call instead.
  void _notifyListenersWithReporter() {
    _maybeLog('going to notify listeners, loaded: $_isLoaded');
    notifyListeners();
    if (_notifyListenersInvokedCallback != null) {
      _notifyListenersInvokedCallback();
    }
  }

  /// This future completes when the manager is initialized and ready for use.
  Future<void> waitForInitialized() {
    return _doneInitializingCompleter.future;
  }

  Future<void> initialize() async {
    _maybeLog('calling initialize');
    // This is largely taken from the sample app.
    // https://github.com/dooboolab/flutter_inapp_purchase/blob/master/example/README.md
    if (_plugin == null) {
      _maybeLog('IAP plugin not set, doing nothing');
      return;
    }

    if (_isStillInitializing) {
      _maybeLog('initialize() called but already initializing, '
          'doing nothing');
      return;
    }

    _isStillInitializing = true;
    _doneInitializingCompleter = Completer<void>();
    _maybeLog('initialize(): setting _isLoaded = false');
    _isLoaded = false;

    if (!_cxnIsInitialized) {
      try {
        await _plugin.initConnection();
        _cxnIsInitialized = true;
        // We are leaving this here because it is an easy way to trigger an
        // error, although I don't know if it should.
        // dynamic consumeResult = await _plugin.consumeAllItems();
        // _printToLog('consumed all items: $consumeResult');
      } catch (e) {
        _maybeLog('initConnection: ugly universal catch block: $e');
        _pluginErrorMsg = e.toString();
        _isLoaded = true;
        _isStillInitializing = false;
        _doneInitializingCompleter.complete();
        _notifyListenersWithReporter();
        return;
      }
    }

    _maybeLog('initialized connection');

    // Do this check so that initialize is safe to call twice in an effort to
    // recover from errors.
    if (!_subscribedToStreams) {
      _purchaseUpdatedSubscription = _plugin
          .getPurchaseUpdatedStream()
          .listen((PurchasedItem purchasedItem) async {
        _maybeLog('got a new purchase: $_storeState');

        try {
          await _handlePurchase(purchasedItem, Set<String>());
        } catch (e) {
          _maybeLog('error handling purchase: $e');
          _pluginErrorMsg = e.toString();
        }

        _notifyListenersWithReporter();
      });

      _purchaseErrorSubscription =
          _plugin.getPurchaseErrorStream().listen((PurchaseResult errorResult) {
        if (errorResult.code == 'E_USER_CANCELLED') {
          // No-op: this is what happens when the user clicks out of the
          // dialog. We don't want to treat this as an error to show
          // them, because to them it's not really an error.
          return;
        }
        _storeState = _storeState.takeError(errorResult);
        _maybeLog('new error: $_storeState');
        _notifyListenersWithReporter();
      });

      _subscribedToStreams = true;
    }

    await getAvailablePurchases(false);
    // We don't actually need this here, but it's kind of a hassle to do it
    // intelligently otherwise.
    await getAvailableProducts(false);

    _isLoaded = true;
    _maybeLog('done initializing: $_isLoaded');
    _isStillInitializing = false;
    _doneInitializingCompleter.complete();
    _notifyListenersWithReporter();
  }

  /// Note that this method can throw errors! This allows the caller to
  /// handle it, but callers should be aware of this and wrap in a try.
  ///
  /// Returns true if the state has already been updated to account for this
  /// purchase. If not, the caller should update state accordingly (eg. by
  /// setting to NOT_OWNED due to it being a pending purchase).
  ///
  /// The extra parameter here is for iOS. IIUC, handling most purchases is
  /// idempotent (so we can call as much as we want with different purchases
  /// and still get the right state) and cheap. The one exception is handling
  /// subscriptions on iOS, where we need to use the plugin to call the server.
  ///
  /// Any subscription in a given batch (eg from getAvailablePurchases()) we
  /// should only verify the number of times that we have to. So say that
  /// someone has purchased the same hourly subscription 10x. Validation of
  /// any ONE of those subs should, I believe, give us the same
  /// information--because we are asking Apple to give us only the latest sub
  /// for that ID.
  ///
  /// However, we want to call finishTransaction() on all of them in case we
  /// get a historical subscription first, and then the second in the batch
  /// is the newer one. Any item whose ID is in the iosValidatedProductIDs
  /// parameter will have finish called but will not issue a verification
  /// call to Apple's back end. Callers should expect this to be populated as
  /// the method progresses. My understanding of this is not 100%.
  ///
  /// This came up in testing where we got six back at a time, eg, and all were
  /// expired. One query from any of them was enough to get the latest state.
  /// See notes in the relevant methods.
  Future<bool> _handlePurchase(
      PurchasedItem item, Set<String> iosValidatedSubProductIDs) async {
    if (_platformWrapper.isAndroid) {
      return await _handlePurchaseAndroid(item);
    }
    if (_platformWrapper.isIOS) {
      return await _handlePurchaseIOS(item, iosValidatedSubProductIDs);
    }

    throw Exception(
        'unsupported platform: ${_platformWrapper.operatingSystem}');
  }

  Future<bool> _handlePurchaseAndroid(PurchasedItem item) async {
    _maybeLog(
        '_handlePurchaseAndroid(): purchaseStateAndroid: ${item.purchaseStateAndroid}');
    _maybeLog(
        '_handlePurchaseAndroid(): isAcknowledgedAndroidSafe: ${item.isAcknowledgedAndroidSafe()}');
    // Here are some example items from the log (these were returned by
    // getAvailablePurchases).
    // I/flutter (31748): XXX IAPManager: got purchaseHistory with [1] purchases
    // I/flutter (31748): XXX IAPManager: found a purchased item: PurchasedItem{  productId: remove_ads_onetime,  transactionId: GPA.3372-8155-6663-62256,  isAcknowledgeAndroid: true,  purchaseStateAndroid: PurchaseState.purchased,  transactionStateIOS: null,}
    // I/flutter (31748): XXX IAPManager: full details: productId: remove_ads_onetime, transactionId: GPA.3372-8155-6663-62256, transactionDate: 2021-02-28T19:08:32.125, transactionReceipt: {"orderId":"GPA.3372-8155-6663-62256","packageName":"com.foobar.baz","productId":"remove_ads_onetime","purchaseTime":1614568112125,"purchaseState":0,"purchaseToken":"edmocmijkpapdflcfmfflomj.AO-J1Oxlg7UjNrGQw2U7oOH9LdKk1Evqrk1IcEAvrrVC96r_bpcreAlpi46YczmLvf2gcGzem7WbcRB5puon8qaAxdDaNqRyng","acknowledged":true}, purchaseToken: edmocmijkpapdflcfmfflomj.AO-J1Oxlg7UjNrGQw2U7oOH9LdKk1Evqrk1IcEAvrrVC96r_bpcreAlpi46YczmLvf2gcGzem7WbcRB5puon8qaAxdDaNqRyng, orderId: GPA.3372-8155-6663-62256, dataAndroid: null, signatureAndroid: ACsvcpfT0zz3f3r0OWWZPpTk6vz6vYjNcN8/ZZH3TaNal8RbHGNJaatGdGS6Q4pTnbqRXYx6ISdz52+5rKPuXXg0TEa72HWPPvi5Ivwq/6hlfEZVsw1UwnqhLeSLdsGCl1VtYdLgVK0vdtsRZsRoDgcod1A4C/OB6vENAIuKuQEnvTKXk62fmW1TBe2RmsAxA6dG4k+7myipBZyFSzNZ7qfelgOnQuRe7hw91EqcIFFbPoFh+Sc8GG5JyxacWgY+96ERBUVkLGXz4/zt7GrsL2hg8HNdXem6H4VgdPEjZ/jjh+s4L+g8R0hP8ynd0nLQG8wHJaMSZP

    bool result = false;

    if (item.purchaseStateAndroid == PurchaseState.purchased) {
      if (!item.isAcknowledgedAndroidSafe()) {
        _maybeLog('_handlePurchaseAndroid(): need to ack purchase');
        // "Lastly, if you want to abstract three different methods into one,
        // consider using finishTransaction method."
        // https://pub.dev/packages/flutter_inapp_purchase
        String finishTxnResult = await _plugin.finishTransaction(item);
        _maybeLog('_handlePurchaseAndroid(): acknowledged '
            'successfully: '
            '$finishTxnResult');
      } else {
        _maybeLog('_handlePurchaseAndroid(): do not need to ack purchase');
      }
      // It's been purchased and we own it.
      _storeState = _storeState.takePurchase(item);
      result = true;
    }

    return result;
  }

  Future<bool> _handlePurchaseIOS(
      PurchasedItem item, Set<String> iosValidatedSubProductIDs) async {
    bool isIOSAndFutureSubscriptionCallsUnnecessary = false;
    bool result = false;
    if (item.transactionStateIOS == TransactionState.purchased ||
        item.transactionStateIOS == TransactionState.restored) {
      // Apple says to finishTransaction after validation:
      // https://developer.apple.com/documentation/storekit/skpaymentqueue/1506003-finishtransaction
      if (_storeState.itemIsSubscription(item)) {
        if (!iosValidatedSubProductIDs.contains(item.productId)) {
          // Subscriptions are special cased on iOS.
          _maybeLog('_handlePurchaseIOS(): found subscription, '
              'going to validate'
              ' receipt');
          try {
            bool ownSub = await _iosSubscriptionIsActive(item);
            _maybeLog('_handlePurchaseIOS(): sub is owned: $ownSub');
            if (ownSub) {
              _storeState = _storeState.takePurchase(item);
              result = true;
            } else {
              _storeState = _storeState.removePurchase(item);
              result = true;
            }
            isIOSAndFutureSubscriptionCallsUnnecessary = true;
          } catch (e) {
            _maybeLog('_handlePurchaseIOS(): ugly universal catch '
                'block: $e');
            _storeState =
                _storeState.takePurchaseUnknown(item, errMsg: e.toString());
            result = true;
          }
        } else {
          _maybeLog('_handlePurchaseIOS(): already validated '
              'subscription '
              'with id: ${item.productId}');
        }
      } else {
        // Anything we get that is purchased/restored and not a subscription is
        // an owned purchase.
        _storeState = _storeState.takePurchase(item);
        result = true;
      }

      // We need to call finishTransaction on all purchases I think, both
      // purchased and restored, subs and non-consumables.
      await _plugin.finishTransaction(item);
    }

    if (isIOSAndFutureSubscriptionCallsUnnecessary) {
      iosValidatedSubProductIDs.add(item.productId);
    }

    return result;
  }

  /// There is no way to tell that a subscription is active on iOS without
  /// issues a call via the transaction receipt. Note that this method calls
  /// the plugin without a try/catch--callers should try/catch.
  Future<bool> _iosSubscriptionIsActive(PurchasedItem item) async {
    // We can either validate against the sandbox (for test accounts) or
    // against production. The apple docs say always first validate against
    // production, only trying the sandbox if there is a specific error code.
    // * https://stackoverflow.com/questions/9677193/ios-storekit-can-i-detect-when-im-in-the-sandbox
    // * https://developer.apple.com/library/archive/technotes/tn2413/_index.html#//apple_ref/doc/uid/DTS40016228-CH1-RECEIPTURL

    // Always use prod first--see above.
    var json = await _validateTransactionIOSHelper(item, false);
    if (_statusEquals(json, _IOS_STATUS_IS_SANDBOX)) {
      _maybeLog('item was sandbox purchase');
      json = await _validateTransactionIOSHelper(item, true);
    }
    if (!_statusEquals(json, _IOS_STATUS_IS_OK)) {
      throw Exception('iOS subscription validation status not ok: '
          '${json['status']}');
    }
    _maybeLog('parsed validation receipt for subscription with sku: '
        '{${item.productId}');
    return _validationResponseIndicatesActiveSubscription(json);
  }

  bool _validationResponseIndicatesActiveSubscription(
      Map<String, dynamic> body) {
    // The presence of expiration_intent is enough to tell us that this is
    // expired. If it is absent, I believe that means either that we do not
    // own the subscription or this wasn't a properly formed request
    // initially, eg maybe not a subscription.
    //
    // https://developer.apple.com/documentation/appstorereceipts/responsebody/pending_renewal_info
    // expiration_intent:
    // The reason a subscription expired. This field is only present for a
    // receipt that contains an expired auto-renewable subscription.
    //
    // We are looking for something like this (the irrelevant bits trimmed):
    // {
    //   status: 0,
    //   pending_renewal_info: [
    //     {
    //       expiration_intent: "1", // if this key present, it is expired
    //     }
    //   ],
    // }
    if (body == null) {
      return false;
    }
    List<dynamic> pendingRenewalInfoList = body['pending_renewal_info'];
    if (pendingRenewalInfoList == null) {
      _maybeLog('no pending_renewal_info property, returning '
          'false');
      return false;
    }
    if (pendingRenewalInfoList.length < 1) {
      _maybeLog('pending_renewal_info set, but no empty list');
      return false;
    }
    if (pendingRenewalInfoList.length > 1) {
      _maybeLog('pending_renewal_info.length > 1, which is unexpected');
    }
    Map<String, dynamic> pendingRenewalInfo =
        pendingRenewalInfoList[0] as Map<String, dynamic>;
    _maybeLog('pending_renewal_info successfully parsed: $pendingRenewalInfo');
    // If non-null, then it has been canceled.
    return pendingRenewalInfo['expiration_intent'] == null;
  }

  bool _statusEquals(Map<String, dynamic> json, int statusCode) {
    if (json == null || json['status'] == null) {
      return false;
    }
    return json['status'] == statusCode || json['status'] == '$statusCode';
  }

  Future<Map<String, dynamic>> _validateTransactionIOSHelper(
      PurchasedItem item, bool useSandbox) async {
    var reqBody = Map<String, String>();
    reqBody['receipt-data'] = item.transactionReceipt;
    // I got this from the appstoreconnect IAP section.
    reqBody['password'] = this._iosSharedSecret;
    reqBody['exclude-old-transactions'] = 'true';

    http.Response resp =
        await _plugin.validateTransactionIOS(reqBody, useSandbox);
    if (resp.statusCode != HttpStatus.ok) {
      throw Exception('could not validate iOS transaction, status code: '
          '${resp.statusCode}');
    }
    Map<String, dynamic> json = jsonDecode(resp.body);
    return json;
  }

  @override
  Future<void> dispose() async {
    super.dispose();
    if (_cxnIsInitialized) {
      await _plugin.endConnection();
    }
    _purchaseUpdatedSubscription?.cancel();
    _purchaseErrorSubscription?.cancel();
  }

  Future<void> _resetState() async {
    _maybeLog('_resetState');
    _purchaseUpdatedSubscription?.cancel();
    _purchaseUpdatedSubscription = null;
    _purchaseErrorSubscription?.cancel();
    _purchaseErrorSubscription = null;

    _subscribedToStreams = false;
    _isStillInitializing = false;
    _isLoaded = false;
    _isFetchingAvailablePurchases = false;
    _isFetchingProducts = false;

    _pluginErrorMsg = null;

    if (_cxnIsInitialized) {
      try {
        await _plugin.endConnection();
      } catch (e) {
        _maybeLog('resetState(): ugly universal catch block, $e');
      }
    }
    _cxnIsInitialized = false;
  }

  /// Get available purchases from the store. When this future completes, the
  /// StateFromStore will contain any results that were fetched. Purchases
  /// will be acked, validated, and finished, as appropriate for the platform.
  ///
  /// This method will also call notifyListeners as appropriate, so if you are
  /// using it as a Provider, you do not need to await the future.
  Future<void> getAvailablePurchases(bool takeOwnershipOfLoading) async {
    _maybeLog('getAvailablePurchases'
        '(takeOwnershipOfLoading: $takeOwnershipOfLoading)');
    if (!_cxnIsInitialized) {
      _maybeLog('getAvailablePurchases called but cxn not initialized');
      return;
    }

    if (_isFetchingAvailablePurchases) {
      _maybeLog('getAvailablePurchases called but already in '
          'flight, ignoring');
      return;
    }
    _isFetchingAvailablePurchases = true;

    if (takeOwnershipOfLoading) {
      _isLoaded = false;
    }

    // Don't reset _hasFetchedPurchases. As long as we've fetched them once,
    // that is enough.
    _notifyListenersWithReporter();
    try {
      List<PurchasedItem> purchases = await _plugin.getAvailablePurchases();
      _maybeLog('got availablePurchases with [${purchases.length}] '
          'purchases');

      // See the long comment on _handlePurchase about what this is doing.
      Set<String> isIOSAndFutureSubscriptionCallsUnnecessaryIDs = Set<String>();
      // These are all the products that we've dealt with tin the
      // handlePurchase method. Anything not in this should be considered
      // NOT_OWNED.
      Set<String> handledPurchaseIDs = Set<String>();
      for (PurchasedItem item in purchases) {
        _maybeLog('found a purchased item: ${item.logFriendlyToString()}');
        _maybeLog('full details: $item');

        bool updatedState = await _handlePurchase(
            item, isIOSAndFutureSubscriptionCallsUnnecessaryIDs);
        if (updatedState) {
          handledPurchaseIDs.add(item.productId);
        }
      }
      _storeState = _storeState.setNotOwnedExcept(handledPurchaseIDs);
      _maybeLog('new state: $_storeState');
    } catch (e) {
      _maybeLog('getAvailablePurchases: ugly universal catch '
          'block: '
          '$e');
      _pluginErrorMsg = e.toString();
    }

    if (takeOwnershipOfLoading) {
      _maybeLog('getAvailablePurchases setting _isLoaded = true');
      _isLoaded = true;
    }

    _isFetchingAvailablePurchases = false;

    _maybeLog('loaded purchases: $_storeState');
    _notifyListenersWithReporter();
  }

  /// Get available products from the store. When this future completes, the
  /// StateFromStore will contain any results that were fetched.
  ///
  /// This method will also call notifyListeners as appropriate, so if you are
  /// using it as a Provider, you do not need to await the future.
  Future<void> getAvailableProducts(bool takeOwnershipOfLoading) async {
    _maybeLog('getAvailableProducts'
        '(takeOwnershipOfLoading: $takeOwnershipOfLoading)');
    if (!_cxnIsInitialized) {
      _maybeLog('getAvailableProducts called but cxn not '
          'initialized');
      return;
    }

    if (_isFetchingProducts) {
      _maybeLog('getAvailableProducts called but already in '
          'flight, ignoring');
      return;
    }
    _isFetchingProducts = true;

    if (takeOwnershipOfLoading) {
      _isLoaded = false;
    }

    try {
      // Note that on iOS we run the risk of getting duplicate products
      // here, depending on the iOS version. That's ok, though, b/c afaict
      // taking the ID as unique will essentially make any changes idempotent.
      List<List<IAPItem>> fetchResult = await Future.wait([
        _plugin.getProducts(_storeState.getNonConsumableProductIDs()),
        _plugin.getSubscriptions(_storeState.getSubscriptionProductIDs()),
      ]);

      // Remove duplicates, because on iOS products and subscriptions aren't
      // different.
      List<IAPItem> items =
          fetchResult.expand((i) => i).toList().toSet().toList();
      _maybeLog('fetched available products. length: ${items.length}');
      _maybeLog('fetched available products: $items');

      for (IAPItem item in items) {
        _storeState = _storeState.takeAvailableProduct(item);
      }
    } catch (e) {
      _maybeLog('getAvailableProducts(): ugly universal catch: $e');
      _pluginErrorMsg = e.toString();
    }

    if (takeOwnershipOfLoading) {
      _maybeLog('loaded products: $_storeState');
      _isLoaded = true;
    }

    _isFetchingProducts = false;

    _notifyListenersWithReporter();
  }

  /// If a plugin error is set on this object, this method resets the state
  /// and tries to reinitialize the connection. You can use this to try and
  /// recover from transient errors.
  Future<void> tryToRecoverFromError() async {
    await _resetState();
    _notifyListenersWithReporter();

    await initialize();
    // We're calling this here b/c we're assuming that his will only ever be
    // called from the purchase screen. This is kind of lazy, but we think
    // it's ok because we only expect to be able to act on one of these
    // errors from the IAP screen, where we will want to fetch the products.
    await getAvailableProducts(true);
  }

  /// Remove a purchase error. Purchase errors do not represent a problem
  /// with the plugin--they are a natural potential state, eg if a card was
  /// declined.
  void dismissPurchaseError() {
    _storeState = _storeState.dismissError();
    _notifyListenersWithReporter();
  }

  /// Request a purchase with the given sku. If there are any plugin errors,
  /// they will be set on pluginErrorMsg. Purchases can complete at any t
  /// ime, so no loading state is indicated after this method has been called.
  Future<dynamic> requestPurchase(String itemSku) async {
    if (!_cxnIsInitialized) {
      _maybeLog('requestPurchase called but cxn not initialized');
      return;
    }
    if (itemSku == null) {
      _maybeLog('requestPurchase: itemSku is null, no-op');
      return;
    }
    _maybeLog('requesting purchase for itemSku: $itemSku');
    try {
      return await _plugin.requestPurchase(itemSku);
    } catch (e) {
      _maybeLog('dismissPurchaseError: ugly universal catch '
          'block: $e');
      _pluginErrorMsg = e.toString();
      _notifyListenersWithReporter();
    }
  }
}
