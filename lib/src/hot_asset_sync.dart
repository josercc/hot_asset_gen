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
    this.reason,
    this.configFingerprintMismatch = false,
  });

  final String message;
  final int packNumber;
  final int downloaded;
  final bool updated;

  /// Server `reason` when no pack was applied (e.g. fingerprint mismatch).
  final String? reason;

  /// True when local config fingerprint did not match the server table.
  final bool configFingerprintMismatch;
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
    this.patchNumber,
    this.platform,
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

  /// Dart patch number to fetch the resource table for.
  /// `null` / ≤0 → release baseline pack.
  final int? patchNumber;

  /// `android` | `ios` | …
  final String? platform;

  final http.Client _http;

  Future<HotAssetSyncResult> checkAndApply({
    void Function(String)? onLog,
  }) async {
    void log(String m) => onLog?.call(m);

    // New binary / new release → drop previous table (packs are per-release).
    final releaseChanged = (registry.appId != null && registry.appId != appId) ||
        (registry.releaseVersion != null &&
            registry.releaseVersion != releaseVersion);
    final patchChanged = patchNumber != null &&
        patchNumber! > 0 &&
        registry.patchNumber != null &&
        registry.patchNumber != patchNumber;
    if (releaseChanged || patchChanged) {
      registry.invalidateLocalTable();
    }
    registry.appId = appId;
    registry.releaseVersion = releaseVersion;
    if (patchNumber != null && patchNumber! > 0) {
      registry.patchNumber = patchNumber;
    }

    final root = baseUrl.replaceAll(RegExp(r'/$'), '');
    final installed = registry.packNumber;
    final localFp = registry.configFingerprint;
    log(
      '资源表 check（已装 #$installed，条目 ${registry.count}'
      '${patchNumber != null && patchNumber! > 0 ? "，补丁 #$patchNumber" : ""}）…',
    );

    final bodyMap = <String, Object?>{
      'app_id': appId,
      'release_version': releaseVersion,
      'channel': channel,
      'client_id': clientId,
      'resource_pack_number': installed,
      if (platform != null && platform!.isNotEmpty) 'platform': platform,
      if (patchNumber != null && patchNumber! > 0) 'patch_number': patchNumber,
      if (localFp != null && localFp.isNotEmpty) 'config_fingerprint': localFp,
    };

    final res = await _http
        .post(
          Uri.parse('$root/api/v1/resources/check'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(bodyMap),
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
    final reason = body['reason'] as String?;

    if (reason == 'config_fingerprint_mismatch') {
      log('配置表指纹不一致，丢弃本地表');
      registry.invalidateLocalTable();
      await registry.persist();
      final expectedFp = body['config_fingerprint'] as String?;
      // Retry once without local fingerprint / pack number so the device can
      // download the correct table for this release+patch.
      return _downloadAndApply(
        root: root,
        body: body,
        log: log,
        installed: 0,
        forceApply: true,
        expectedFingerprint: expectedFp,
        reason: reason,
      );
    }

    if (body['resource_pack_available'] != true) {
      if (reason == 'resource_pack_missing_for_patch') {
        log('补丁 #$patchNumber 无资源表，清空本地表');
        registry.invalidateLocalTable();
      }
      await registry.persist();
      return HotAssetSyncResult(
        message: reason == null
            ? '资源表: 无更新（当前 #${body['number'] ?? installed}）'
            : '资源表: 无更新（$reason）',
        packNumber: (body['number'] as num?)?.toInt() ?? installed,
        downloaded: 0,
        updated: false,
        reason: reason,
        configFingerprintMismatch: reason == 'config_fingerprint_mismatch',
      );
    }

    return _downloadAndApply(
      root: root,
      body: body,
      log: log,
      installed: installed,
    );
  }

  Future<HotAssetSyncResult> _downloadAndApply({
    required String root,
    required Map<String, dynamic> body,
    required void Function(String) log,
    required int installed,
    bool forceApply = false,
    String? expectedFingerprint,
    String? reason,
  }) async {
    // On fingerprint mismatch the first response has available=false but still
    // carries the expected pack number — re-check without fingerprint.
    if (forceApply && body['resource_pack_available'] != true) {
      final retryBody = <String, Object?>{
        'app_id': appId,
        'release_version': releaseVersion,
        'channel': channel,
        'client_id': clientId,
        'resource_pack_number': 0,
        if (platform != null && platform!.isNotEmpty) 'platform': platform,
        if (patchNumber != null && patchNumber! > 0)
          'patch_number': patchNumber,
      };
      final retry = await _http
          .post(
            Uri.parse('$root/api/v1/resources/check'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(retryBody),
          )
          .timeout(const Duration(seconds: 12));
      if (retry.statusCode != 200) {
        return HotAssetSyncResult(
          message: '资源表 re-check HTTP ${retry.statusCode}',
          packNumber: 0,
          downloaded: 0,
          updated: false,
          reason: reason,
          configFingerprintMismatch: true,
        );
      }
      body = jsonDecode(retry.body) as Map<String, dynamic>;
      if (body['resource_pack_available'] != true) {
        await registry.persist();
        return HotAssetSyncResult(
          message: '资源表: 指纹不一致且无可用包',
          packNumber: 0,
          downloaded: 0,
          updated: false,
          reason: reason,
          configFingerprintMismatch: true,
        );
      }
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
    final fp = (body['config_fingerprint'] as String?) ?? expectedFingerprint;
    if (fp != null && fp.isNotEmpty) {
      registry.configFingerprint = fp;
    }
    final pn = (body['patch_number'] as num?)?.toInt() ?? patchNumber;
    if (pn != null && pn > 0) {
      registry.patchNumber = pn;
    }
    await registry.persist();

    return HotAssetSyncResult(
      message:
          '资源表 #$number 已应用（下载 $downloaded → ${registry.rootDir}，条目 ${registry.count}）',
      packNumber: number,
      downloaded: downloaded,
      updated: true,
      reason: reason,
      configFingerprintMismatch: reason == 'config_fingerprint_mismatch',
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
