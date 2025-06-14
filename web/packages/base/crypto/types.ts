/**
 * @file types shared between the public API (main thread) and implementation
 * (worker thread). Also some constants, but no code.
 */
import { type StateAddress } from "libsodium-wrappers-sumo";

/**
 * An opaque object meant to be threaded through various functions that deal
 * with resumable chunk based processing.
 */
export type SodiumStateAddress = StateAddress;

/**
 * The various *Stream encryption functions break up the input into chunks of
 * {@link streamEncryptionChunkSize} bytes during encryption (except the last
 * chunk which can be smaller since a file would rarely align exactly to a
 * {@link streamEncryptionChunkSize} multiple).
 *
 * The various *Stream decryption functions also assume that each potential
 * chunk is {@link streamEncryptionChunkSize} long.
 *
 * This value of this constant is 4 MB (and is unlikely to change).
 */
export const streamEncryptionChunkSize = 4 * 1024 * 1024;

/**
 * The message of the {@link Error} that is thrown by {@link deriveSensitiveKey}
 * if we could not find acceptable ops and mem limit combinations without
 * exceeded the maximum mem limit.
 *
 * Generally, this indicates that the current device is not powerful enough to
 * perform the key derivation. This is rare for computers, but can happen with
 * older mobile devices with too little RAM.
 */
export const deriveKeyInsufficientMemoryErrorMessage =
    "Failed to derive key (insufficient memory)";

/**
 * Data provided either as bytes ({@link Uint8Array}) or their base64 string
 * representation.
 */
export type BytesOrB64 = Uint8Array | string;

/**
 * The result of encryption using the secretbox APIs.
 *
 * It contains an encrypted data and a randomly generated nonce that was used
 * during encryption. Both these values are needed to decrypt the data. The
 * nonce does not need to be secret.
 *
 * See: [Note: 3 forms of encryption (Box | Blob | Stream)].
 */
export interface EncryptedBox {
    /**
     * The data to decrypt.
     */
    encryptedData: BytesOrB64;
    /**
     * The nonce that was used during encryption.
     *
     * The nonce is required to decrypt the data, but it does not need to be
     * kept secret.
     */
    nonce: BytesOrB64;
}

export interface EncryptedBoxB64 {
    /**
     * The encrypted data as a base64 string.
     */
    encryptedData: string;
    /**
     * The nonce that was used during encryption, as a base64 string.
     *
     * The nonce is required to decrypt the data, but it does not need to be
     * kept secret.
     */
    nonce: string;
}

/**
 * The result of encryption using the secretstream APIs without chunking.
 *
 * It contains an encrypted data and a header that should be provided during
 * decryption. The header does not need to be secret.
 *
 * See: [Note: 3 forms of encryption (Box | Blob | Stream)].
 *
 * This type is a combination of {@link EncryptedBlobBytes} and
 * {@link EncryptedBlobB64} which allows the decryption routines to accept
 * either the bytes or the base64 variants produced by the encryption routines.
 */
export interface EncryptedBlob {
    /**
     * The encrypted data.
     */
    encryptedData: BytesOrB64;
    /**
     * The decryption header.
     *
     * While the exact contents of the header are libsodium's internal details,
     * it effectively contains a random nonce generated by libsodium. It does
     * not need to be secret, but it is required to decrypt the data.
     */
    decryptionHeader: BytesOrB64;
}

/**
 * A variant of {@link EncryptedBlob} that has the encrypted data and header
 * as bytes ({@link Uint8Array}s).
 */
export interface EncryptedBlobBytes {
    /**
     * The encrypted data.
     */
    encryptedData: Uint8Array;
    /**
     * The decryption header.
     *
     * While the exact contents of the header are libsodium's internal details,
     * it effectively contains a random nonce generated by libsodium. It does
     * not need to be secret, but it is required to decrypt the data.
     */
    decryptionHeader: Uint8Array;
}

/**
 * A variant of {@link EncryptedBlob} that has the encrypted data and header
 * as base64 strings.
 */
export interface EncryptedBlobB64 {
    /**
     * The encrypted data as a base64 string.
     */
    encryptedData: string;
    /**
     * A base64 string containing the decryption header.
     *
     * While the exact contents of the header are libsodium's internal details,
     * it effectively contains a random nonce generated by libsodium. It does
     * not need to be secret, but it is required to decrypt the data.
     */
    decryptionHeader: string;
}

/**
 * An intermediate between {@link EncryptedBlobBytes} and
 * {@link EncryptedBlobB64} that has the encrypted as bytes
 * ({@link Uint8Array}s), but the {@link decryptionHeader} as a base64 string.
 *
 * Such a format is handy for encrypting files, since it can then directly be
 * used (the file's encrypted bytes get uploaded separately, whilst the base64
 * decryption header becomes part of the corresponding {@link EnteFile}).
 */
export interface EncryptedFile {
    /**
     * The encrypted data.
     */
    encryptedData: Uint8Array;
    /**
     * A base64 string containing the decryption header.
     *
     * While the exact contents of the header are libsodium's internal details,
     * it effectively contains a random nonce generated by libsodium. It does
     * not need to be secret, but it is required to decrypt the data.
     */
    decryptionHeader: string;
}

/**
 * An object returned by the init function of chunked encryption routines.
 */
export interface InitChunkEncryptionResult {
    /**
     * A base64 string containing the decryption header.
     *
     * While the exact contents of the header are libsodium's internal details,
     * it effectively contains a random nonce generated by libsodium. It does
     * not need to be secret, but it is required to decrypt the data.
     */
    decryptionHeader: string;
    /**
     * An opaque value that refers to the internal state used by the resumable
     * calls in the encryption sequence.
     */
    pushState: SodiumStateAddress;
}

/**
 * An object returned by the init function of chunked decryption routines.
 */
export interface InitChunkDecryptionResult {
    /**
     * An opaque value that refers to the internal state used by the resumable
     * calls in the decryption sequence.
     */
    pullState: SodiumStateAddress;
    /**
     * The expected size of each chunk.
     */
    decryptionChunkSize: number;
}

/**
 * A pair of public and private keys.
 */
export interface KeyPair {
    /**
     * The public key of the keypair, as a base64 encoded string.
     */
    publicKey: string;
    /**
     * The private key of the keypair, as a base64 encoded string.
     *
     * Some places also refer to it as the "secret key".
     *
     * See: [Note: privateKey and secretKey].
     */
    privateKey: string;
}

/**
 * A key derived from a user provided passphrase, and the various attributes
 * that were used during the key derivation.
 */
export interface DerivedKey {
    /**
     * The newly derived key itself, as a base64 encoded string.
     */
    key: string;
    /**
     * The randomly generated salt (as a base64 string) that was used when deriving the key.
     */
    salt: string;
    /**
     * opsLimit used during key derivation.
     */
    opsLimit: number;
    /**
     * memLimit used during key derivation.
     * */
    memLimit: number;
}
