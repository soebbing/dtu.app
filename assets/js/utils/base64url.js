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

// Convert the base64url-encoded BINARY members of a server-sent
// `publicKey` options object into ArrayBuffers, leaving every other
// member untouched.
//
// Only these members are binary per the WebAuthn spec:
//   * `challenge`
//   * `user.id`                       (registration)
//   * `excludeCredentials[].id`       (registration)
//   * `allowCredentials[].id`         (authentication)
//
// Everything else is a plain string the browser needs verbatim
// (`rp.id`, `rp.name`, `user.name`, `user.displayName`, `attestation`,
// `pubKeyCredParams[].type`, `authenticatorSelection.*`, transports, …).
// Decoding those indiscriminately not only corrupts them, it can throw:
// `atob("dtu.app")` raises `InvalidCharacterError` because "." is not a
// base64 character.
export function decodePublicKey(pk) {
  if (pk == null) return pk;
  if (typeof pk !== "object") return pk;

  const out = { ...pk };

  if (typeof out.challenge === "string") {
    out.challenge = decode(out.challenge).buffer;
  }

  if (out.user && typeof out.user === "object") {
    out.user = { ...out.user };
    if (typeof out.user.id === "string") {
      out.user.id = decode(out.user.id).buffer;
    }
  }

  for (const key of ["excludeCredentials", "allowCredentials"]) {
    if (Array.isArray(out[key])) {
      out[key] = out[key].map((cred) => {
        if (!cred || typeof cred !== "object") return cred;
        const next = { ...cred };
        if (typeof next.id === "string") next.id = decode(next.id).buffer;
        return next;
      });
    }
  }

  return out;
}
