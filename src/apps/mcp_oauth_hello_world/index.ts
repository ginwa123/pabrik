//! mcp-oauth-hello-world — a tiny OAuth-protected MCP server.
//!
//! Self-test target for pabrik's MCP OAuth client. Same 3 hello tools as
//! `mcp-http-hello-world`, but every `/mcp` request needs a Bearer token, and
//! the process also plays the authorization server so the whole flow can run
//! against one binary:
//!
//!   GET  /.well-known/oauth-protected-resource/mcp   RFC 9728
//!   GET  /.well-known/oauth-authorization-server     RFC 8414
//!   POST /register                                   RFC 7591
//!   GET  /authorize                                  authorization code + PKCE
//!   POST /token                                      code + refresh grants
//!   POST /mcp                                        the MCP endpoint
//!   GET  /health                                     readiness probe
//!
//! `/authorize` auto-approves: a consent form here would be the fixture
//! testing itself, not pabrik. Tokens live in memory for the life of the
//! process — this is a test target, never a real authorization server.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import * as http from "node:http";
import { createHash, randomBytes } from "node:crypto";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { z } from "zod";

const SERVER_NAME = "mcp-oauth-hello-world";
const SERVER_VERSION = "0.0.1";
const DEFAULT_PORT = 3000;
const ACCESS_TOKEN_TTL_SECONDS = 3600;
const CODE_TTL_SECONDS = 60;
const SCOPE = "hello:read";

export interface Client {
  client_id: string;
  redirect_uris: string[];
}

export interface PendingCode {
  code: string;
  client_id: string;
  redirect_uri: string;
  code_challenge: string;
  resource: string;
  scope: string;
  expires_at: number;
}

export interface AccessToken {
  token: string;
  resource: string;
  scope: string;
  expires_at: number;
}

export interface RefreshToken {
  token: string;
  client_id: string;
  resource: string;
  scope: string;
}

export interface State {
  clients: Map<string, Client>;
  codes: Map<string, PendingCode>;
  access_tokens: Map<string, AccessToken>;
  refresh_tokens: Map<string, RefreshToken>;
  token_requests: string[];
}

export function createState(): State {
  return {
    clients: new Map(),
    codes: new Map(),
    access_tokens: new Map(),
    refresh_tokens: new Map(),
    token_requests: [],
  };
}

function base64url(buf: Buffer): string {
  return buf.toString("base64url");
}

function randomToken(prefix: string): string {
  return `${prefix}_${base64url(randomBytes(24))}`;
}

function s256(verifier: string): string {
  return base64url(createHash("sha256").update(verifier).digest());
}

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

function sameResource(a: string, b: string): boolean {
  const strip = (s: string) => s.replace(/\/+$/, "");
  return strip(a) === strip(b);
}

function readBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function sendJson(
  res: http.ServerResponse,
  status: number,
  body: unknown,
  headers: Record<string, string> = {},
): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(payload).toString(),
    ...headers,
  });
  res.end(payload);
}

function sendOAuthError(
  res: http.ServerResponse,
  status: number,
  error: string,
  description: string,
): void {
  sendJson(res, status, { error, error_description: description });
}

function getServer(): McpServer {
  const mcp = new McpServer({ name: SERVER_NAME, version: SERVER_VERSION });
  mcp.tool(
    "print_hello",
    "Print a greeting. Optional argument `name` (string) — defaults to `world`.",
    { name: z.string().optional() },
    async (args: { name?: string }) => ({
      content: [{ type: "text", text: `Hello ${args?.name ?? "world"}` }],
    }),
  );
  mcp.tool(
    "print_name",
    "Print this server's name and version. Takes no arguments.",
    async () => ({
      content: [
        { type: "text", text: `i am ${SERVER_NAME} v${SERVER_VERSION}` },
      ],
    }),
  );
  mcp.tool(
    "print_exit",
    "Print a goodbye message. (No-op in HTTP mode — there's no child process to exit.)",
    async () => ({ content: [{ type: "text", text: "exiting" }] }),
  );
  return mcp;
}

export interface App {
  server: http.Server;
  state: State;
  origin: () => string;
}

