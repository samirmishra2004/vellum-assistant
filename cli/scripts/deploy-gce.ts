/**
 * Deploy a Vellum assistant to Google Compute Engine.
 *
 * Uses the same hatchGcp path as `vellum hatch --remote gcp` (currently
 * gated in hatch.ts). Requires gcloud CLI, billing, and a provider API key
 * in the environment (e.g. GEMINI_API_KEY, ANTHROPIC_API_KEY).
 *
 * Usage:
 *   GCP_DEFAULT_ZONE=us-central1-a bun run scripts/deploy-gce.ts [--name my-instance]
 */
import {
  buildStartupScript,
  watchHatching,
} from "../src/commands/hatch.ts";
import { hatchGcp } from "../src/lib/gcp.ts";
import { PROVIDER_ENV_VAR_NAMES } from "../src/shared/provider-env-vars.js";

const args = process.argv.slice(2);
let name: string | null = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--name" && args[i + 1]) {
    name = args[++i];
  }
}

const hasProviderKey = Object.values(PROVIDER_ENV_VAR_NAMES).some(
  (envVar) => process.env[envVar]?.trim(),
);
if (!hasProviderKey) {
  console.error(
    "Error: Set at least one provider API key in the environment, e.g.:\n" +
      "  GEMINI_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY",
  );
  process.exit(1);
}

if (!process.env.GCP_DEFAULT_ZONE?.trim()) {
  console.error("Error: Set GCP_DEFAULT_ZONE (e.g. us-central1-a).");
  process.exit(1);
}

await hatchGcp(
  "vellum",
  false,
  name,
  buildStartupScript,
  watchHatching,
);
