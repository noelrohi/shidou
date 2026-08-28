/** Minimal App Store Connect API client — just enough to find or create the
 *  app record and nothing more. Authenticated the same way altool is: an
 *  ES256 JWT signed with the team's API key (.p8), good for at most 20
 *  minutes. Endpoint shapes follow Apple's App Store Connect API; the
 *  create-an-app body follows fastlane's spaceship implementation. */

const ascBaseUrl = "https://api.appstoreconnect.apple.com";
const tokenLifetimeSeconds = 20 * 60;

/** URL-safe base64 without padding — JWT segment encoding. */
export function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64urlDecode(segment: string): Uint8Array {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

export function decodeJwtClaims(token: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(base64urlDecode(token.split(".")[1]!)));
}

/** Extracts the base64 payload of a PEM body. */
function pemBody(pem: string): Uint8Array {
  const body = pem
    .split("\n")
    .filter((line) => !line.includes("-----"))
    .join("");
  if (!body) {
    throw new Error("The API key file is not a PEM-encoded private key.");
  }
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

/** A short-lived App Store Connect API token. Apple rejects `exp` more than
 *  20 minutes out and tokens without an `iat`. */
export async function createAscToken(options: {
  keyId: string;
  issuerId: string;
  p8: string;
  now?: number;
}): Promise<string> {
  const now = options.now ?? Math.floor(Date.now() / 1000);
  const header = base64url(
    new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: options.keyId, typ: "JWT" })),
  );
  const payload = base64url(
    new TextEncoder().encode(
      JSON.stringify({
        iss: options.issuerId,
        iat: now,
        exp: now + tokenLifetimeSeconds,
        aud: "appstoreconnect-v1",
      }),
    ),
  );

  const privateKey = await crypto.subtle
    .importKey(
      "pkcs8",
      pemBody(options.p8),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    )
    .catch(() => {
      throw new Error(
        "The API key file does not contain a PEM-encoded EC P-256 private key.",
      );
    });
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    new TextEncoder().encode(`${header}.${payload}`),
  );
  // WebCrypto's ECDSA signatures are already the raw r||s form JWTs want.
  return `${header}.${payload}.${base64url(new Uint8Array(signature))}`;
}

/** The POST /v1/apps body. The app's name does not live on the app itself —
 *  it arrives as an appInfoLocalization in `included`, keyed to the appInfo
 *  through the `${new-appInfo-id}` placeholder the server resolves. */
export function createAppBody(options: {
  name: string;
  sku: string;
  primaryLocale: string;
  bundleId: string;
  companyName?: string;
}): {
  data: {
    type: string;
    attributes: Record<string, string>;
    relationships: {
      appInfos: { data: Array<{ type: string; id: string }> };
    };
  };
  included: Array<{
    type: string;
    id: string;
    attributes?: Record<string, string>;
    relationships?: Record<string, unknown>;
  }>;
} {
  const attributes: Record<string, string> = {
    sku: options.sku,
    primaryLocale: options.primaryLocale,
    bundleId: options.bundleId,
  };
  if (options.companyName) attributes.companyName = options.companyName;
  return {
    data: {
      type: "apps",
      attributes,
      relationships: {
        appInfos: {
          data: [{ type: "appInfos", id: "${new-appInfo-id}" }],
        },
      },
    },
    included: [
      {
        type: "appInfos",
        id: "${new-appInfo-id}",
        relationships: {
          appInfoLocalizations: {
            data: [{ type: "appInfoLocalizations", id: "${new-appInfoLocalization-id}" }],
          },
        },
      },
      {
        type: "appInfoLocalizations",
        id: "${new-appInfoLocalization-id}",
        attributes: { locale: options.primaryLocale, name: options.name },
      },
    ],
  };
}

export class AscApi {
  private token: Promise<string>;

  constructor(
    private keyId: string,
    private issuerId: string,
    p8: string,
  ) {
    this.token = createAscToken({ keyId, issuerId, p8 });
  }

  private async request(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<unknown> {
    const response = await fetch(`${ascBaseUrl}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${await this.token}`,
        "Content-Type": "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!response.ok) {
      const detail = await response.text().catch(() => "");
      throw new Error(
        `App Store Connect API ${method} ${path} failed: ` +
          `${response.status} ${detail.slice(0, 500)}`,
      );
    }
    if (response.status === 204) return null;
    return response.json();
  }

  /** The existing app for a bundle id, or null. */
  async findAppByBundleId(bundleId: string): Promise<{ id: string } | null> {
    const result = (await this.request(
      "GET",
      `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}`,
    )) as { data?: Array<{ id: string }> };
    return result.data?.[0] ?? null;
  }

  /** The existing bundle-id registration, or null. Xcode's automatic signing
   *  registers the id on the first archive, so a miss here is rare — but a
   *  fresh key on a clean team hits it. */
  async findBundleIdRegistration(
    bundleId: string,
  ): Promise<{ id: string } | null> {
    const result = (await this.request(
      "GET",
      `/v1/bundleIdRegistrations?filter[identifier]=${encodeURIComponent(bundleId)}`,
    )) as { data?: Array<{ id: string }> };
    return result.data?.[0] ?? null;
  }

  async registerBundleId(bundleId: string): Promise<{ id: string }> {
    const result = (await this.request("POST", "/v1/bundleIdRegistrations", {
      data: {
        type: "bundleIdRegistrations",
        attributes: { identifier: bundleId, platform: "IOS" },
      },
    })) as { data: { id: string } };
    return result.data;
  }

  async createApp(options: {
    name: string;
    sku: string;
    primaryLocale: string;
    bundleId: string;
    companyName?: string;
  }): Promise<{ id: string }> {
    const result = (await this.request("POST", "/v1/apps", createAppBody(options))) as {
      data: { id: string };
    };
    return result.data;
  }
}
