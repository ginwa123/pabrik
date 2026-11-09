//! Tests for the mcp-oauth-hello-world fixture.
//!
//! Each test spawns the compiled binary on a free port and drives it over
//! real HTTP, so the assertions are about the wire — the same wire pabrik's
//! MCP OAuth client speaks. The end-to-end test through a real pabrik binary
//! lives at `tests/functional/mcp_oauth_hello_world_test.zig`.

import { describe, it, expect, afterEach } from "vitest";
import { spawn, type ChildProcess } from "node:child_process";
import { createServer } from "node:net";
import { createHash, randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const BINARY_PATH = resolve(__dirname, "dist/index.js");
const READY_TIMEOUT_MS = 20_000;

async function getFreePort(): Promise<number> {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.unref();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (addr === null || typeof addr === "string") {
        server.close();
        reject(new Error("getFreePort: could not determine assigned port"));
        return;
      }
      const port = addr.port;
      server.close(() => resolvePort(port));
    });
  });
}

interface Fixture {
  child: ChildProcess;
  base: string;
}

async function startFixture(): Promise<Fixture> {
  const port = await getFreePort();
  const child = spawn(process.execPath, [BINARY_PATH, String(port)], {
    stdio: ["ignore", "pipe", "pipe"],
  });

  await new Promise<void>((resolveReady, reject) => {
    const timer = setTimeout(() => {
      reject(
        new Error(`fixture did not become ready within ${READY_TIMEOUT_MS}ms`),
      );
    }, READY_TIMEOUT_MS);
    let stderr = "";
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      if (stderr.includes("listening on")) {
        clearTimeout(timer);
        resolveReady();
      }
    });
    child.on("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`fixture exited early (code ${code}): ${stderr}`));
    });
  });

  return { child, base: `http://127.0.0.1:${port}` };
}

function stopFixture(fixture: Fixture | undefined): void {
  if (!fixture) return;
  fixture.child.kill("SIGKILL");
}

function pkce(): { verifier: string; challenge: string } {
  const verifier = randomBytes(48).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  return { verifier, challenge };
}

async function register(base: string, redirectUri: string): Promise<string> {
  const res = await fetch(`${base}/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      client_name: "vitest",
      redirect_uris: [redirectUri],
      token_endpoint_auth_method: "none",
    }),
  });
  expect(res.status).toBe(201);
  const body = (await res.json()) as { client_id: string };
  return body.client_id;
}

async function authorize(
  base: string,
  clientId: string,
  redirectUri: string,
  challenge: string,
  resource: string,
): Promise<string> {
  const url = new URL(`${base}/authorize`);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", clientId);
  url.searchParams.set("redirect_uri", redirectUri);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("state", "state-1");
  url.searchParams.set("resource", resource);

  const res = await fetch(url, { redirect: "manual" });
  expect(res.status).toBe(302);
  const location = res.headers.get("location");
  expect(location).toBeTruthy();
  const redirected = new URL(location!);
  expect(redirected.searchParams.get("state")).toBe("state-1");
  const code = redirected.searchParams.get("code");
  expect(code).toBeTruthy();
  return code!;
}

async function exchange(
  base: string,
  params: Record<string, string>,
): Promise<Response> {
  return fetch(`${base}/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(params).toString(),
  });
}

async function fullFlow(base: string): Promise<{
  clientId: string;
  redirectUri: string;
  verifier: string;
  accessToken: string;
  refreshToken: string;
}> {
  const redirectUri = "http://127.0.0.1:9999/callback";
  const resource = `${base}/mcp`;
  const clientId = await register(base, redirectUri);
  const { verifier, challenge } = pkce();
  const code = await authorize(
    base,
    clientId,
    redirectUri,
    challenge,
    resource,
  );

  const res = await exchange(base, {
    grant_type: "authorization_code",
    code,
    redirect_uri: redirectUri,
    client_id: clientId,
    code_verifier: verifier,
    resource,
  });
  expect(res.status).toBe(200);
  const body = (await res.json()) as {
    access_token: string;
    refresh_token: string;
  };
  return {
    clientId,
    redirectUri,
    verifier,
    accessToken: body.access_token,
    refreshToken: body.refresh_token,
  };
}

