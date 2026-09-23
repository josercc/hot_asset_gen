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
    this.patchNumber,
    this.configFingerprint,
  }) : _entries = Map<String, String>.from(entries);

  /// Dart pubspec package name of the host app (e.g. `sample_app`).
  final String appPackage;

  /// Absolute directory: `…/Documents/meta_ota_resources`.
  final String rootDir;

  String? appId;
  String? releaseVersion;
  int packNumber;

  /// Dart patch number this table belongs to (`null` / 0 = release baseline).
  int? patchNumber;

  /// Fingerprint of the full resource inventory for this table.
  String? configFingerprint;

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

  /// Drop local table state so the next sync must re-download.
  void invalidateLocalTable() {
    clearEntries();
    packNumber = 0;
    patchNumber = null;
    configFingerprint = null;
  }

  Future<void> persist() async {
    final table = File(p.join(rootDir, tableFileName));
    table.parent.createSync(recursive: true);
    final payload = <String, Object?>{
      'app_package': appPackage,
      'app_id': appId,
      'release_version': releaseVersion,
      'pack_number': packNumber,
      if (patchNumber != null) 'patch_number': patchNumber,
      if (configFingerprint != null) 'config_fingerprint': configFingerprint,
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
            if (patchNumber != null) 'patch_number': patchNumber,
            if (configFingerprint != null)
              'config_fingerprint': configFingerprint,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })}\n',
      flush: true,
    );
  }

  /// Load table from disk (or empty). Does not talk to the network.
  ///
  /// When [releaseVersion] is provided and the on-disk table belongs to a
  /// different release, the table is discarded (do not load stale config).
  static Future<HotAssetRegistry> load({
    required String appPackage,
    String? appId,
    String? releaseVersion,
    int? patchNumber,
    String? configFingerprint,
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final rootDir = p.join(docs.path, 'meta_ota_resources');
    Directory(rootDir).createSync(recursive: true);

    final tableFile = File(p.join(rootDir, tableFileName));
    Map<String, String> entries = {};
    String? storedAppId = appId;
    String? storedRelease = releaseVersion;
    var packNumber = 0;
    int? storedPatch = patchNumber;
    String? storedFingerprint = configFingerprint;

    if (tableFile.existsSync()) {
      try {
        final decoded = jsonDecode(await tableFile.readAsString());
        if (decoded is Map) {
          final sameApp = appId == null || decoded['app_id'] == appId;
          // When caller supplies releaseVersion, mismatch → discard (1.0.0+1→+2).
          final sameRelease = releaseVersion == null ||
              decoded['release_version'] == releaseVersion;
          final diskPatch = (decoded['patch_number'] as num?)?.toInt();
          final samePatch =
              patchNumber == null || diskPatch == patchNumber;
          final diskFp = decoded['config_fingerprint'] as String?;
          final sameFp = configFingerprint == null ||
              configFingerprint.isEmpty ||
              diskFp == configFingerprint;
          if (sameApp && sameRelease && samePatch && sameFp) {
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
            storedPatch = diskPatch ?? storedPatch;
            storedFingerprint = diskFp ?? storedFingerprint;
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
              storedPatch =
                  (decoded['patch_number'] as num?)?.toInt() ?? storedPatch;
              storedFingerprint =
                  decoded['config_fingerprint'] as String? ?? storedFingerprint;
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
      patchNumber: storedPatch,
      configFingerprint: storedFingerprint,
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
