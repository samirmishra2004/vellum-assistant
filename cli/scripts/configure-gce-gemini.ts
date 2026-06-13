/**
 * Configure a GCP assistant to use Gemini: API key, provider connection, and
 * active profile.
 *
 * Requires GEMINI_API_KEY in the environment unless the key is already stored.
 */
import { configureAssistantGemini } from "../src/lib/gcp-gemini-config.ts";
import {
  lookupAssistantByIdentifier,
  setActiveAssistant,
} from "../src/lib/assistant-config.ts";

const args = process.argv.slice(2);
let name: string | null = null;
let skipKeySetup = false;

for (let i = 0; i < args.length; i++) {
  if (args[i] === "--name" && args[i + 1]) {
    name = args[++i];
  } else if (args[i] === "--skip-key") {
    skipKeySetup = true;
  }
}

if (!name) {
  console.error(
    "Usage: bun run scripts/configure-gce-gemini.ts --name <instance> [--skip-key]",
  );
  process.exit(1);
}

const result = lookupAssistantByIdentifier(name);
if (result.status !== "found" || result.entry.cloud !== "gcp") {
  console.error(`Error: GCP assistant '${name}' not found in lockfile.`);
  process.exit(1);
}

if (!skipKeySetup && !process.env.GEMINI_API_KEY?.trim()) {
  console.error(
    "Error: Set GEMINI_API_KEY in the environment, or pass --skip-key if the key is already stored.",
  );
  process.exit(1);
}

const { entry } = result;
setActiveAssistant(entry.assistantId);

console.log(`Configuring Gemini on ${entry.assistantId} (${entry.runtimeUrl})...`);
await configureAssistantGemini(entry, { skipKeySetup });
console.log("Done. Restart the web client or send a new chat message to use Gemini.");
