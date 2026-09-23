import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'hot_asset_bundle.dart';
import 'hot_asset_registry.dart';
import 'hot_asset_sync.dart';

/// Facade: init local resource table → wrap app → sync from server.
///
/// Usage:
/// ```dart
/// await HotAssets.init(appPackage: 'sample_app', releaseVersion: '1.0.0+1');
/// runApp(HotAssets.wrap(const MyApp()));
/// // later:
/// await HotAssets.sync(
///   baseUrl: ...,
///   appId: ...,
///   releaseVersion: ...,
///   patchNumber: 2,
/// );
/// ```
class HotAssets {
  HotAssets._();

  static HotAssetRegistry? _registry;
  static HotAssetBundle? _bundle;

  static HotAssetRegistry get registry {
    final r = _registry;
    if (r == null) {
      throw StateError('HotAssets.init() must be called before use');
    }
    return r;
  }

  static HotAssetBundle get bundle {
    final b = _bundle;
    if (b == null) {
      throw StateError('HotAssets.init() must be called before use');
    }
    return b;
  }

  static bool get isInitialized => _registry != null && _bundle != null;

  static int get packNumber => _registry?.packNumber ?? 0;

  static int get tableCount => _registry?.count ?? 0;

  static int? get patchNumber => _registry?.patchNumber;

  static String? get configFingerprint => _registry?.configFingerprint;

  static String? get resourceDir => _registry?.rootDir;

  /// Load local resource table (offline). Call once before [runApp].
  ///
  /// Pass [releaseVersion] so a newer binary does not load a stale table from
  /// a previous release (e.g. `1.0.0+1` → `1.0.0+2`).
  static Future<void> init({
    required String appPackage,
    String? appId,
    String? releaseVersion,
    int? patchNumber,
    String? configFingerprint,
    AssetBundle? parent,
  }) async {
    _registry = await HotAssetRegistry.load(
      appPackage: appPackage,
      appId: appId,
      releaseVersion: releaseVersion,
      patchNumber: patchNumber,
      configFingerprint: configFingerprint,
    );
    _bundle = HotAssetBundle(
      parent: parent ?? rootBundle,
      registry: _registry!,
    );
  }

  /// Install [HotAssetBundle] for the subtree so `Image.asset` resolves via table.
  static Widget wrap(Widget child) {
    return DefaultAssetBundle(
      bundle: bundle,
      child: child,
    );
  }

  /// Query server resource pack / config, download blobs, update table.
  ///
  /// Clears Flutter [imageCache] when files changed so subsequent `Image.asset`
  /// picks up new bytes without restarting the process.
  static Future<HotAssetSyncResult> sync({
    required String baseUrl,
    required String appId,
    required String releaseVersion,
    String channel = 'stable',
    String clientId = 'hot-asset',
    String? uniqueId,
    int? patchNumber,
    String? platform,
    void Function(String)? onLog,
    bool clearImageCacheOnUpdate = true,
  }) async {
    final result = await HotAssetSync(
      baseUrl: baseUrl,
      appId: appId,
      releaseVersion: releaseVersion,
      registry: registry,
      channel: channel,
      clientId: clientId,
      uniqueId: uniqueId,
      patchNumber: patchNumber,
      platform: platform,
    ).checkAndApply(onLog: onLog);

    if (result.updated && clearImageCacheOnUpdate) {
      imageCache.clear();
      imageCache.clearLiveImages();
    }
    return result;
  }
}
