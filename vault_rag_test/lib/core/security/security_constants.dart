/// security_constants.dart
///
/// Every magic number the security and retrieval architecture depends on,
/// in one place. Kotlin mirrors the channel name and aliases in
/// KeystoreChannel.kt, and bridge/vault_cli/capsule_verify.py mirrors the
/// canonical-signing constants — change one side and the other must follow,
/// which is exactly why they are not scattered through call sites.

library;

/// MethodChannel carrying every AndroidKeyStore operation.
const kKeystoreChannel = 'vault/keystore';

/// AES-256-GCM key that encrypts chunk content at rest. Never leaves
/// AndroidKeyStore.
const kAesMasterAlias = 'vault_tee_aes_master';

/// ECDSA P-256 key that signs context capsules. Never leaves AndroidKeyStore.
const kSigningAlias = 'vault_tee_attestation';

/// AES-GCM wire layout: `IV(12) || ciphertext || tag(16)`.
const kGcmIvLength = 12;
const kGcmTagLength = 16;
const kGcmMinPayloadLength = kGcmIvLength + kGcmTagLength;

/// all-MiniLM-L6-v2 output width. The vector matrix is laid out in strides
/// of exactly this many float32s.
const kEmbeddingDim = 384;

/// Retrieval-score gates for [VaultEngine.ask]. See vault_engine.dart.
const kTier1Threshold = 0.82;
const kTier2Threshold = 0.50;

/// How long a capsule may sit on the clipboard before Vault scrubs it.
const kClipboardTtl = Duration(seconds: 20);

/// Answer returned verbatim below [kTier2Threshold].
const kNoRelevantFactsAnswer = 'No relevant facts found in vault.';
