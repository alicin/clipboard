# Sync format

Clipboard syncs through plain files in a folder, either in iCloud Drive or in Google Drive's hidden app data folder. A client on any platform can join by following this page. The Mac app's implementation is in `Sources/ClipboardCore/Sync`.

## Files

| Name | Contents |
| --- | --- |
| `sync-info.json` | The key derivation settings, as readable JSON |
| `<name>.clip` | One clip, encrypted |
| `<name>.gone` | A deleted clip, encrypted, kept for 30 days so every device hears about it |

Ignore anything else in the folder, such as the conflict copies a sync service can leave behind.

## Encryption

`sync-info.json` holds `format` (1), `salt` and `check` (base64) and `iterations`.

1. The master key is PBKDF2-HMAC-SHA256 of the UTF-8 passphrase and `salt`, for `iterations` rounds, 32 bytes long.
2. HKDF-SHA256 of the master key, with no salt, gives two 32-byte keys: the sealing key with info `clipboard-sync seal`, and the naming key with info `clipboard-sync name`.
3. Each encrypted file is AES-256-GCM with the sealing key, stored as nonce (12 bytes), then ciphertext, then tag (16 bytes).
4. `check` is the text `clipboard-sync` sealed the same way. If it doesn't open, the passphrase is wrong.
5. `<name>` is the lowercase hex HMAC-SHA256 of the clip's `hash`, using the naming key.

## Records

Inside the encryption, each file is JSON. Times are seconds since 1970, and `data` is base64.

```json
{
  "format": 1,
  "hash": "sha256 of the clip's identity",
  "updatedAt": 1793557000.5,
  "deletedAt": null,
  "createdAt": 1793556000.5,
  "sortedAt": 1793556500.5,
  "title": "Optional name the user gave it",
  "sourceBundleID": "com.apple.Notes",
  "sourceName": "Notes",
  "pinboards": [{ "name": "Work", "color": "sky" }],
  "items": [[{ "uti": "public.utf8-plain-text", "data": "aGVsbG8=" }]]
}
```

`.gone` records carry only `format`, `hash`, `updatedAt` and `deletedAt`. Skip any record whose `format` you don't recognize, and don't overwrite it.

`hash` is the SHA-256 of `text:` plus the clip's text, or of `image:` plus the hex SHA-256 of its image bytes, or of `data:` plus the hex SHA-256 of its other contents. The same content therefore lands in the same file on every device.

## Rules

- The record with the newest `updatedAt` wins for a clip's title and pinboards.
- Download before uploading, so a device doesn't overwrite a newer change it hasn't seen.
- Never upload files, or text that looks like a secret, or a clip over 25 MB.
- A retention setting only applies locally. Pruning old clips doesn't write `.gone` files, but deleting one on purpose does.
