import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Local hot-asset resource table.
///
/// Keys are Flutter asset keys (`assets/foo.png` or `packages/pkg/assets/foo.png`).
/// Values are paths relative to the on-disk resource root.
class HotAssetRegistry {
  HotAssetRegistry._({
    required this.appPackage,
    required this.rootDir,
    required Map<String, String> entries,
    this.appId,
    this.releaseVersion,
    this.packNumber = 0,
  }) : _entries = Map<String, String>.from(entries);

  /// Dart pubspec package name of the host app (e.g. `sample_app`).
  final String appPackage;

  /// Absolute directory: `…/Documents/meta_ota_resources`.
  final String rootDir;

  String? appId;
  String? releaseVersion;
  int packNumber;

  final Map<String, String> _entries;

  static const tableFileName = '.asset_table.json';
  static const stateFileName = '.pack_state.json';

  Map<String, String> get entries => Map.unmodifiable(_entries);

  int get count => _entries.length;

  bool containsKey(String assetKey) => _entries.containsKey(assetKey);

  /// Resolve a Flutter asset key to a local file if present in the table and on disk.
  File? resolveFile(String assetKey) {
    final rel = _entries[assetKey];
    if (rel == null || rel.isEmpty) return null;
    final file = File(p.join(rootDir, rel));
    if (!file.existsSync()) return null;
    return file;
  }

  /// Flutter asset keys that map to a downloaded `(package, path)` blob.
  static List<String> keysFor({
    required String appPackage,
    required String package,
    required String path,
  }) {
    final keys = <String>['packages/$package/$path'];
    if (package == appPackage) {
      keys.add(path);
    }
    return keys;
  }

  String relativeBlobPath(String package, String path) => p.join(package, path);

  void upsertBlob({
    required String package,
    required String path,
  }) {
    final rel = relativeBlobPath(package, path);
    for (final key in keysFor(
      appPackage: appPackage,
      package: package,
      path: path,
    )) {
      _entries[key] = rel;
    }
  }

  void removeBlob({
    required String package,
    required String path,
  }) {
    for (final key in keysFor(
      appPackage: appPackage,
      package: package,
      path: path,
    )) {
      _entries.remove(key);
    }
  }

  void clearEntries() => _entries.clear();

  Future<void> persist() async {
    final table = File(p.join(rootDir, tableFileName));
    table.parent.createSync(recursive: true);
    final payload = <String, Object?>{
      'app_package': appPackage,
      'app_id': appId,
      'release_version': releaseVersion,
      'pack_number': packNumber,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      'entries': _entries,
    };
    await table.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(payload)}\n',
      flush: true,
    );

    final state = File(p.join(rootDir, stateFileName));
    await state.writeAsString(
      '${jsonEncode({
            'app_id': appId,
            'release_version': releaseVersion,
            'number': packNumber,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })}\n',
      flush: true,
    );
  }

  /// Load table from disk (or empty). Does not talk to the network.
  static Future<HotAssetRegistry> load({
    required String appPackage,
    String? appId,
    String? releaseVersion,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final rootDir = p.join(docs.path, 'meta_ota_resources');
    Directory(rootDir).createSync(recursive: true);

    final tableFile = File(p.join(rootDir, tableFileName));
    Map<String, String> entries = {};
    String? storedAppId = appId;
    String? storedRelease = releaseVersion;
    var packNumber = 0;

    if (tableFile.existsSync()) {
      try {
        final decoded = jsonDecode(await tableFile.readAsString());
        if (decoded is Map) {
          final sameApp = appId == null || decoded['app_id'] == appId;
          final sameRelease =
              releaseVersion == null || decoded['release_version'] == releaseVersion;
          if (sameApp && sameRelease) {
            final raw = decoded['entries'];
            if (raw is Map) {
              entries = {
                for (final e in raw.entries)
                  if (e.key is String && e.value is String)
                    e.key as String: e.value as String,
              };
            }
            storedAppId = decoded['app_id'] as String? ?? storedAppId;
            storedRelease =
                decoded['release_version'] as String? ?? storedRelease;
            packNumber = (decoded['pack_number'] as num?)?.toInt() ?? 0;
          }
        }
      } catch (_) {
        entries = {};
      }
    } else {
      // Migrate older installs that only have files + .pack_state.json.
      final stateFile = File(p.join(rootDir, stateFileName));
      if (stateFile.existsSync()) {
        try {
          final decoded = jsonDecode(await stateFile.readAsString());
          if (decoded is Map) {
            final sameApp = appId == null || decoded['app_id'] == appId;
            final sameRelease = releaseVersion == null ||
                decoded['release_version'] == releaseVersion;
            if (sameApp && sameRelease) {
              storedAppId = decoded['app_id'] as String? ?? storedAppId;
              storedRelease =
                  decoded['release_version'] as String? ?? storedRelease;
              packNumber = (decoded['number'] as num?)?.toInt() ?? 0;
              entries = await _scanExistingBlobs(
                rootDir: rootDir,
                appPackage: appPackage,
              );
            }
          }
        } catch (_) {}
      }
    }

    final registry = HotAssetRegistry._(
      appPackage: appPackage,
      rootDir: rootDir,
      entries: entries,
      appId: storedAppId,
      releaseVersion: storedRelease,
      packNumber: packNumber,
    );
    if (entries.isNotEmpty && !tableFile.existsSync()) {
      await registry.persist();
    }
    return registry;
  }

  static Future<Map<String, String>> _scanExistingBlobs({
    required String rootDir,
    required String appPackage,
  }) async {
    final out = <String, String>{};
    final root = Directory(rootDir);
    if (!root.existsSync()) return out;

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      final rel = p.relative(entity.path, from: rootDir);
      final parts = p.split(rel);
      if (parts.length < 2) continue;
      final package = parts.first;
      final path = p.joinAll(parts.sublist(1));
      for (final key in keysFor(
        appPackage: appPackage,
        package: package,
        path: path,
      )) {
        out[key] = rel;
      }
    }
    return out;
  }
}
