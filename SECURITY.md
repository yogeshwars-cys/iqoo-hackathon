# Vault security architecture

What is protected, how, what has been verified, and what has not. Code
comments point here for the threat model. Nothing below claims a hardware
property that has not been observed on a device.

## Components

| Concern | Where | Mechanism |
|---|---|---|
| Chunk text at rest | `KeystoreChannel.kt`, `vector_store.dart` | AES-256-GCM, AndroidKeyStore key `vault_tee_aes_master` (StrongBox attempted, TEE KeyStore otherwise), `IV(12) ‖ ct ‖ tag(16)` in `chunks.content_cipher` |
| Capsule authenticity | `capsule_signing.dart`, `capsule_signer.dart` | ECDSA P-256 / SHA-256, AndroidKeyStore key `vault_tee_attestation`, DER signature |
| Desktop trust | `bridge/vault_cli/capsule_verify.py` | digest → signature → **pinned** key; attestation chain parsed at enrollment |
| Clipboard link | `vaultlink_secure.dart`, `vault_cli/vaultlink_protocol.py` | VAULTLINK/2: pairing code → HMAC-SHA256 key schedule → AES-256-GCM frames, direction-separated keys, ±5 min skew, replay cache |
| Clipboard residue | `ephemeral_clipboard.dart`, `vaultlink.py` | 20 s TTL, clear only if still byte-identical |
| Network | `android/app/build.gradle.kts` flavors | `airgap` release has no network permission; `lan` keeps `INTERNET` |

## Canonical capsule signature (`vault-capsule-sig/v1`)

```
payload = LP(tag) LP(query) LP(answer) LP(timestamp) LP(gating_path)
          LPL(chunk_ids) LP(confidence) LPL(key_fact_texts)
          LPL(sha256_hex(context_content)) LP(device) LP(key_security_level)
          LP(sha256_hex(public_key_der))
LP(s)   = "<utf8 byte length>:" utf8(s)          LPL(xs) = LP(concat(LP(x)))
canonical_digest = hex(SHA-256(payload))
signature        = ECDSA-P256-SHA256(payload)    # hashed once, by the keystore
```

**Deliberate deviation from `query|answer|timestamp|gating|ids`:** a pipe-joined
string is not injective (`"a|b","c"` and `"a","b|c"` sign identically), and it
leaves `context[].content` and `key_facts` unsigned, so a relay could rewrite
the quoted evidence under a valid signature. The length-prefixed form fixes
both. The shared vector `bridge/tests/vectors/cross_language_vectors.json` is
asserted by both the Dart and Python suites.

Unsigned on purpose: similarity scores and latency telemetry (they are floats,
formatted differently per language; the gating path they produced is signed).

## Trust model

- A public key inside a capsule proves nothing on its own. A capsule is
  **trusted** only if it verifies under the key pinned by an explicit
  enrollment (`vaultlink.py enroll`, over the paired VAULTLINK/2 channel).
- A different key never silently replaces a pinned one (`TRUSTED_KEY_MISMATCH`).
  To re-enroll, run `unenroll` and then `enroll`.
- `key_security_level` is reported by the phone's KeyInfo and signed, but it is
  still **self-reported**. It is only hardware-proven when the attestation chain
  checks out against a Google hardware-attestation root that you supply with
  `--attestation-root`. The CLI prints which of the two cases applies.

## VaultLink v2: what it does and does not stop

Stops: another app or process querying the vault through the clipboard;
clipboard observers or the sync path reading questions and answers; forged or
modified replies; replies reflected back as requests; stale replays.

Does not stop:
- Malware running as the same Windows user. DPAPI protects the pairing root
  from other accounts, not from your own processes.
- Shoulder-surfing the pairing code. It is hidden until tapped.
- Replay of a captured request after the phone app restarts (the replay cache
  lives in memory). Impact is limited: every op is read-only, and replies are
  sealed to the paired laptop.
- Traffic analysis: frame sizes and timing are visible.

## Verified in this environment

- Host: `flutter test` (213 tests), `flutter analyze` (clean), bridge `pytest tests/` (66 tests).
- The raw SQLite file, including after a plaintext→encrypted migration, contains
  no plaintext marker bytes (`secure_delete` + `VACUUM`).
- JDK 21 JCA (`SHA256withECDSA`, `AES/GCM/NoPadding`, the same calls
  `KeystoreChannel.kt` makes) → Python `cryptography` verifies the signature and
  opens the payload; tampering is rejected.
- `aapt2 dump permissions`: `app-airgap-release.apk` has no network permission;
  `app-lan-release.apk` has `android.permission.INTERNET`.
- Real Win32 clipboard: an unchanged reply is erased, and replaced content is left alone.

## Not yet verified (needs the iQOO 15)

- Keys actually generated in StrongBox or the TEE (`keyStatus`), and StrongBox
  acceptance of the specs. The code falls back to the TEE when StrongBox refuses.
- Real attestation chain contents and root.
- On-device ranking latency. Run
  `flutter run --release --flavor airgap -t lib/bench_rank_main.dart`
  (target: median < 3 ms for 1,000×384). Host JIT median was 0.6–0.8 ms, which is
  not a device figure.
- Per-chunk ingest cost on StrongBox (expect tens of ms per keystore op).
- Android clipboard behaviour (EXTRA_IS_SENSITIVE, background read refusal).

## Known limitations and next steps

1. **Embeddings are plaintext.** MiniLM vectors allow partial content
   inference (topic, near-duplicate detection, and inversion attacks exist in
   the literature). Next step: encrypt the `embedding` column too, decrypt it
   once into the RAM matrix at `open()`, and zeroise on background.
2. **Unlocked-device binding.** Add `setUnlockedDeviceRequired(true)` (API 28+)
   to both keys after testing on the device, so a locked or stolen phone cannot
   decrypt even with a live process.
3. **Fresh attestation challenge.** Generate the signing key at enrollment with
   a laptop-supplied challenge, not a fixed string, so the chain proves
   freshness as well as provenance.
4. **Fix retrieval before blaming the model.** On the device, chunks of 256
   *words* ran ~400 tokens, so MiniLM (254-token window) never saw 35–38% of
   each chunk. Chunk by tokens (≤ ~200, ~40 overlap) and re-index.
5. **LAN bridge is `ws://` cleartext.** For the `lan` flavor, move to TLS with a
   pinned self-signed cert, or Noise over the pairing secret, and require the
   same pairing as VaultLink.
6. **Persist the replay cache** (last-seen timestamp per kid) so requests
   captured before an app restart are rejected too.
7. **Request-side PAKE.** Replacing the typed 20-character code with SPAKE2 plus
   a 6-digit comparison would be friendlier and just as strong.
8. **Remove legacy v1** once all laptop scripts use v2.
