import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";

export interface DotPluginAuth {
  /** Returns the end of this verified access grant, never a caller-supplied owner. */
  authenticate: (authorization: string | undefined) => Promise<number | undefined>;
  resource: string;
  issuer: string;
}
export interface DotOAuthConfig { issuer: string; jwksURL: string; resource: string; subject: string }
function httpsURL(raw: string) {
  const url = new URL(raw);
  if (url.protocol !== "https:" || url.username || url.password || url.hash || url.search) throw new Error("OAuth URLs must be HTTPS without credentials, query, or fragment");
  return url;
}
/** Resource server only. An EXISTING authorization server must provide OAuth 2.1
 * discovery, PKCE/client registration and resource-bound JWT access tokens.
 * No keys, login UI, grants, or OAuth clients are provisioned by this module. */
export function createDotOAuth(config: DotOAuthConfig, getKey?: JWTVerifyGetKey): DotPluginAuth {
  httpsURL(config.issuer);
  if (httpsURL(config.resource).pathname !== "/mcp/dot") throw new Error("OAuth resource must use /mcp/dot");
  const jwks = httpsURL(config.jwksURL);
  if (!config.subject.trim()) throw new Error("OAuth subject binding is required");
  const resolver = getKey ?? createRemoteJWKSet(jwks, { timeoutDuration: 5000, cooldownDuration: 30000, cacheMaxAge: 300000 });
  return {
    resource: config.resource, issuer: config.issuer,
    async authenticate(header) {
      if (!header?.startsWith("Bearer ") || header.length > 16384) return undefined;
      try {
        const { payload } = await jwtVerify(header.slice(7), resolver, {
          issuer: config.issuer, audience: config.resource, subject: config.subject,
          algorithms: ["RS256", "ES256"], typ: "at+jwt", requiredClaims: ["exp", "iat", "sub", "scope"],
        });
        if (typeof payload.exp !== "number" || typeof payload.iat !== "number" || !Number.isSafeInteger(payload.exp) || !Number.isSafeInteger(payload.iat) ||
            payload.exp - payload.iat > 300 || payload.iat > Date.now() / 1000 ||
            typeof payload.scope !== "string" || !payload.scope.split(" ").includes("chime:dot")) return undefined;
        // JWT revocation isn't instantaneous. Bound stored delivery authority to
        // five minutes AND token expiry; refresh revalidates a new access grant.
        return Math.min(payload.exp * 1000, Date.now() + 300000);
      } catch { return undefined; }
    },
  };
}
