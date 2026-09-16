# hot_asset_gen

通过本地资源表 + `AssetBundle` 覆盖，热更新 Flutter 静态资源。业务侧继续使用 `Image.asset` / FlutterGen `.image()` 等，无需改调用点。

**应用请接上层 [`flutterpatch`](https://pub.dev/packages/flutterpatch)**，不要直接调本包的 `HotAssets`。本包是资源热更的内部实现。

非 `Image.asset` 场景（音频 / 分享图 / `VideoPlayerController.file`）请用：

- `FlutterPatch.load(key)` — 替代 `rootBundle.load`
- `FlutterPatch.resolveFile(key)` — 热更落盘文件

## 快速接入（推荐）

```dart
import 'package:flutterpatch/flutterpatch.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // bootstrap：读 shorebird.yaml、离线加载资源表、注入 HotAssetBundle（不上网）
  runApp(await FlutterPatch.bootstrap(const MyApp(), appPackage: 'my_app'));

  FlutterPatch.setUniqueId(deviceUniqueId); // 有灰度 id 时再设，可空
  await FlutterPatch.sync();                // 有网络时再 sync（资源 + 可选代码补丁）
}
```

`baseUrl` / `appId` / `channel` 来自 `shorebird.yaml`（或传入的 `FlutterPatchConfig`），`releaseVersion` 默认取 `PackageInfo`。

业务代码保持不变：

```dart
Image.asset('assets/foo.png');
Assets.images.logo.image(); // FlutterGen 同样走 DefaultAssetBundle
```

仅资源、不跑代码补丁时可用 `FlutterPatch.syncResources()`。

## 资源热更范围（约定）

| 纳入 | 说明 |
|------|------|
| `assets/images/**` | 主路径；有 `2.0x`/`3.0x` 须整组上传 |
| audios / videos / lottie | 业务须走 `FlutterPatch.load` / `resolveFile` |
| **排除 fonts** | `pubspec.yaml` `fonts:` 启动注册，AssetBundle 管不到 |
| **排除** 启动配置（如 `dart_define.json`） | 保持包内只读 |

只替换已打进包的 asset key；换 `release_version` 会清本地资源表。

## 原理

`FlutterPatch.bootstrap` / `sync` 内部会走到本包：

1. **`HotAssetRegistry`**：本地资源表（`…/Documents/meta_ota_resources/`）
2. **`HotAssetBundle`**：优先从表读，没有则回退 `rootBundle`
3. **`HotAssetSync`**：`/api/v1/resources/check` → 下载 blob → 更新表
4. **`HotAssets`**：被 `FlutterPatch` 调用的 facade，业务一般不直接用

```
Image.asset / Assets.xxx.image()
        │
        ▼
 HotAssetBundle ──有表项──► meta_ota_resources/<package>/assets/foo.png
        │
        └──无表项──► rootBundle（打包进 APK/IPA 的资源）
```

## 内部 API（一般无需关心）

| API | 说明 |
|-----|------|
| `HotAssets.init` | `FlutterPatch.init` 调用；只读本地表 |
| `HotAssets.wrap` | `FlutterPatch.wrap` / `bootstrap` 调用 |
| `HotAssets.sync` | `FlutterPatch.sync` / `syncResources` 调用 |
| `HotAssets.packNumber` / `tableCount` | 也可经 `FlutterPatch.resourcePackNumber` 等读取 |

`HotAssetSyncResult`：`updated` / `downloaded` / `packNumber` / `message`。

## 资源表与磁盘布局

根目录：`ApplicationDocumentsDirectory/meta_ota_resources/`

| 文件 | 作用 |
|------|------|
| `.asset_table.json` | asset key → 相对路径；含 `pack_number` / `app_id` / `release_version` |
| `.pack_state.json` | 轻量状态（兼容旧安装） |
| `<package>/<path>` | 已下载 blob，例如 `my_app/assets/foo.png` |

Asset key 规则：

- 宿主包资源：`assets/foo.png` 与 `packages/<appPackage>/assets/foo.png` 都会映射到同一文件
- 依赖包资源：仅 `packages/<package>/assets/...`

换 `app_id` 或 `release_version` 时，`sync` 会清空旧表（资源包按 release 隔离）。

## 灰度（uniqueId）

请求协议不变；服务端在 check 响应里带 `unique_ids`，由客户端过滤：

| 响应 `unique_ids` | 本地 `uniqueId` | 是否下载 |
|-------------------|-----------------|----------|
| 空 / 无 | 任意 | 是 |
| 非空 | 空 / 未命中 | 否 |
| 非空 | 命中 | 是 |

## 网络

- `init` / `wrap` **不上网**
- 仅 `sync`（内部 `HotAssetSync.checkAndApply`）访问：
  - `POST {baseUrl}/api/v1/resources/check`
  - `GET` 变更项的 `download_url`，或回退 `{baseUrl}/api/v1/assets/{hash}/content`

## 依赖

- Flutter `>=3.24` / Dart `^3.5`
- `http`、`path`、`path_provider`
