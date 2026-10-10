## 0.1.2

- If local `packNumber > 0` but the resource table has **0 entries** (corrupt
  state from an empty patch delta), invalidate and re-check from pack `0` so
  the device can pull a full materialized inventory again.
- Skip network download when the local file already exists and its sha256
  matches the change entry `hash` (full materialization no longer re-fetches
  unchanged blobs).

## 0.1.1

- Per-patch resource tables: `HotAssets.sync` sends `patch_number`,
  `config_fingerprint`, and `platform` to `/api/v1/resources/check`.
- On `config_fingerprint_mismatch` / release or patch mismatch, invalidate the
  local table and re-fetch (do not keep loading stale config).
- Persist `patch_number` and `config_fingerprint` in `.asset_table.json`.
- `HotAssets.init` treats a provided `releaseVersion` as authoritative — a newer
  binary (e.g. `1.0.0+2`) will not load a table written for `1.0.0+1`.

## 0.1.0

- Initial release: hot-update Flutter assets via a local resource table and AssetBundle override.
