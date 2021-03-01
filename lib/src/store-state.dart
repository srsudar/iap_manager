import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inapp_purchase/flutter_inapp_purchase.dart';

enum OwnedState {
  /// This is is we have communicated with the store and validated it
  /// correctly, and know that it is owned.
  OWNED,

  /// This is when we have validated that we not own it.
  NOT_OWNED,

  /// This might happen if we process a sub but can't validate it, eg.
  UNKNOWN,
}

/// This represents an in-app product that you are selling.
class InAppProduct {
  final String sku;
  final IAPItem product;
  final PurchasedItem purchase;
  final OwnedState owned;

  /// This is an optional error msg from the store about a specific product.
  /// This might occur if you have an error when validating an iOS
  /// subscription, eg.
  final String errMsg;

  InAppProduct(this.sku, this.product, this.purchase, this.owned, this.errMsg);

  /// We can't really display a purchase unless we can communicate with the
  /// store, b/c we get the title etc from the store.
  bool canDisplay() {
    return product != null && product.title != null && product.title != '';
  }

  String getTitle() {
    if (product == null || product.title == null) {
      return '';
    }
    return product.title;
  }

  String getDescription() {
    if (product == null || product.description == null) {
      return '';
    }
    return product.description;
  }

  String getLocalizedPrice() {
    if (product == null || product.localizedPrice == null) {
      return '';
    }
    return product.localizedPrice;
  }

  bool isOwned() {
    return owned == OwnedState.OWNED;
  }

  bool isNotOwned() {
    return owned == OwnedState.NOT_OWNED;
  }

  bool isUnknownPurchaseState() {
    return owned == OwnedState.UNKNOWN;
  }

  static InAppProduct defaultSate(String sku) {
    return InAppProduct(sku, null, null, OwnedState.UNKNOWN, '');
  }

  InAppProduct withProductInfo(IAPItem item) {
    if (item.productId != this.sku) {
      debugPrint('withProductInfo called with mismatched skus, returning '
          'original');
      return this;
    }
    InAppProduct tmp = fromProduct(item);
    return tmp.withOwnedState(this.owned, '');
  }

  InAppProduct withOwnedState(OwnedState owned, String errMsg) {
    return InAppProduct(sku, product, purchase, owned, errMsg);
  }

  InAppProduct toPurchaseOwned(String errMsg) {
    return withOwnedState(OwnedState.OWNED, errMsg);
  }

  InAppProduct toPurchaseNotOwned(String errMsg) {
    return InAppProduct(sku, product, null, OwnedState.NOT_OWNED, errMsg);
  }

  InAppProduct toPurchaseUnknown(String errMsg) {
    return InAppProduct(sku, product, null, OwnedState.UNKNOWN, errMsg);
  }

  static InAppProduct fromPurchased(PurchasedItem item) {
    InAppProduct result = InAppProduct(
      item.productId,
      null,
      item,
      OwnedState.OWNED,
      '',
    );
    return result;
  }

  static InAppProduct fromProduct(IAPItem item) {
    InAppProduct result = InAppProduct(
      item.productId,
      item,
      null,
      OwnedState.UNKNOWN,
      '',
    );
    return result;
  }

  @override
  String toString() {
    return 'InAppProduct{sku: $sku, title: ${product?.title}, description: '
        '${product?.description}, localizedPrice: '
        '${product?.localizedPrice}, owned: '
        '$owned}';
  }
}

/// An object to expose to the app, which will use this to look at the state
/// of the object and whether or not we need to rebuild / hide ads / etc.
abstract class StateFromStore {
  final PurchaseResult lastError;

  StateFromStore(this.lastError);

  bool hasError() {
    return lastError != null;
  }

  /// True if details have been retrieved from the store. Store details
  /// provide descriptions and titles, so if this is false then we can't
  /// really display anything.
  bool canDisplay();

  /// Construct a new state without lastError.
  StateFromStore dismissError();

  StateFromStore takeAvailableProduct(IAPItem item);

  StateFromStore takePurchase(PurchasedItem item, {String errMsg = ''});

  StateFromStore removePurchase(PurchasedItem item, {String errMsg = ''});

  StateFromStore takePurchaseUnknown(PurchasedItem item, {String errMsg = ''});

  /// This is used for setting purchases in a known not purchased state. All
  /// products will be set to NOT_OWNED, except for those in ignoreTheseIDs.
  /// This is because you know something is NOT_OWNED if it is absent from a
  /// getAvailablePurchases request.
  StateFromStore setNotOwnedExcept(Set<String> ignoreTheseIDs);

  /// Add an error to the known state.
  StateFromStore takeError(PurchaseResult result);

  /// Get a list of non-consumable product IDs. This should be platform-aware.
  List<String> getNonConsumableProductIDs();

  /// get a list of subscription IDs. This should be platform-aware.
  List<String> getSubscriptionProductIDs();

  /// Processing is different for items that are subscriptions. There is no
  /// way to tell without checking product IDs, as far as I know. This is
  /// provided to callers to be able to control when an item is a subscription.
  /// This naive implementation just checks if the productID is included in
  /// getSubscriptionProductIDs, but this is included to allow more complext
  /// implementations.
  bool itemIsSubscription(PurchasedItem item) {
    return getSubscriptionProductIDs().contains(item.productId);
  }
}
