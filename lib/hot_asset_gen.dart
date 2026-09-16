/// Hot asset runtime: sync resource packs from Meta OTA, then resolve assets
/// through a local resource table so `Image.asset` / `DefaultAssetBundle` keep
/// working unchanged. Apps should use the umbrella [`flutterpatch`](https://pub.dev/packages/flutterpatch)
/// package (`FlutterPatch.load` / `resolveFile` / `wrap`) rather than calling
/// this library directly.
library;

export 'src/hot_asset_bundle.dart';
export 'src/hot_asset_registry.dart';
export 'src/hot_assets.dart';
export 'src/hot_asset_sync.dart';
