import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'hot_asset_registry.dart';

class HotAssetSyncResult {
  const HotAssetSyncResult({
    required this.message,
    required this.packNumber,
    required this.downloaded,
    required this.updated,
  });

  final String message;
  final int packNumber;
  final int downloaded;
  final bool updated;
}

/// Talks to Meta OTA `/api/v1/resources/check`, downloads blobs, updates
/// [HotAssetRegistry] (the local resource table).
class HotAssetSync {
  HotAssetSync({
    required this.baseUrl,
    required this.appId,
    required this.releaseVersion,
    required this.registry,
    this.channel = 'stable',
    this.clientId = 'hot-asset',
    this.uniqueId,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final String appId;
  final String releaseVersion;
  final HotAssetRegistry registry;
  final String channel;
  final String clientId;

  /// Local gray-release id ([FlutterPatch.setUniqueId]). Compared to response
  /// `unique_ids` on the client — empty allowlist = download for everyone.
  final String? uniqueId;
  final http.Client _http;

  Future<HotAssetSyncResult> checkAndApply({
    void Function(String)? onLog,
  }) async {
    void log(String m) => onLog?.call(m);

    // New binary / new release → drop previous table (packs are per-release).
    final releaseChanged = (registry.appId != null && registry.appId != appId) ||
        (registry.releaseVersion != null &&
            registry.releaseVersion != releaseVersion);
    if (releaseChanged) {
      registry.clearEntries();
      registry.packNumber = 0;
    }
    registry.appId = appId;
    registry.releaseVersion = releaseVersion;

    final root = baseUrl.replaceAll(RegExp(r'/$'), '');
    final installed = registry.packNumber;
    log('资源表 check（已装 #$installed，条目 ${registry.count}）…');

    final res = await _http
        .post(
          Uri.parse('$root/api/v1/resources/check'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'app_id': appId,
            'release_version': releaseVersion,
            'channel': channel,
            'client_id': clientId,
            'resource_pack_number': installed,
          }),
        )
        .timeout(const Duration(seconds: 12));

    if (res.statusCode != 200) {
      return HotAssetSyncResult(
        message: '资源表 check HTTP ${res.statusCode}: ${res.body}',
        packNumber: installed,
        downloaded: 0,
        updated: false,
      );
    }

    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['resource_pack_available'] != true) {
      await registry.persist();
      return HotAssetSyncResult(
        message: '资源表: 无更新（当前 #${body['number'] ?? installed}）',
        packNumber: (body['number'] as num?)?.toInt() ?? installed,
        downloaded: 0,
        updated: false,
      );
    }

    final number = (body['number'] as num?)?.toInt() ?? 0;
    final allowlist = _parseUniqueIds(body['unique_ids']);
    if (!_clientAllowed(allowlist, uniqueId)) {
      log('资源包 #$number 有更新，但 uniqueId 未命中名单，跳过下载');
      return HotAssetSyncResult(
        message: '资源表: uniqueId 未命中，跳过 #$number',
        packNumber: installed,
        downloaded: 0,
        updated: false,
      );
    }

    final changes = (body['changes'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    log('资源包 #$number 可用，${changes.length} 条变动');

    final outRoot = Directory(registry.rootDir);
    if (!outRoot.existsSync()) outRoot.createSync(recursive: true);

    var downloaded = 0;
    for (final c in changes) {
      final change = '${c['change'] ?? ''}'.toLowerCase();
      final package = '${c['package'] ?? 'app'}';
      final path = '${c['path'] ?? ''}';
      if (path.isEmpty) continue;

      final local = File(p.join(registry.rootDir, package, path));

      if (change == 'remove') {
        if (local.existsSync()) local.deleteSync();
        registry.removeBlob(package: package, path: path);
        continue;
      }
      if (change != 'add' && change != 'update') continue;

      var url = '${c['download_url'] ?? ''}'.trim();
      if (url.isEmpty) {
        final hash = '${c['hash'] ?? ''}'.trim().toLowerCase();
        if (hash.isEmpty) continue;
        url = '$root/api/v1/assets/$hash/content';
      }

      final dl =
          await _http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (dl.statusCode != 200) {
        log('下载失败 $package/$path → ${dl.statusCode}');
        continue;
      }
      local.parent.createSync(recursive: true);
      await local.writeAsBytes(dl.bodyBytes, flush: true);
      registry.upsertBlob(package: package, path: path);
      downloaded++;
      log('已写入 ${local.path}');
    }

    registry.packNumber = number;
    await registry.persist();

    return HotAssetSyncResult(
      message:
          '资源表 #$number 已应用（下载 $downloaded → ${registry.rootDir}，条目 ${registry.count}）',
      packNumber: number,
      downloaded: downloaded,
      updated: true,
    );
  }

  static List<String>? _parseUniqueIds(Object? raw) {
    if (raw is! List) return null;
    final ids =
        raw.map((e) => '$e'.trim()).where((s) => s.isNotEmpty).toList();
    return ids.isEmpty ? null : ids;
  }

  /// Empty / null allowlist → everyone. Non-empty → local id must be listed.
  static bool _clientAllowed(List<String>? allowlist, String? localId) {
    if (allowlist == null || allowlist.isEmpty) return true;
    final id = (localId ?? '').trim();
    if (id.isEmpty) return false;
    return allowlist.contains(id);
  }
}
