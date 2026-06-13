import type { AssistantEntry } from "./assistant-config.js";
import { resolveGcpGuardianBearer } from "./gcp.js";
import { loopbackSafeFetch } from "./loopback-fetch.js";
import {
  ensureProviderApiKey,
  formatProviderName,
  readGatewayApiKey,
} from "./provider-secrets.js";

const CONNECTION_NAME = "gemini-personal";
const GEMINI_CREDENTIAL = "credential/gemini/api_key";

const GEMINI_PROFILES = {
  "custom-balanced": {
    provider: "gemini",
    model: "gemini-3-flash-preview",
    provider_connection: CONNECTION_NAME,
    source: "user",
    label: "Balanced",
    description: "Good balance of quality, cost, and speed",
    maxTokens: 16000,
    effort: "high",
    thinking: { enabled: true, streamThinking: true },
  },
  "custom-quality-optimized": {
    provider: "gemini",
    model: "gemini-3.1-pro-preview",
    provider_connection: CONNECTION_NAME,
    source: "user",
    label: "Quality",
    description: "Best results with the most capable model",
    maxTokens: 32000,
    effort: "high",
    thinking: { enabled: true, streamThinking: true },
  },
  "custom-cost-optimized": {
    provider: "gemini",
    model: "gemini-3.1-flash-lite",
    provider_connection: CONNECTION_NAME,
    source: "user",
    label: "Speed",
    description: "Fastest responses at lower cost",
    maxTokens: 8192,
    effort: "low",
    thinking: { enabled: false, streamThinking: false },
  },
} as const;

function gatewayV1Url(gatewayUrl: string, path: string): string {
  const base = gatewayUrl.replace(/\/$/, "");
  const suffix = path.startsWith("/") ? path.slice(1) : path;
  return `${base}/v1/${suffix}`;
}

function bearerHeaders(bearerToken: string): Record<string, string> {
  return {
    Authorization: `Bearer ${bearerToken}`,
    "Content-Type": "application/json",
    Accept: "application/json",
  };
}

async function parseErrorMessage(response: Response): Promise<string> {
  const body = (await response.json().catch(() => ({}))) as {
    detail?: string;
    error?: string | { message?: string };
    message?: string;
  };
  if (typeof body.detail === "string" && body.detail.trim()) {
    return body.detail;
  }
  if (typeof body.message === "string" && body.message.trim()) {
    return body.message;
  }
  if (typeof body.error === "string" && body.error.trim()) {
    return body.error;
  }
  if (
    body.error &&
    typeof body.error === "object" &&
    typeof body.error.message === "string" &&
    body.error.message.trim()
  ) {
    return body.error.message;
  }
  return `${response.status} ${response.statusText}`.trim();
}

async function ensureGeminiConnection(
  gatewayUrl: string,
  bearerToken: string,
): Promise<void> {
  const listUrl = gatewayV1Url(
    gatewayUrl,
    `inference/provider-connections/${CONNECTION_NAME}`,
  );
  const existing = await loopbackSafeFetch(listUrl, {
    headers: bearerHeaders(bearerToken),
    signal: AbortSignal.timeout(15_000),
  });
  if (existing.ok) {
    return;
  }
  if (existing.status !== 404) {
    throw new Error(
      `Failed to inspect Gemini connection: ${await parseErrorMessage(existing)}`,
    );
  }

  const createUrl = gatewayV1Url(gatewayUrl, "inference/provider-connections");
  const created = await loopbackSafeFetch(createUrl, {
    method: "POST",
    headers: bearerHeaders(bearerToken),
    body: JSON.stringify({
      name: CONNECTION_NAME,
      provider: "gemini",
      label: "Personal Gemini",
      auth: { type: "api_key", credential: GEMINI_CREDENTIAL },
    }),
    signal: AbortSignal.timeout(15_000),
  });
  if (created.ok) {
    return;
  }
  if (created.status === 409) {
    return;
  }
  throw new Error(
    `Failed to create Gemini connection: ${await parseErrorMessage(created)}`,
  );
}

async function patchGeminiProfiles(
  gatewayUrl: string,
  bearerToken: string,
): Promise<void> {
  const patchUrl = gatewayV1Url(gatewayUrl, "config");
  const response = await loopbackSafeFetch(patchUrl, {
    method: "PATCH",
    headers: bearerHeaders(bearerToken),
    body: JSON.stringify({
      llm: {
        activeProfile: "custom-balanced",
        default: {
          provider: "gemini",
          model: "gemini-3-flash-preview",
          provider_connection: CONNECTION_NAME,
        },
        profiles: {
          ...GEMINI_PROFILES,
          balanced: { status: "disabled" },
          "quality-optimized": { status: "disabled" },
          "cost-optimized": { status: "disabled" },
        },
        profileOrder: [
          "auto",
          "quality-optimized",
          "balanced",
          "cost-optimized",
          "custom-balanced",
          "custom-quality-optimized",
          "custom-cost-optimized",
        ],
      },
    }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) {
    throw new Error(
      `Failed to switch assistant to Gemini: ${await parseErrorMessage(response)}`,
    );
  }
}

export interface ConfigureGeminiOptions {
  env?: NodeJS.ProcessEnv;
  skipKeySetup?: boolean;
}

/**
 * Store a Gemini API key (when needed), create the personal connection, and
 * switch the active profile to Gemini on a remote assistant.
 */
export async function configureAssistantGemini(
  entry: Pick<AssistantEntry, "assistantId" | "runtimeUrl" | "localUrl"> &
    Parameters<typeof resolveGcpGuardianBearer>[0],
  options: ConfigureGeminiOptions = {},
): Promise<void> {
  const gatewayUrl = entry.localUrl ?? entry.runtimeUrl;
  const bearerToken = await resolveGcpGuardianBearer(entry);
  if (!bearerToken) {
    throw new Error(
      "Could not obtain a guardian token. Run `bun run scripts/lease-gce-token.ts --name <instance>` first.",
    );
  }

  if (!options.skipKeySetup) {
    const existing = await readGatewayApiKey(gatewayUrl, "gemini", bearerToken);
    if (!existing.found) {
      const keyResult = await ensureProviderApiKey({
        gatewayUrl,
        provider: "gemini",
        bearerToken,
        env: options.env ?? process.env,
      });
      if (keyResult.status === "missing" || keyResult.status === "failed") {
        throw new Error(keyResult.message);
      }
      if (keyResult.status === "skipped") {
        throw new Error(keyResult.message);
      }
      if (keyResult.status === "configured") {
        console.log(
          `${formatProviderName("gemini")} API key saved to assistant.`,
        );
      }
    } else {
      console.log(`${formatProviderName("gemini")} API key is already configured.`);
    }
  }

  await ensureGeminiConnection(gatewayUrl, bearerToken);
  await patchGeminiProfiles(gatewayUrl, bearerToken);
  console.log("Switched active model profile to Gemini (custom-balanced).");
}
