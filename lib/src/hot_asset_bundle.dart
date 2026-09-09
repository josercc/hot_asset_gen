import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'hot_asset_registry.dart';

/// [AssetBundle] that prefers entries from [HotAssetRegistry], otherwise
/// delegates to [parent] (usually [rootBundle]).
///
/// Wrap the app with [DefaultAssetBundle] so `Image.asset` / `DefaultAssetBundle.of`
/// keep the same call sites.
class HotAssetBundle extends AssetBundle {
  HotAssetBundle({
    required this.parent,
    required this.registry,
  });

  final AssetBundle parent;
  final HotAssetRegistry registry;

  @override
  Future<ByteData> load(String key) async {
    final file = registry.resolveFile(key);
    if (file != null) {
      final bytes = await file.readAsBytes();
      return ByteData.sublistView(bytes);
    }
    return parent.load(key);
  }

  @override
  Future<ui.ImmutableBuffer> loadBuffer(String key) async {
    final file = registry.resolveFile(key);
    if (file != null) {
      final bytes = await file.readAsBytes();
      return ui.ImmutableBuffer.fromUint8List(bytes);
    }
    return parent.loadBuffer(key);
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    final data = await load(key);
    return utf8.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  @override
  Future<T> loadStructuredData<T>(
    String key,
    Future<T> Function(String value) parser,
  ) async {
    return parser(await loadString(key));
  }

  @override
  void evict(String key) {
    parent.evict(key);
  }

  @override
  void clear() {
    parent.clear();
  }
}
