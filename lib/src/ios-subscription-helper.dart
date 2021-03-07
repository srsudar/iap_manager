import 'dart:convert';
import 'dart:io';

import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:http/http.dart' as http;
import 'package:iap_manager/iap_manager.dart';
import 'package:iap_manager/src/iap-logger.dart';

/// See the developer link below about where this comes from.
const int _IOS_STATUS_IS_SANDBOX = 21007;
const int _IOS_STATUS_IS_OK = 0;

/// Helps validate an iOS subscription as active or inactive. The proper way
/// to do this is using your own server. The Apple documentation warns:
///
/// Do not call the App Store server verifyReceipt endpoint from your app.
/// You can't build a trusted connection between a user’s device and the App
/// Store directly, because you don’t control either end of that connection,
/// which makes it susceptible to a man-in-the-middle attack.
///
/// https://developer.apple.com/documentation/storekit/in-app_purchase/validating_receipts_with_the_app_store
///
/// However, as far as I can tell, without doing SOMETHING on the client you
/// really have no way at all to tell that a subscription is valid. This
/// implementation follows their suggested process but should not be trusted
/// for high value resources. As Apple warns you, on a rooted device you
/// might be subject o a man-in-the-middle attack.
class IOSSubscriptionHelper {
  final IAPPlugin3PWrapper _plugin;
  final IAPLogger _logger;

  /// This comes via the AppstoreConnect screen and is used for validating
  /// subscriptions.
  final String _iosSharedSecret;

  IOSSubscriptionHelper(this._plugin, this._iosSharedSecret, this._logger);

  /// Returns true if the item is active. If this is not a subscription item,
  /// behavior is undefined. This method correctly handles sandbox and
  /// production purchases.
  ///
  /// There is no way to tell that a subscription is active on iOS without
  /// issues a call via the transaction receipt.
  Future<PurchaseVerificationResult> verifyIOSSubscription(
      PurchasedItem item) async {
    // We can either validate against the sandbox (for test accounts) or
    // against production. The apple docs say always first validate against
    // production, only trying the sandbox if there is a specific error code.
    // * https://stackoverflow.com/questions/9677193/ios-storekit-can-i-detect-when-im-in-the-sandbox
    // * https://developer.apple.com/library/archive/technotes/tn2413/_index.html#//apple_ref/doc/uid/DTS40016228-CH1-RECEIPTURL

    try {
      // Always use prod first--see above.
      var json = await _validateTransactionIOSHelper(item, false);
      if (_statusEquals(json, _IOS_STATUS_IS_SANDBOX)) {
        _logger.maybeLog('item was sandbox purchase');
        json = await _validateTransactionIOSHelper(item, true);
      }
      if (!_statusEquals(json, _IOS_STATUS_IS_OK)) {
        throw Exception('iOS subscription validation status not ok: '
            '${json['status']}');
      }
      _logger.maybeLog('parsed validation receipt for subscription with sku: '
          '{${item.productId}');
      return _validationResponseIndicatesActiveSubscription(json);
    } catch (e) {
      _logger.maybeLog('catch block when validating: $e');
      return PurchaseVerificationResult(
        PurchaseVerificationStatus.UNKNOWN,
        e.toString(),
      );
    }
  }

  PurchaseVerificationResult _validationResponseIndicatesActiveSubscription(
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
      return PurchaseVerificationResult(
          PurchaseVerificationStatus.UNKNOWN, 'body is null');
    }
    List<dynamic> pendingRenewalInfoList = body['pending_renewal_info'];
    if (pendingRenewalInfoList == null) {
      _logger.maybeLog('no pending_renewal_info property, returning '
          'false');
      return PurchaseVerificationResult(
          PurchaseVerificationStatus.UNKNOWN, 'pending_renewal_info is null');
    }
    if (pendingRenewalInfoList.length < 1) {
      _logger.maybeLog('pending_renewal_info set, but empty list');
      return PurchaseVerificationResult(
          PurchaseVerificationStatus.UNKNOWN, 'pending_renewal_info is empty');
    }
    if (pendingRenewalInfoList.length > 1) {
      _logger.maybeLog('pending_renewal_info.length > 1, which is unexpected');
    }
    Map<String, dynamic> pendingRenewalInfo =
        pendingRenewalInfoList[0] as Map<String, dynamic>;
    _logger.maybeLog(
        'pending_renewal_info successfully parsed: $pendingRenewalInfo');
    // If non-null, then it has been canceled.
    if (pendingRenewalInfo['expiration_intent'] == null) {
      return PurchaseVerificationResult(PurchaseVerificationStatus.VALID, '');
    } else {
      return PurchaseVerificationResult(
          PurchaseVerificationStatus.INVALID, 'expired');
    }
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
}
