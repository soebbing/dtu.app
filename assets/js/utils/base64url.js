// Base64URL <-> Uint8Array helpers used by every WebAuthn code path.
// Browsers hand us ArrayBuffers; we serialize them as base64url strings
// to round-trip through JSON.

export function encode(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function decode(str) {
  const padded = str.replace(/-/g, "+").replace(/_/g, "/");
  const padding = padded.length % 4 === 0 ? "" : "=".repeat(4 - (padded.length % 4));
  const binary = atob(padded + padding);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    out[i] = binary.charCodeAt(i);
  }
  return out;
}

// PublicKeyCredential JSON serialization:
// https://w3c.github.io/webauthn/#dictdef-registrationresponsejson
export function serializeCredential(credential) {
  return {
    id: credential.id,
    rawId: encode(new Uint8Array(credential.rawId)),
    type: credential.type,
    response: {
      clientDataJSON: encode(new Uint8Array(credential.response.clientDataJSON)),
      attestationObject: credential.response.attestationObject
        ? encode(new Uint8Array(credential.response.attestationObject))
        : undefined,
      authenticatorData: credential.response.authenticatorData
        ? encode(new Uint8Array(credential.response.authenticatorData))
        : undefined,
      signature: credential.response.signature
        ? encode(new Uint8Array(credential.response.signature))
        : undefined,
      userHandle: credential.response.userHandle
        ? encode(new Uint8Array(credential.response.userHandle))
        : undefined
    }
  };
}

// Recursively convert base64url strings in a `publicKey` object into
// Uint8Arrays (and ArrayBuffers where the WebAuthn API requires them).
export function decodePublicKey(pk) {
  if (pk == null) return pk;
  if (typeof pk === "string") return decode(pk).buffer;
  if (Array.isArray(pk)) return pk.map(decodePublicKey);
  if (typeof pk === "object") {
    const out = {};
    for (const k of Object.keys(pk)) {
      out[k] = decodePublicKey(pk[k]);
    }
    return out;
  }
  return pk;
}
