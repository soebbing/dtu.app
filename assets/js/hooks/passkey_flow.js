// PasskeyFlow hook — drives both the registration and authentication
// WebAuthn ceremonies. Mounted on the login page (`data-kind="authentication"`)
// and on the settings page (`data-kind="registration"`).
//
// Responsibilities:
//   1. Read the CSRF token from `<meta name="csrf-token">`.
//   2. POST to /auth/passkey/<kind>/begin and get the WebAuthn
//      publicKey options plus the request_id.
//   3. Call navigator.credentials.create() (registration) or
//      navigator.credentials.get() (authentication).
//   4. POST the serialized credential to /auth/passkey/<kind>/finish.
//   5. On success, follow the server's redirect (authentication) or
//      location.reload() (registration).
//
// On the authentication page, also fires a non-awaited
// navigator.credentials.get({mediation: "conditional"}) on mount so
// the browser can show an autofill chip if the user has a passkey
// for this RP.
//
// User-cancelled authenticator prompts (NotAllowedError) are
// swallowed — not an error to show the user.

import {
  decodePublicKey,
  serializeCredential
} from "../utils/base64url.js";

const PasskeyFlow = {
  mounted() {
    this.kind = this.el.dataset.kind; // "registration" | "authentication"
    this.csrf = readCsrfToken();
    this.bindButtons();

    if (this.kind === "authentication") {
      this.fireConditionalMediation();
    }
  },

  bindButtons() {
    const buttons = this.el.querySelectorAll("[data-passkey-action='start']");
    buttons.forEach((btn) => {
      btn.addEventListener("click", async (e) => {
        e.preventDefault();
        btn.disabled = true;
        const originalLabel = btn.textContent;
        btn.textContent = btn.dataset.loadingLabel || "Loading…";

        try {
          const friendlyName = btn.dataset.friendlyName ||
            this.el.querySelector("[name='friendly_name']")?.value ||
            "This device";
          await this.start({ friendlyName });
        } finally {
          btn.disabled = false;
          btn.textContent = originalLabel;
        }
      });
    });
  },

  async start({ friendlyName }) {
    const beginBody = this.kind === "registration"
      ? JSON.stringify({ friendly_name: friendlyName })
      : "{}";

    const beginResp = await fetch(`/auth/passkey/${this.kind}/begin`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrf
      },
      body: beginBody,
      credentials: "same-origin"
    });

    if (!beginResp.ok) {
      this.showError(beginResp);
      return;
    }

    let request_id, publicKey, pk;
    try {
      ({ request_id, publicKey } = await beginResp.json());
      pk = decodePublicKey(publicKey);
    } catch (_) {
      this.showError(beginResp);
      return;
    }

    if (pk == null) {
      this.showError(beginResp);
      return;
    }

    let credential;
    try {
      credential = this.kind === "registration"
        ? await navigator.credentials.create({ publicKey: pk })
        : await navigator.credentials.get({ publicKey: pk });
    } catch (err) {
      // User cancelled the ceremony (closed the OS prompt, hit Esc,
      // walked away) — silent UX.
      if (err && err.name === "NotAllowedError") return;
      // Other DOMExceptions are user-actionable and need a banner:
      //   * SecurityError     — `rp.id` doesn't match the page origin
      //                         (most common prod failure: the server's
      //                         `WEBAUTHN_RP_ID` is wrong for the
      //                         deploy target) or the page is in an
      //                         insecure context.
      //   * InvalidStateError — this authenticator already holds a
      //                         matching credential (re-enrollment).
      //   * NotSupportedError — no usable authenticator on this device.
      // Without this branch they escape to the unhandled-rejection
      // handler and the operator only finds out via DevTools.
      this._showErrorKey((err && err.name) || "unknown_error");
      return;
    }

    const finishBody = JSON.stringify({
      request_id: request_id,
      [this.kind === "registration" ? "attestation_response" : "assertion_response"]:
        serializeCredential(credential)
    });

    const finishResp = await fetch(`/auth/passkey/${this.kind}/finish`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrf
      },
      body: finishBody,
      credentials: "same-origin"
    });

    if (finishResp.ok) {
      const body = await finishResp.json();
      if (this.kind === "authentication" && body.redirect) {
        window.location.href = body.redirect;
      } else {
        location.reload();
      }
    } else {
      this.showError(finishResp);
    }
  },

  fireConditionalMediation() {
    // We need the publicKey from /auth/passkey/authentication/begin
    // first, but we don't want to block the UI. Fire it once mount
    // completes.
    fetch("/auth/passkey/authentication/begin", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrf },
      body: "{}",
      credentials: "same-origin"
    })
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => {
        if (!data) return;
        const pk = decodePublicKey(data.publicKey);
        // `data` is captured here so `completeConditional` can reuse the
        // request_id; referencing it from the next `.then` would be a
        // ReferenceError (swallowed by the trailing `.catch`, which is
        // why the conditional path silently did nothing).
        return navigator.credentials
          .get({ publicKey: pk, mediation: "conditional" })
          .then((cred) => {
            if (!cred) return;
            return this.completeConditional(cred, data.request_id);
          });
      })
      .catch(() => {/* user dismissed */});
  },

  async completeConditional(credential, request_id) {
    const finishResp = await fetch("/auth/passkey/authentication/finish", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": this.csrf },
      body: JSON.stringify({
        request_id: request_id,
        assertion_response: serializeCredential(credential)
      }),
      credentials: "same-origin"
    });

    if (finishResp.ok) {
      const body = await finishResp.json();
      window.location.href = body.redirect || "/";
    } else {
      this.showError(finishResp);
    }
  },

  // Render an error banner for a failed fetch response (server-side
  // ceremony error — 4xx/5xx from the controller). Reads `%{error: ...}`
  // out of the JSON body and falls back to `"unknown_error"`.
  async showError(resp) {
    let body = {};
    try { body = await resp.json(); } catch (_) {}
    this._showErrorKey(body.error || "unknown_error");
  },

  // Render an error banner for a browser-side failure (DOMException
  // from `navigator.credentials.create/get` — `SecurityError`,
  // `InvalidStateError`, `NotSupportedError`, etc.). Called directly
  // so the WebAuthn catch block doesn't have to fabricate a fake
  // `Response` to reuse `showError/1`.
  _showErrorKey(errorKey) {
    const banner = document.querySelector("[data-passkey-error]");
    if (banner) {
      banner.textContent = `Passkey error: ${errorKey}`;
      banner.hidden = false;
    }
  }
};

function readCsrfToken() {
  const meta = document.querySelector("meta[name='csrf-token']");
  return meta ? meta.getAttribute("content") : "";
}

export { PasskeyFlow };