describe("mcp-oauth-hello-world", () => {
  let fixture: Fixture | undefined;

  afterEach(() => {
    stopFixture(fixture);
    fixture = undefined;
  });

  it("an unauthenticated /mcp request answers 401 with a resource_metadata challenge", async () => {
    fixture = await startFixture();
    const res = await fetch(`${fixture.base}/mcp`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: "1", method: "tools/list" }),
    });

    expect(res.status).toBe(401);
    const challenge = res.headers.get("www-authenticate") ?? "";
    expect(challenge).toContain("Bearer");
    expect(challenge).toContain(
      `resource_metadata="${fixture.base}/.well-known/oauth-protected-resource/mcp"`,
    );
    expect(challenge).toContain('scope="hello:read"');
  });

  it("the protected resource metadata names the mcp endpoint and the authorization server", async () => {
    fixture = await startFixture();
    const res = await fetch(
      `${fixture.base}/.well-known/oauth-protected-resource/mcp`,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      resource: string;
      authorization_servers: string[];
      scopes_supported: string[];
    };
    expect(body.resource).toBe(`${fixture.base}/mcp`);
    expect(body.authorization_servers).toEqual([fixture.base]);
    expect(body.scopes_supported).toContain("hello:read");
  });

  it("the authorization server metadata advertises S256 and the three endpoints", async () => {
    fixture = await startFixture();
    const res = await fetch(
      `${fixture.base}/.well-known/oauth-authorization-server`,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      issuer: string;
      authorization_endpoint: string;
      token_endpoint: string;
      registration_endpoint: string;
      code_challenge_methods_supported: string[];
    };
    expect(body.issuer).toBe(fixture.base);
    expect(body.authorization_endpoint).toBe(`${fixture.base}/authorize`);
    expect(body.token_endpoint).toBe(`${fixture.base}/token`);
    expect(body.registration_endpoint).toBe(`${fixture.base}/register`);
    expect(body.code_challenge_methods_supported).toEqual(["S256"]);
  });

  it("dynamic registration returns a client id that /authorize accepts", async () => {
    fixture = await startFixture();
    const redirectUri = "http://127.0.0.1:9999/callback";
    const clientId = await register(fixture.base, redirectUri);
    expect(clientId.length).toBeGreaterThan(0);

    const { challenge } = pkce();
    const code = await authorize(
      fixture.base,
      clientId,
      redirectUri,
      challenge,
      `${fixture.base}/mcp`,
    );
    expect(code.length).toBeGreaterThan(0);
  });

  it("the authorization code exchange returns a bearer token that /mcp accepts", async () => {
    fixture = await startFixture();
    const { accessToken } = await fullFlow(fixture.base);

    const res = await fetch(`${fixture.base}/mcp`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: "1", method: "tools/list" }),
    });

    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toContain("print_hello");
    expect(text).toContain("print_name");
    expect(text).toContain("print_exit");
  });

  it("a wrong code_verifier is rejected with invalid_grant", async () => {
    fixture = await startFixture();
    const redirectUri = "http://127.0.0.1:9999/callback";
    const resource = `${fixture.base}/mcp`;
    const clientId = await register(fixture.base, redirectUri);
    const { challenge } = pkce();
    const code = await authorize(
      fixture.base,
      clientId,
      redirectUri,
      challenge,
      resource,
    );

    const res = await exchange(fixture.base, {
      grant_type: "authorization_code",
      code,
      redirect_uri: redirectUri,
      client_id: clientId,
      code_verifier: "not-the-verifier",
      resource,
    });

    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toBe("invalid_grant");
  });

  it("a token request without the resource parameter is rejected with invalid_target", async () => {
    fixture = await startFixture();
    const redirectUri = "http://127.0.0.1:9999/callback";
    const resource = `${fixture.base}/mcp`;
    const clientId = await register(fixture.base, redirectUri);
    const { verifier, challenge } = pkce();
    const code = await authorize(
      fixture.base,
      clientId,
      redirectUri,
      challenge,
      resource,
    );

    const res = await exchange(fixture.base, {
      grant_type: "authorization_code",
      code,
      redirect_uri: redirectUri,
      client_id: clientId,
      code_verifier: verifier,
    });

    expect(res.status).toBe(400);
    const body = (await res.json()) as { error: string };
    expect(body.error).toBe("invalid_target");
  });

  it("a code cannot be exchanged twice", async () => {
    fixture = await startFixture();
    const redirectUri = "http://127.0.0.1:9999/callback";
    const resource = `${fixture.base}/mcp`;
    const clientId = await register(fixture.base, redirectUri);
    const { verifier, challenge } = pkce();
    const code = await authorize(
      fixture.base,
      clientId,
      redirectUri,
      challenge,
      resource,
    );

    const params = {
      grant_type: "authorization_code",
      code,
      redirect_uri: redirectUri,
      client_id: clientId,
      code_verifier: verifier,
      resource,
    };
    expect((await exchange(fixture.base, params)).status).toBe(200);

    const replay = await exchange(fixture.base, params);
    expect(replay.status).toBe(400);
    const body = (await replay.json()) as { error: string };
    expect(body.error).toBe("invalid_grant");
  });

  it("the refresh grant returns a new access token", async () => {
    fixture = await startFixture();
    const { clientId, accessToken, refreshToken } = await fullFlow(
      fixture.base,
    );

    const res = await exchange(fixture.base, {
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: clientId,
      resource: `${fixture.base}/mcp`,
    });

    expect(res.status).toBe(200);
    const body = (await res.json()) as { access_token: string };
    expect(body.access_token).not.toBe(accessToken);

    const mcp = await fetch(`${fixture.base}/mcp`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
        Authorization: `Bearer ${body.access_token}`,
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: "1", method: "tools/list" }),
    });
    expect(mcp.status).toBe(200);
  });

  it("an unknown bearer token is rejected", async () => {
    fixture = await startFixture();
    const res = await fetch(`${fixture.base}/mcp`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer at_not_a_real_token",
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: "1", method: "tools/list" }),
    });
    expect(res.status).toBe(401);
  });
});
