/**
 * Print non-secret LLM config from a GCP assistant (active profile, providers).
 */
import { resolveGcpGuardianBearer } from "../src/lib/gcp.ts";
import { lookupAssistantByIdentifier } from "../src/lib/assistant-config.ts";
import { loopbackSafeFetch } from "../src/lib/loopback-fetch.ts";

const args = process.argv.slice(2);
let name: string | null = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--name" && args[i + 1]) {
    name = args[++i];
  }
}

if (!name) {
  console.error("Usage: bun run scripts/inspect-gce-llm.ts --name <instance>");
  process.exit(1);
}

const result = lookupAssistantByIdentifier(name);
if (result.status !== "found" || result.entry.cloud !== "gcp") {
  console.error(`Error: GCP assistant '${name}' not found in lockfile.`);
  process.exit(1);
}

const { entry } = result;
const gatewayUrl = entry.localUrl ?? entry.runtimeUrl;
const bearerToken = await resolveGcpGuardianBearer(entry);
if (!bearerToken) {
  console.error("No guardian token. Run lease-gce-token.ts first.");
  process.exit(1);
}

const base = gatewayUrl.replace(/\/$/, "");
const response = await loopbackSafeFetch(`${base}/v1/config`, {
  headers: {
    Authorization: `Bearer ${bearerToken}`,
    Accept: "application/json",
  },
  signal: AbortSignal.timeout(15_000),
});

if (!response.ok) {
  console.error(`Config fetch failed: ${response.status} ${response.statusText}`);
  process.exit(1);
}

const config = (await response.json()) as {
  llm?: {
    activeProfile?: string;
    default?: { provider?: string; model?: string; provider_connection?: string };
    profiles?: Record<
      string,
      { provider?: string; model?: string; provider_connection?: string; status?: string }
    >;
  };
};

const llm = config.llm ?? {};
console.log("activeProfile:", llm.activeProfile ?? "(unset)");
console.log("default:", JSON.stringify(llm.default ?? null));
const profiles = llm.profiles ?? {};
for (const [name, profile] of Object.entries(profiles)) {
  if (!profile?.provider && !profile?.status) continue;
  console.log(
    `profile ${name}:`,
    JSON.stringify({
      provider: profile.provider,
      model: profile.model,
      provider_connection: profile.provider_connection,
      status: profile.status,
    }),
  );
}