export function createApp(port: number): App {
  const state = createState();
  const origin = () => `http://127.0.0.1:${port}`;
  const resourceUrl = () => `${origin()}/mcp`;
  const prmUrl = () => `${origin()}/.well-known/oauth-protected-resource/mcp`;

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", origin());
    const path = url.pathname;

    try {
      if (req.method === "GET" && path === "/health") {
        res.writeHead(200, { "Content-Type": "text/plain" });
        res.end("ok");
        return;
      }

      if (
        req.method === "GET" &&
        path === "/.well-known/oauth-protected-resource/mcp"
      ) {
        sendJson(res, 200, {
          resource: resourceUrl(),
          authorization_servers: [origin()],
          scopes_supported: [SCOPE],
          bearer_methods_supported: ["header"],
        });
        return;
      }

      if (
        req.method === "GET" &&
        path === "/.well-known/oauth-authorization-server"
      ) {
        sendJson(res, 200, {
          issuer: origin(),
          authorization_endpoint: `${origin()}/authorize`,
          token_endpoint: `${origin()}/token`,
          registration_endpoint: `${origin()}/register`,
          scopes_supported: [SCOPE],
          response_types_supported: ["code"],
          grant_types_supported: ["authorization_code", "refresh_token"],
          code_challenge_methods_supported: ["S256"],
          token_endpoint_auth_methods_supported: ["none"],
        });
        return;
      }

      if (req.method === "POST" && path === "/register") {
        const raw = await readBody(req);
        let body: { redirect_uris?: unknown; client_name?: unknown } = {};
        try {
          body = JSON.parse(raw || "{}");
        } catch {
          sendOAuthError(
            res,
            400,
            "invalid_client_metadata",
            "body is not JSON",
          );
          return;
        }
        const uris = Array.isArray(body.redirect_uris)
          ? body.redirect_uris.filter((u): u is string => typeof u === "string")
          : [];
        if (uris.length === 0) {
          sendOAuthError(
            res,
            400,
            "invalid_redirect_uri",
            "redirect_uris must be a non-empty array of strings",
          );
          return;
        }
        const client: Client = {
          client_id: randomToken("client"),
          redirect_uris: uris,
        };
        state.clients.set(client.client_id, client);
        sendJson(
          res,
          201,
          {
            client_id: client.client_id,
            redirect_uris: client.redirect_uris,
            token_endpoint_auth_method: "none",
            grant_types: ["authorization_code", "refresh_token"],
            response_types: ["code"],
          },
          { "Cache-Control": "no-store" },
        );
        return;
      }

      if (req.method === "GET" && path === "/authorize") {
        const q = url.searchParams;
        const clientId = q.get("client_id") ?? "";
        const redirectUri = q.get("redirect_uri") ?? "";
        const challenge = q.get("code_challenge") ?? "";
        const method = q.get("code_challenge_method") ?? "";
        const resource = q.get("resource") ?? "";
        const scope = q.get("scope") || SCOPE;
        const st = q.get("state") ?? "";

        const client = state.clients.get(clientId);
        if (!client) {
          sendOAuthError(res, 400, "invalid_client", "unknown client_id");
          return;
        }
        if (!client.redirect_uris.includes(redirectUri)) {
          sendOAuthError(
            res,
            400,
            "invalid_request",
            "redirect_uri is not registered for this client",
          );
          return;
        }
        if (q.get("response_type") !== "code") {
          sendOAuthError(
            res,
            400,
            "unsupported_response_type",
            "only response_type=code is supported",
          );
          return;
        }
        if (method !== "S256" || challenge.length === 0) {
          sendOAuthError(
            res,
            400,
            "invalid_request",
            "code_challenge with code_challenge_method=S256 is required",
          );
          return;
        }
        if (resource.length === 0 || !sameResource(resource, resourceUrl())) {
          sendOAuthError(
            res,
            400,
            "invalid_target",
            `resource must be ${resourceUrl()}`,
          );
          return;
        }

        const code = randomToken("code");
        state.codes.set(code, {
          code,
          client_id: clientId,
          redirect_uri: redirectUri,
          code_challenge: challenge,
          resource,
          scope,
          expires_at: nowSeconds() + CODE_TTL_SECONDS,
        });

        const location = new URL(redirectUri);
        location.searchParams.set("code", code);
        if (st.length > 0) location.searchParams.set("state", st);
        res.writeHead(302, { Location: location.toString() });
        res.end();
        return;
      }

      if (req.method === "POST" && path === "/token") {
        const raw = await readBody(req);
        state.token_requests.push(raw);
        const form = new URLSearchParams(raw);
        const grantType = form.get("grant_type") ?? "";
        const clientId = form.get("client_id") ?? "";
        const resource = form.get("resource") ?? "";

        if (!state.clients.has(clientId)) {
          sendOAuthError(res, 401, "invalid_client", "unknown client_id");
          return;
        }
        if (resource.length === 0 || !sameResource(resource, resourceUrl())) {
          sendOAuthError(
            res,
            400,
            "invalid_target",
            `resource must be ${resourceUrl()}`,
          );
          return;
        }

        if (grantType === "authorization_code") {
          const code = form.get("code") ?? "";
          const verifier = form.get("code_verifier") ?? "";
          const redirectUri = form.get("redirect_uri") ?? "";
          const pending = state.codes.get(code);
          if (!pending) {
            sendOAuthError(res, 400, "invalid_grant", "unknown or used code");
            return;
          }
          state.codes.delete(code);
          if (pending.expires_at < nowSeconds()) {
            sendOAuthError(res, 400, "invalid_grant", "code expired");
            return;
          }
          if (pending.client_id !== clientId) {
            sendOAuthError(
              res,
              400,
              "invalid_grant",
              "code was issued to another client",
            );
            return;
          }
          if (pending.redirect_uri !== redirectUri) {
            sendOAuthError(res, 400, "invalid_grant", "redirect_uri mismatch");
            return;
          }
          if (
            verifier.length === 0 ||
            s256(verifier) !== pending.code_challenge
          ) {
            sendOAuthError(
              res,
              400,
              "invalid_grant",
              "code_verifier does not match the code_challenge",
            );
            return;
          }
          if (!sameResource(pending.resource, resource)) {
            sendOAuthError(res, 400, "invalid_target", "resource mismatch");
            return;
          }

          const access: AccessToken = {
            token: randomToken("at"),
            resource,
            scope: pending.scope,
            expires_at: nowSeconds() + ACCESS_TOKEN_TTL_SECONDS,
          };
          const refresh: RefreshToken = {
            token: randomToken("rt"),
            client_id: clientId,
            resource,
            scope: pending.scope,
          };
          state.access_tokens.set(access.token, access);
          state.refresh_tokens.set(refresh.token, refresh);
          sendJson(
            res,
            200,
            {
              access_token: access.token,
              token_type: "Bearer",
              expires_in: ACCESS_TOKEN_TTL_SECONDS,
              refresh_token: refresh.token,
              scope: access.scope,
            },
            { "Cache-Control": "no-store" },
          );
          return;
        }

        if (grantType === "refresh_token") {
          const presented = form.get("refresh_token") ?? "";
          const existing = state.refresh_tokens.get(presented);
          if (!existing) {
            sendOAuthError(res, 400, "invalid_grant", "unknown refresh_token");
            return;
          }
          if (existing.client_id !== clientId) {
            sendOAuthError(
              res,
              400,
              "invalid_grant",
              "refresh_token was issued to another client",
            );
            return;
          }
          if (!sameResource(existing.resource, resource)) {
            sendOAuthError(res, 400, "invalid_target", "resource mismatch");
            return;
          }
          const access: AccessToken = {
            token: randomToken("at"),
            resource,
            scope: existing.scope,
            expires_at: nowSeconds() + ACCESS_TOKEN_TTL_SECONDS,
          };
          state.access_tokens.set(access.token, access);
          sendJson(
            res,
            200,
            {
              access_token: access.token,
              token_type: "Bearer",
              expires_in: ACCESS_TOKEN_TTL_SECONDS,
              scope: access.scope,
            },
            { "Cache-Control": "no-store" },
          );
          return;
        }

        sendOAuthError(
          res,
          400,
          "unsupported_grant_type",
          `grant_type "${grantType}" is not supported`,
        );
        return;
      }

      if (path === "/mcp") {
        const header = req.headers["authorization"];
        const presented =
          typeof header === "string" && header.startsWith("Bearer ")
            ? header.slice("Bearer ".length)
            : "";
        const token =
          presented.length > 0 ? state.access_tokens.get(presented) : undefined;
        if (!token || token.expires_at < nowSeconds()) {
          const payload = JSON.stringify({
            jsonrpc: "2.0",
            id: null,
            error: { code: -32001, message: "Unauthorized" },
          });
          res.writeHead(401, {
            "Content-Type": "application/json",
            "Content-Length": Buffer.byteLength(payload).toString(),
            "WWW-Authenticate": `Bearer resource_metadata="${prmUrl()}", scope="${SCOPE}"`,
          });
          res.end(payload);
          return;
        }

        const mcp = getServer();
        const transport = new StreamableHTTPServerTransport({
          sessionIdGenerator: undefined,
        });
        await mcp.connect(transport);
        await transport.handleRequest(req, res);
        res.on("close", () => {
          transport.close();
          mcp.close();
        });
        return;
      }

      sendJson(res, 404, { error: "not_found", path });
    } catch (err) {
      console.error(
        `${SERVER_NAME}: request error: ${err instanceof Error ? err.message : String(err)}`,
      );
      if (!res.headersSent) {
        sendJson(res, 500, {
          jsonrpc: "2.0",
          id: null,
          error: { code: -32603, message: "Internal server error" },
        });
      }
    }
  });

  return { server, state, origin };
}

function parsePort(): number {
  const raw = process.argv[2] ?? process.env.PORT ?? String(DEFAULT_PORT);
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    console.error(
      `${SERVER_NAME}: invalid port: "${raw}" (expected integer 0..65535)`,
    );
    process.exit(2);
  }
  return port;
}

async function main(): Promise<void> {
  const port = parsePort();
  const app = createApp(port);

  app.server.listen(port, "127.0.0.1", () => {
    const address = app.server.address();
    const bound = typeof address === "object" && address ? address.port : port;
    console.error(
      `${SERVER_NAME} listening on http://127.0.0.1:${bound}/mcp (oauth protected)`,
    );
  });

  const shutdown = (sig: string) => {
    console.error(`${SERVER_NAME}: ${sig} received, closing server`);
    app.server.close(() => process.exit(0));
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

function isEntryPoint(): boolean {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  main().catch((err) => {
    console.error(
      `${SERVER_NAME}: fatal: ${err instanceof Error ? err.stack : String(err)}`,
    );
    process.exit(1);
  });
}
