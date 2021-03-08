library iap_manager;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:iap_manager/src/iap-logger.dart';
import 'package:iap_manager/src/platform-wrapper.dart';
import 'package:iap_manager/src/store-state.dart';

import 'iap-plugin-3p-wrapper.dart';

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

enum PurchaseVerificationStatus {
  /// A valid, owned transaction.
  VALID,

  /// An invalid or un-unknowned transaction.
  INVALID,

  /// Unknown, eg due to a network error.
  UNKNOWN,
}

class PurchaseVerificationResult {
  final PurchaseVerificationStatus status;
  final String errorMessage;

  PurchaseVerificationResult(this.status, this.errorMessage);
}

abstract class PurchaseVerifier {
  Future<PurchaseVerificationResult> verifyPurchase(PurchasedItem item);
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

  /// Verify the transaction for the given item. If this is not set,
  /// transactions are not verified, and the result of the query is trusted.
  PurchaseVerifier _purchaseVerifier;

  IAPLogger _logger;

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
      this._storeState,
      void Function() notifyListenersInvokedCallback,
      PlatformWrapper platformWrapper,
      {this.logInReleaseMode = false,
      PurchaseVerifier purchaseVerifier}) {
    _notifyListenersInvokedCallback = notifyListenersInvokedCallback;
    _purchaseVerifier = purchaseVerifier;
    _platformWrapper = platformWrapper ?? PlatformWrapper();
    _logger = IAPLogger('IAPManager', this.logInReleaseMode);

    initialize();
  }

  /// This calls notifyListeners and also informs callers when
  /// notifyListeners has been invoked. This facilitates testing, eg. In
  /// general, we should avoid calls to notifyListners() in this class and
  /// wrap everything in this call instead.
  void _notifyListenersWithReporter() {
    _logger.maybeLog('going to notify listeners, loaded: $_isLoaded');
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
    _logger.maybeLog('calling initialize');
    // This is largely taken from the sample app.
    // https://github.com/dooboolab/flutter_inapp_purchase/blob/master/example/README.md
    if (_plugin == null) {
      _logger.maybeLog('IAP plugin not set, doing nothing');
      return;
    }

    if (_isStillInitializing) {
      _logger.maybeLog('initialize() called but already initializing, '
          'doing nothing');
      return;
    }

    _isStillInitializing = true;
    _doneInitializingCompleter = Completer<void>();
    _logger.maybeLog('initialize(): setting _isLoaded = false');
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
        _logger.maybeLog('initConnection: ugly universal catch block: $e');
        _pluginErrorMsg = e.toString();
        _isLoaded = true;
        _isStillInitializing = false;
        _doneInitializingCompleter.complete();
        _notifyListenersWithReporter();
        return;
      }
    }

    _logger.maybeLog('initialized connection');

    // Do this check so that initialize is safe to call twice in an effort to
    // recover from errors.
    if (!_subscribedToStreams) {
      _purchaseUpdatedSubscription = _plugin
          .getPurchaseUpdatedStream()
          .listen((PurchasedItem purchasedItem) async {
        _logger.maybeLog('got a new purchase: $_storeState');

        try {
          await _handlePurchase(purchasedItem);
        } catch (e) {
          _logger.maybeLog('error handling purchase: $e');
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
        _logger.maybeLog('new error: $_storeState');
        _notifyListenersWithReporter();
      });

      _subscribedToStreams = true;
    }

    // Don't fetch products by default on iOS, because their API is clunkier.
    if (_platformWrapper.isAndroid) {
      await getAvailablePurchases(false);
      await getAvailableProducts(false);
    }

    _isLoaded = true;
    _logger.maybeLog('done initializing: $_isLoaded');
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
  Future<bool> _handlePurchase(PurchasedItem item) async {
    if (_platformWrapper.isAndroid) {
      return await _handlePurchaseAndroid(item);
    }
    if (_platformWrapper.isIOS) {
      return await _handlePurchaseIOS(item);
    }

    throw Exception(
        'unsupported platform: ${_platformWrapper.operatingSystem}');
  }

  Future<bool> _handlePurchaseAndroid(PurchasedItem item) async {
    _logger.maybeLog(
        '_handlePurchaseAndroid(): purchaseStateAndroid: ${item.purchaseStateAndroid}');
    _logger.maybeLog(
        '_handlePurchaseAndroid(): isAcknowledgedAndroidSafe: ${item.isAcknowledgedAndroidSafe()}');
    // Here are some example items from the log (these were returned by
    // getAvailablePurchases).
    // I/flutter (31748): XXX IAPManager: got purchaseHistory with [1] purchases
    // I/flutter (31748): XXX IAPManager: found a purchased item: PurchasedItem{  productId: remove_ads_onetime,  transactionId: GPA.3372-8155-6663-62256,  isAcknowledgeAndroid: true,  purchaseStateAndroid: PurchaseState.purchased,  transactionStateIOS: null,}
    // I/flutter (31748): XXX IAPManager: full details: productId: remove_ads_onetime, transactionId: GPA.3372-8155-6663-62256, transactionDate: 2021-02-28T19:08:32.125, transactionReceipt: {"orderId":"GPA.3372-8155-6663-62256","packageName":"com.foobar.baz","productId":"remove_ads_onetime","purchaseTime":1614568112125,"purchaseState":0,"purchaseToken":"edmocmijkpapdflcfmfflomj.AO-J1Oxlg7UjNrGQw2U7oOH9LdKk1Evqrk1IcEAvrrVC96r_bpcreAlpi46YczmLvf2gcGzem7WbcRB5puon8qaAxdDaNqRyng","acknowledged":true}, purchaseToken: edmocmijkpapdflcfmfflomj.AO-J1Oxlg7UjNrGQw2U7oOH9LdKk1Evqrk1IcEAvrrVC96r_bpcreAlpi46YczmLvf2gcGzem7WbcRB5puon8qaAxdDaNqRyng, orderId: GPA.3372-8155-6663-62256, dataAndroid: null, signatureAndroid: ACsvcpfT0zz3f3r0OWWZPpTk6vz6vYjNcN8/ZZH3TaNal8RbHGNJaatGdGS6Q4pTnbqRXYx6ISdz52+5rKPuXXg0TEa72HWPPvi5Ivwq/6hlfEZVsw1UwnqhLeSLdsGCl1VtYdLgVK0vdtsRZsRoDgcod1A4C/OB6vENAIuKuQEnvTKXk62fmW1TBe2RmsAxA6dG4k+7myipBZyFSzNZ7qfelgOnQuRe7hw91EqcIFFbPoFh+Sc8GG5JyxacWgY+96ERBUVkLGXz4/zt7GrsL2hg8HNdXem6H4VgdPEjZ/jjh+s4L+g8R0hP8ynd0nLQG8wHJaMSZP

    bool result = false;

    if (item.purchaseStateAndroid == PurchaseState.purchased) {
      if (!item.isAcknowledgedAndroidSafe()) {
        _logger.maybeLog('_handlePurchaseAndroid(): need to ack purchase');

        PurchaseVerificationResult verificationResult =
            PurchaseVerificationResult(PurchaseVerificationStatus.VALID, '');
        if (_purchaseVerifier != null) {
          _logger.maybeLog('verifying purchase: $item');
          verificationResult = await _purchaseVerifier.verifyPurchase(item);
          _logger.maybeLog('verification result: $verificationResult');
        } else {
          _logger.maybeLog('not verifying purchase');
        }

        switch (verificationResult.status) {
          case PurchaseVerificationStatus.VALID:
            _logger.maybeLog('_handlerPurchaseAndroid(): verified item');
            String finishTxnResult = await _plugin.finishTransaction(item);
            _logger.maybeLog('_handlePurchaseAndroid(): acknowledged '
                'successfully: '
                '$finishTxnResult');
            // It's been purchased and we own it.
            _storeState = _storeState.takePurchase(item);
            result = true;
            break;
          case PurchaseVerificationStatus.INVALID:
            _logger.maybeLog('_handlerPurchaseAndroid(): item invalid');
            _storeState = _storeState.removePurchase(item,
                errMsg: 'invalid purchase: ${verificationResult.errorMessage}');
            result = true;
            break;
          case PurchaseVerificationStatus.UNKNOWN:
            _logger
                .maybeLog('_handlerPurchaseAndroid(): could not validate item');
            _storeState = _storeState.takePurchaseUnknown(item,
                errMsg: verificationResult.errorMessage);
            result = true;
            break;
        }
      } else {
        _logger
            .maybeLog('_handlePurchaseAndroid(): do not need to ack purchase');
        _storeState = _storeState.takePurchase(item);
        result = true;
      }
    }

    return result;
  }

  Future<bool> _handlePurchaseIOS(PurchasedItem item) async {
    if (item.transactionStateIOS == TransactionState.deferred ||
        item.transactionStateIOS == TransactionState.purchasing) {
      // Do nothing.
      return false;
    }

    bool result = false;

    if (item.transactionStateIOS == TransactionState.purchased ||
        item.transactionStateIOS == TransactionState.restored) {
      PurchaseVerificationResult verificationResult =
          PurchaseVerificationResult(PurchaseVerificationStatus.VALID, '');
      if (_purchaseVerifier != null) {
        _logger.maybeLog('verifying purchase: $item');
        verificationResult = await _purchaseVerifier.verifyPurchase(item);
        _logger.maybeLog('item is valid: $verificationResult');
      } else {
        _logger.maybeLog('not validating purchase');
      }

      switch (verificationResult.status) {
        case PurchaseVerificationStatus.VALID:
          _logger.maybeLog('_handlePurchaseIOS(): verified item');
          _storeState = _storeState.takePurchase(item);
          result = true;
          break;
        case PurchaseVerificationStatus.INVALID:
          _logger.maybeLog('_handlePurchaseIOS(): item invalid');
          _storeState = _storeState.removePurchase(item,
              errMsg: 'invalid purchase: ${verificationResult.errorMessage}');
          result = true;
          break;
        case PurchaseVerificationStatus.UNKNOWN:
          _logger.maybeLog('_handlePurchaseIOS(): could not validate item');
          _storeState = _storeState.takePurchaseUnknown(item,
              errMsg: verificationResult.errorMessage);
          result = true;
          break;
      }
    }

    // We need to call finishTransaction on all purchases that are not
    // deferred or purchasing.
    await _plugin.finishTransaction(item);

    return result;
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
    _logger.maybeLog('_resetState');
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
        _logger.maybeLog('resetState(): ugly universal catch block, $e');
      }
    }
    _cxnIsInitialized = false;
  }

  /// Fetch state from the store that can be fetched without user
  /// intervention. On iOS, therefore, this does not fetch purchase history,
  /// since that requires users to log in to the App Store (see
  /// getAvailablePurchase).
  ///
  /// Instead, this method is safe to call whenever the purchases UI is
  /// presented.
  Future<void> refreshState() async {
    if (_platformWrapper.isAndroid) {
      await getAvailablePurchases(true);
      await getAvailableProducts(true);
    } else if (_platformWrapper.isIOS) {
      await getAvailableProducts(true);
    } else {
      _logger.maybeLog('refreshState: unrecognized platform');
    }
  }

  /// Get available purchases from the store. When this future completes, the
  /// StateFromStore will contain any results that were fetched. Purchases
  /// will be acked, validated, and finished, as appropriate for the platform.
  ///
  /// This method will also call notifyListeners as appropriate, so if you are
  /// using it as a Provider, you do not need to await the future.
  ///
  /// This method performs the "restore purchases" action on iOS. This means
  /// that it asks users to log into their app store account, and returns
  /// results that have PurchaseState == restored. You might consider
  /// avoiding this on app load, eg, because it can surprise users to be
  /// asked to log into their App Store account without knowing why they are
  /// being asked.
  Future<void> getAvailablePurchases(bool takeOwnershipOfLoading) async {
    _logger.maybeLog('getAvailablePurchases'
        '(takeOwnershipOfLoading: $takeOwnershipOfLoading)');
    if (!_cxnIsInitialized) {
      _logger.maybeLog('getAvailablePurchases called but cxn not initialized');
      return;
    }

    if (_isFetchingAvailablePurchases) {
      _logger.maybeLog('getAvailablePurchases called but already in '
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
      _logger.maybeLog('got availablePurchases with [${purchases.length}] '
          'purchases');

      // These are all the products that we've dealt with tin the
      // handlePurchase method. Anything not in this should be considered
      // NOT_OWNED.
      Set<String> handledPurchaseIDs = Set<String>();
      for (PurchasedItem item in purchases) {
        _logger
            .maybeLog('found a purchased item: ${item.logFriendlyToString()}');
        _logger.maybeLog('full details: $item');

        bool updatedState = await _handlePurchase(item);
        if (updatedState) {
          handledPurchaseIDs.add(item.productId);
        }
      }
      _storeState = _storeState.setNotOwnedExcept(handledPurchaseIDs);
      _logger.maybeLog('new state: $_storeState');
    } catch (e) {
      _logger.maybeLog('getAvailablePurchases: ugly universal catch '
          'block: '
          '$e');
      _pluginErrorMsg = e.toString();
    }

    if (takeOwnershipOfLoading) {
      _logger.maybeLog('getAvailablePurchases setting _isLoaded = true');
      _isLoaded = true;
    }

    _isFetchingAvailablePurchases = false;

    _logger.maybeLog('loaded purchases: $_storeState');
    _notifyListenersWithReporter();
  }

  /// Get available products from the store. When this future completes, the
  /// StateFromStore will contain any results that were fetched.
  ///
  /// This method will also call notifyListeners as appropriate, so if you are
  /// using it as a Provider, you do not need to await the future.
  Future<void> getAvailableProducts(bool takeOwnershipOfLoading) async {
    _logger.maybeLog('getAvailableProducts'
        '(takeOwnershipOfLoading: $takeOwnershipOfLoading)');
    if (!_cxnIsInitialized) {
      _logger.maybeLog('getAvailableProducts called but cxn not '
          'initialized');
      return;
    }

    if (_isFetchingProducts) {
      _logger.maybeLog('getAvailableProducts called but already in '
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
      _logger.maybeLog('fetched available products. length: ${items.length}');
      _logger.maybeLog('fetched available products: $items');

      for (IAPItem item in items) {
        _storeState = _storeState.takeAvailableProduct(item);
      }
    } catch (e) {
      _logger.maybeLog('getAvailableProducts(): ugly universal catch: $e');
      _pluginErrorMsg = e.toString();
    }

    if (takeOwnershipOfLoading) {
      _logger.maybeLog('loaded products: $_storeState');
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
      _logger.maybeLog('requestPurchase called but cxn not initialized');
      return;
    }
    if (itemSku == null) {
      _logger.maybeLog('requestPurchase: itemSku is null, no-op');
      return;
    }
    _logger.maybeLog('requesting purchase for itemSku: $itemSku');
    try {
      return await _plugin.requestPurchase(itemSku);
    } catch (e) {
      _logger.maybeLog('dismissPurchaseError: ugly universal catch '
          'block: $e');
      _pluginErrorMsg = e.toString();
      _notifyListenersWithReporter();
    }
  }
}
