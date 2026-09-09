/// Hot asset runtime: sync resource packs from Meta OTA, then resolve assets
/// through a local resource table so `Image.asset` / `DefaultAssetBundle` keep
/// working unchanged.
library;

export 'src/hot_asset_bundle.dart';
export 'src/hot_asset_registry.dart';
export 'src/hot_assets.dart';
export 'src/hot_asset_sync.dart';
