## [0.1.1] - 2021-03-10

* Don't interpret user cancellation as an error during
`getAvailablePurchases()`. This was showing an error (even though it's not
really an error state) on iOS when someone restored purchases but hit the cancel
button when asked to sign in.

## [0.1.0] - 2021-03-07

* Don't contact the App Store when initializing on iOS. This allows callers to
be more precise about when they want the user to be asked to log in to the App
Store.
* Add a parameter to verify purchases against your own server.
* Remove default iOS subscription validation.


## [0.0.3] - 2021-03-01

* Avoid `isAcknowledgedAndroid` on Android subscriptions, which the plugin
leaves as `null`. Instead, check `transactionReceipt` when necessary.

## [0.0.2] - 2021-02-28

* Switch from `getPurchaseHistory()` to `getAvailablePurchases()`, which seems
to be more correct behavior on Android.
* Add the ability to log in release mode, in case you need to debug.

## [0.0.1] - initial release

* First pass
