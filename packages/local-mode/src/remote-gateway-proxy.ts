import fs from "node:fs";

const REMOTE_GATEWAY_PATTERN =
  /^(?:\/assistant)?\/__remote\/([^/]+)(\/.*)?$/;

const ASSISTANT_ID_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/;

export interface RemoteGatewayTarget {
  assistantId: string;
  path: string;
}

export type RemoteGatewayParseResult =
  | { match: true; valid: true; target: RemoteGatewayTarget }
  | { match: true; valid: false }
  | { match: false };

export type RemoteGatewayProxyDecision =
  | { kind: "pass" }
  | { kind: "invalid-id" }
  | { kind: "forbidden-id"; assistantId: string }
  | { kind: "forward"; target: RemoteGatewayTarget; runtimeUrl: string };

export function parseRemoteGatewayUrl(pathname: string): RemoteGatewayParseResult {
  const match = pathname.match(REMOTE_GATEWAY_PATTERN);
  if (!match) return { match: false };

  const assistantId = decodeURIComponent(match[1]!);
  if (!ASSISTANT_ID_PATTERN.test(assistantId)) {
    return { match: true, valid: false };
  }

  return {
    match: true,
    valid: true,
    target: { assistantId, path: match[2] || "/" },
  };
}

function isRemoteRuntimeUrl(value: unknown): value is string {
  if (typeof value !== "string") return false;
  try {
    const parsed = new URL(value);
    return parsed.protocol === "http:" || parsed.protocol === "https:";
  } catch {
    return false;
  }
}

function usesLocalPortProxy(resources: { gatewayPort?: unknown } | undefined): boolean {
  const gp = resources?.gatewayPort;
  return (
    typeof gp === "number" &&
    Number.isInteger(gp) &&
    gp >= 1024 &&
    gp <= 65535
  );
}

/**
 * Lockfile assistants that reach a remote gateway through the dev-server
 * proxy. Local/docker entries with `resources.gatewayPort` use the loopback
 * `__gateway/{port}` path instead.
 */
export function readRemoteRuntimeUrls(lockfilePaths: string[]): Map<string, string> {
  const urls = new Map<string, string>();
  for (const candidate of lockfilePaths) {
    try {
      const raw = fs.readFileSync(candidate, "utf-8");
      const data = JSON.parse(raw) as {
        assistants?: Array<{
          assistantId?: unknown;
          runtimeUrl?: unknown;
          resources?: { gatewayPort?: unknown };
        }>;
      };
      const assistants = Array.isArray(data.assistants) ? data.assistants : [];
      for (const assistant of assistants) {
        if (typeof assistant?.assistantId !== "string") continue;
        if (!isRemoteRuntimeUrl(assistant.runtimeUrl)) continue;
        if (usesLocalPortProxy(assistant.resources)) continue;
        urls.set(assistant.assistantId, assistant.runtimeUrl);
      }
      if (urls.size > 0) return urls;
    } catch (err: unknown) {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") return new Map();
    }
  }
  return urls;
}

export function resolveRemoteGatewayProxyTarget(
  pathname: string,
  getRuntimeUrls: () => Map<string, string>,
): RemoteGatewayProxyDecision {
  const parsed = parseRemoteGatewayUrl(pathname);
  if (!parsed.match) return { kind: "pass" };
  if (!parsed.valid) return { kind: "invalid-id" };

  const runtimeUrl = getRuntimeUrls().get(parsed.target.assistantId);
  if (!runtimeUrl) {
    return { kind: "forbidden-id", assistantId: parsed.target.assistantId };
  }
  return { kind: "forward", target: parsed.target, runtimeUrl };
}
