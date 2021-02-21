import 'dart:async';

import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';
import 'package:flutter_inapp_purchase/modules.dart';
import 'package:http/http.dart' as http;

/// This is a wrapper around the third party flutter_inapp_purchases plugin.
/// That plugin has lots of static instance variables, which we want to avoid
/// dealing with in test code.
class IAPPlugin3PWrapper {
  Future<List<IAPItem>> getProducts(List<String> productIds) {
    return FlutterInappPurchase.instance.getProducts(productIds);
  }

  Future<List<IAPItem>> getSubscriptions(List<String> subscriptionIds) {
    return FlutterInappPurchase.instance.getSubscriptions(subscriptionIds);
  }

  Future<List<PurchasedItem>> getPurchaseHistory() async {
    return FlutterInappPurchase.instance.getPurchaseHistory();
  }

  Stream<PurchasedItem> getPurchaseUpdatedStream() {
    return FlutterInappPurchase.purchaseUpdated;
  }

  Stream<PurchaseResult> getPurchaseErrorStream() {
    return FlutterInappPurchase.purchaseError;
  }

  Future<dynamic> consumeAllItems() {
    return FlutterInappPurchase.instance.consumeAllItems;
  }

  Future<String> initConnection() {
    return FlutterInappPurchase.instance.initConnection;
  }

  Future<String> endConnection() {
    return FlutterInappPurchase.instance.endConnection;
  }

  Future<dynamic> requestPurchase(String itemSku) {
    return FlutterInappPurchase.instance.requestPurchase(itemSku);
  }

  Future<String> acknowledgePurchase(String token) {
    return FlutterInappPurchase.instance.acknowledgePurchaseAndroid(token);
  }

  Future<String> finishTransaction(PurchasedItem purchasedItem) {
    return FlutterInappPurchase.instance.finishTransaction(purchasedItem);
  }

  Future<http.Response> validateTransactionIOS(
      Map<String, String> reqBody, bool useSandbox) async {
    return FlutterInappPurchase.instance
        .validateReceiptIos(receiptBody: reqBody, isTest: useSandbox);
  }
}
