import { describe, expect, test } from "bun:test";
import {
  base64url,
  base64urlDecode,
  createAppBody,
  createAscToken,
  decodeJwtClaims,
} from "./asc";

describe("base64url", () => {
  test("encodes without padding and uses the url-safe alphabet", () => {
    expect(base64url(new TextEncoder().encode("{\"alg\":\"ES256\"}"))).toBe(
      "eyJhbGciOiJFUzI1NiJ9",
    );
  });

  test("round-trips arbitrary bytes", () => {
    const bytes = crypto.getRandomValues(new Uint8Array(64));
    expect(base64urlDecode(base64url(bytes))).toEqual(bytes);
  });
});

describe("createAscToken", () => {
  test("produces an ES256 JWT with ASC claims", async () => {
    // A throwaway P-256 key, exported as the PKCS#8 that .p8 files hold.
    const pair = await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" },
      true,
      ["sign", "verify"],
    );
    const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
    const pem = [
      "-----BEGIN PRIVATE KEY-----",
      ...Buffer.from(pkcs8)
        .toString("base64")
        .match(/.{1,64}/g)!,
      "-----END PRIVATE KEY-----",
    ].join("\n");

    const now = 1_700_000_000;
    const token = await createAscToken({
      keyId: "ABC123",
      issuerId: "69a6de7c-0000-0000-0000-000000000000",
      p8: pem,
      now,
    });

    const [headerB64, payloadB64] = token.split(".");
    expect(JSON.parse(atob(headerB64!.replace(/-/g, "+").replace(/_/g, "/")))).toEqual({
      alg: "ES256",
      kid: "ABC123",
      typ: "JWT",
    });
    const payload = decodeJwtClaims(token);
    expect(payload).toEqual({
      iss: "69a6de7c-0000-0000-0000-000000000000",
      iat: now,
      exp: now + 20 * 60,
      aud: "appstoreconnect-v1",
    });

    // The signature verifies against the generated public key. WebCrypto's
    // ECDSA sign output is already the raw r||s form JWTs carry.
    const verified = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      pair.publicKey,
      base64urlDecode(token.split(".")[2]!),
      new TextEncoder().encode(`${headerB64}.${payloadB64}`),
    );
    expect(verified).toBe(true);
  });

  test("rejects a PEM that is not a private key", async () => {
    expect(
      createAscToken({
        keyId: "ABC123",
        issuerId: "iss",
        p8: "not a pem at all",
        now: 0,
      }),
    ).rejects.toThrow(/private key/i);
  });
});

describe("createAppBody", () => {
  test("carries sku, locale, and bundle id, with the name in appInfoLocalizations", () => {
    const body = createAppBody({
      name: "Shidou",
      sku: "dev.shidou.ios",
      primaryLocale: "en-US",
      bundleId: "dev.shidou.ios",
    });
    expect(body.data.attributes).toEqual({
      sku: "dev.shidou.ios",
      primaryLocale: "en-US",
      bundleId: "dev.shidou.ios",
    });
    const localizations = body.included.filter(
      (i) => i.type === "appInfoLocalizations",
    );
    expect(localizations).toHaveLength(1);
    expect(localizations[0]!.attributes).toEqual({
      locale: "en-US",
      name: "Shidou",
    });
    // The appInfos relationship points at the included appInfo placeholder.
    expect(body.data.relationships.appInfos.data).toEqual([
      { type: "appInfos", id: "${new-appInfo-id}" },
    ]);
    expect(body.included.some((i) => i.type === "appInfos")).toBe(true);
  });

  test("keeps companyName when given", () => {
    const body = createAppBody({
      name: "Shidou",
      sku: "s",
      primaryLocale: "en-US",
      bundleId: "b",
      companyName: "Noel Garcia",
    });
    expect(body.data.attributes).toMatchObject({ companyName: "Noel Garcia" });
  });
});
