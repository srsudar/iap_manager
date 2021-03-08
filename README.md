# iap_manager

> Manage your Flutter In-App Purchases.

[![Build Status](https://travis-ci.org/srsudar/iap_manager.svg?branch=master)](https://travis-ci.org/srsudar/iap_manager)

## Warning: not yet tested in production

I have not yet tested this library in my own production app. I plan to, but I
haven't yet done so. When I am satisfied that it works I will remove this
warning.

## Overview

This package helps manage In-App Purchases (IAPs) in Flutter apps. It **does not
provide any native platform code**. Interacting with the Google Play (on
Android) and App Store (on iOS) APIs is handled by the
[flutter_inapp_purchase](https://pub.dev/packages/flutter_inapp_purchase)
plugin.

When I started adding IAPs to my app, even with the above plugin, it was hard.
There is a lot of state management to get right. This package shows how I have
done it. Hopefully it is correct and can be useful to others.

If you find problems or have usability suggestions, please open issues or submit
pull requests!

## Getting Started

### Set Up In-App Purchases

Follow the instructions at
[flutter_inapp_purchase](https://pub.dev/packages/flutter_inapp_purchase) to
enable IAPs for your apps. They have a [blog
post](https://medium.com/codechai/flutter-in-app-purchase-7a3fb9345e2a) that is
helpful. You'll also need the proguard rules for when you build a release
version.

### Classes

#### `IAPManager`

The main class this package provides is the `IAPManager`. It is a
[`ChangeNotifier`](https://api.flutter.dev/flutter/foundation/ChangeNotifier-class.html),
which will hopefully make it easy for you to integrate into your app.

When you create an `IAPManager`, it will begin listening to for purchase
updates. On Android, you will always get the latest purchase state because Play
Services caches the purchases locally and makes querying simple. On iOS,
purchases aren't requested from the store unless you call
`getAvailablePurchases`. This is the mechanism that provides the "Restore State"
button required by Apple--it asks users to log in to the App Store, and it then
fetches any purchases, setting purchase state to `restored`. Best practice on
iOS appears to be caching the results of the first purchase yourself, and
validating the purchase with your own server before use.


#### `InAppProduct`

`InAppProduct` represents a product that you have for sale. All you need to
provide is a SKU (a product ID). The rest of the required information (title,
description, price, ownership status) comes from the store.

#### `StateFromStore`

`StateFromStore` is your app's local view of a user's IAP state. It contains the
title and description of your items, and an error message (if something went
wrong communicating with the store, eg).

#### `IAPPlugin3PWrapper`

This is a simple wrapper around `flutter_inapp_purchase`. I use it to simplify
testing.

#### `PlatformWrapper`

This is a simple wrapper around `Platform`. If you want to simulate an Android
environment, you can pass `PlatformWrapper.android()`. In production, just use
`PlatformWrapper()`.

#### `PurchaseVerifier`

This is a class you can implement to perform server-side validation of IAPs.
If you don't use any server-side validation, and instead trust what you see
on the device, you can leave this parameter unset.

If you are using iOS subscriptions, there is any way to tell on-device if the
subscription is valid. The `IOSSubscriptionHelper` class is provided to help
determine if a subscription is valid. You can use that in a custom
`PurchaseVerifier` to determine if subscriptions are active.

### Integrating iap_manager Into Your App

#### 1. Define Your Store State

Start by defining your store state. You do this by extending `StateFromStore`.
An example is shown in the test file.

This class shows that we have two products: a one-time purchase that removes ads
forever, and a subscription that removes ads for one year. The `shouldShowAds()`
function calculates whether or not ads should be shown to the user.

```dart
class TestStoreState extends StateFromStore {
  final bool initialShouldShowAds;
  final InAppProduct noAdsForever;
  final InAppProduct noAdsOneYear;

  TestStoreState(this.initialShouldShowAds, this.noAdsForever,
    this.noAdsOneYear, PurchaseResult lastError)
      : super(lastError);

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

  <snip>
```

#### 2. Extend `IAPManager`

`IAPManager` is a parameterized object. You can use it right away like this:

**I avoid this:**

```dart
IAPManager<TestStoreState> iap = IAPManager<TestStoreState>(...);
```

This can be error-prone, though, and lead to runtime failures. Dart is
permissive, so you can also do this:

**I avoid this:**

```dart
// Note that we're not parameterizing the declared type here (no
// <TestStoreState>).
IAPManager iap = IAPManager<TestStoreState>(...);
```

This is perfectly valid dart. However, it can lead to runtime errors if you use
that bare type in a Provider. Provider will look for a type
`IAPManager<StateFromStore>`, which it might not find, and could lead to errors.

Instead, I like to subclass `IAPManager` so that I can't commit that error.

**I prefer this**:

```dart
class TestIAPManager extends IAPManager<TestStoreState> {
  TestIAPManager(
    IAPPlugin3PWrapper plugin,
    TestStoreState storeState,
    bool initialShouldShowAds,
    void Function() notifyListenersInvokedCallback,
    PlatformWrapper platformWrapper,
    {PurchaseVerifier purchaseVerifier},
  ) : super(
          plugin,
          storeState,
          initialShouldShowAds,
          notifyListenersInvokedCallback,
          platformWrapper,
          purchaseVerifier: purchaseVerifier,
        );
}
```

Now you can just use `TestIAPManager` without worrying about parameterizing it
properly every time.

#### 3. Wire It Into Your App

I use `Provider` to manage state in my app. The root widget of my app looks more
or less like what is shown below. Note that the `AdManager` class isn't included
in this package. It is used an example to show one way that you can incorporate
`IAPManager` along with any other `Provider`s you might be using. 

This is the root function of an app that uses iap_manager:

```dart
  bool initialShouldShowAds = await dataStore.getLastKnownShowAds();

  return MultiProvider(
    providers: [
      Provider<AdManager>(
        create: (_) {
          return AdManager();
        },
        dispose: (ctx, mgr) => mgr.dispose(),
        lazy: false,
      ),
      ChangeNotifierProvider<TestIAPManager>(
        create: (_) {
          return TestIAPManager(
            IAPPlugin3PWrapper(),
            TestStoreState.defaultState(),
            initialShouldShowAds,
            null,
            PlatformWrapper(),
          );
        },
        // We want this created on app start, so that we have the most up
        // to date purchases right away. This will prevent us from still
        // showing ads if someone closed an app before the purchase
        // completed, eg. And it should be fast, b/c Play Services should
        // cache the results for us.
        lazy: false,
      ),
   ],
   child: MyApp(),
 );
```

## Known Limitations

I don't have need for these features, so I don't have a good way to validate
them, so I haven't implemented them.

* **No consumable items**. IAPs like coins that you can spend are something that
    I haven't looked into, so they're not supported at the moment.
