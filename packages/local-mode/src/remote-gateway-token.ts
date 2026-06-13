import { spawn, type ChildProcess } from "node:child_process";
import fs from "node:fs";

import { expandGcloudSpawnTarget, resolveGcloudCommand } from "./gcloud-command.js";

const ASSISTANT_ID_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/;
const GATEWAY_TOKEN_TUNNEL_PORT = 17831;
const DEFAULT_GATEWAY_PORT = 7830;
const TUNNEL_READY_TIMEOUT_MS = 45_000;
const WEB_ORIGIN_RE = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

const GATEWAY_TOKEN_PATTERN =
  /^(?:\/assistant)?\/__local\/gateway-token\/([^/]+)$/;

export interface GcpAssistantMeta {
  assistantId: string;
  project: string;
  zone: string;
  gatewayPort: number;
}

export type GatewayTokenMintPathResult =
  | { match: false }
  | { match: true; valid: false }
  | { match: true; valid: true; assistantId: string };

export function parseGatewayTokenMintPath(
  pathname: string,
): GatewayTokenMintPathResult {
  const match = pathname.match(GATEWAY_TOKEN_PATTERN);
  if (!match) return { match: false };

  const assistantId = decodeURIComponent(match[1]!);
  if (!ASSISTANT_ID_PATTERN.test(assistantId)) {
    return { match: true, valid: false };
  }

  return { match: true, valid: true, assistantId };
}

export function readGcpAssistantMeta(
  assistantId: string,
  lockfilePaths: string[],
  env: Record<string, string | undefined> = process.env,
): GcpAssistantMeta | null {
  for (const candidate of lockfilePaths) {
    try {
      const raw = fs.readFileSync(candidate, "utf-8");
      const data = JSON.parse(raw) as {
        assistants?: Array<Record<string, unknown>>;
      };
      const assistants = Array.isArray(data.assistants) ? data.assistants : [];
      for (const entry of assistants) {
        if (entry.assistantId !== assistantId) continue;
        if (entry.cloud !== "gcp") return null;

        const project =
          typeof entry.project === "string" ? entry.project : env.GCP_PROJECT;
        const zone =
          typeof entry.zone === "string" ? entry.zone : env.GCP_DEFAULT_ZONE;
        if (!project || !zone) return null;

        let gatewayPort = DEFAULT_GATEWAY_PORT;
        if (typeof entry.runtimeUrl === "string") {
          try {
            const parsed = new URL(entry.runtimeUrl);
            if (parsed.port) gatewayPort = Number(parsed.port);
          } catch {
            // keep default
          }
        }

        return { assistantId, project, zone, gatewayPort };
      }
    } catch (err: unknown) {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") return null;
    }
  }
  return null;
}

async function waitForTunnelReady(localPort: number): Promise<void> {
  const deadline = Date.now() + TUNNEL_READY_TIMEOUT_MS;
  const healthUrl = `http://127.0.0.1:${localPort}/healthz`;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(healthUrl, { method: "GET" });
      if (response.ok) return;
    } catch {
      // Tunnel not ready yet.
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error(
    `SSH tunnel to 127.0.0.1:${localPort} did not become ready within ${TUNNEL_READY_TIMEOUT_MS / 1000}s`,
  );
}

function spawnGcpTunnel(
  instanceName: string,
  project: string,
  zone: string,
  localPort: number,
  remoteGatewayPort: number,
  account?: string,
): ChildProcess {
  const tunnelArgs = [
    "compute",
    "ssh",
    instanceName,
    `--project=${project}`,
    `--zone=${zone}`,
    "--quiet",
    "--",
    "-N",
    "-L",
    `${localPort}:127.0.0.1:${remoteGatewayPort}`,
  ];
  if (account) tunnelArgs.splice(4, 0, `--account=${account}`);

  const gcloud = resolveGcloudCommand();
  const expanded = expandGcloudSpawnTarget(gcloud, tunnelArgs);
  if (expanded) {
    return spawn(expanded.command, expanded.args, { stdio: "ignore" });
  }
  return spawn(gcloud, tunnelArgs, { stdio: "ignore" });
}

export type MintGatewayTokenResult =
  | { ok: true; token: string; expiresAt: number }
  | { ok: false; status: number; error: string };

/**
 * Mint a gateway session JWT for a GCP assistant. The remote gateway only
 * accepts POST /auth/token from loopback, so we open a short-lived SSH tunnel
 * and call the endpoint from the laptop.
 */
export async function mintGcpGatewayTokenViaTunnel(
  meta: GcpAssistantMeta,
  guardianBearer: string,
  webOrigin: string,
  env: Record<string, string | undefined> = process.env,
): Promise<MintGatewayTokenResult> {
  if (!WEB_ORIGIN_RE.test(webOrigin)) {
    return { ok: false, status: 400, error: "Invalid web origin" };
  }

  let tunnel: ChildProcess | undefined;
  try {
    tunnel = spawnGcpTunnel(
      meta.assistantId,
      meta.project,
      meta.zone,
      GATEWAY_TOKEN_TUNNEL_PORT,
      meta.gatewayPort,
      env.GCP_ACCOUNT_EMAIL,
    );
  } catch (err) {
    return {
      ok: false,
      status: 502,
      error:
        err instanceof Error
          ? `Failed to start gcloud SSH tunnel: ${err.message}`
          : String(err),
    };
  }

  try {
    await waitForTunnelReady(GATEWAY_TOKEN_TUNNEL_PORT);
    const response = await fetch(
      `http://127.0.0.1:${GATEWAY_TOKEN_TUNNEL_PORT}/auth/token`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${guardianBearer}`,
          Origin: webOrigin,
        },
      },
    );
    if (!response.ok) {
      return {
        ok: false,
        status: response.status,
        error: `Gateway token mint failed: ${response.status}`,
      };
    }
    const body = (await response.json()) as {
      token?: string;
      expiresAt?: number;
    };
    if (!body.token || body.expiresAt == null) {
      return {
        ok: false,
        status: 502,
        error: "Malformed gateway token response",
      };
    }
    return { ok: true, token: body.token, expiresAt: body.expiresAt };
  } catch (err) {
    return {
      ok: false,
      status: 502,
      error: err instanceof Error ? err.message : String(err),
    };
  } finally {
    tunnel?.kill();
  }
}
