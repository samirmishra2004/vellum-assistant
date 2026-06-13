/**
 * Finish bootstrap on an existing GCE instance when the initial deploy failed
 * after VM creation (e.g. firewall sync or install.sh curl).
 */
import { userInfo } from "os";

import { recoverFromCurlFailure, leaseGcpGuardianTokenViaLocalTunnel } from "../src/lib/gcp.ts";
import { configureAssistantGemini } from "../src/lib/gcp-gemini-config.ts";
import { saveAssistantEntry, setActiveAssistant } from "../src/lib/assistant-config.ts";
import { GATEWAY_PORT } from "../src/lib/constants.ts";
import { execOutput } from "../src/lib/step-runner.ts";
import { resolveGcloudCommand } from "../src/lib/gcloud-command.ts";

const args = process.argv.slice(2);
let name: string | null = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--name" && args[i + 1]) {
    name = args[++i];
  }
}

if (!name) {
  console.error("Usage: bun run scripts/finish-gce-bootstrap.ts --name <instance>");
  process.exit(1);
}

const project = process.env.GCP_PROJECT ?? "sam-world";
const zone = process.env.GCP_DEFAULT_ZONE ?? "us-central1-a";
const account = process.env.GCP_ACCOUNT_EMAIL;
const gcloud = resolveGcloudCommand();

let sshUser: string;
try {
  sshUser = userInfo().username;
} catch {
  sshUser = process.env.USER ?? process.env.USERNAME ?? "";
}
if (!sshUser) {
  console.error("Error: Could not determine SSH username.");
  process.exit(1);
}

console.log(`Recovering install on ${name} (${project}/${zone})...`);
await recoverFromCurlFailure(name, project, zone, sshUser, account);

const describeArgs = [
  "compute",
  "instances",
  "describe",
  name,
  `--project=${project}`,
  `--zone=${zone}`,
  "--format=get(networkInterfaces[0].accessConfigs[0].natIP)",
];
if (account) describeArgs.push(`--account=${account}`);
const ip = (await execOutput(gcloud, describeArgs)).trim();
const runtimeUrl = ip ? `http://${ip}:${GATEWAY_PORT}` : `http://${name}:${GATEWAY_PORT}`;

saveAssistantEntry({
  assistantId: name,
  runtimeUrl,
  cloud: "gcp",
  project,
  zone,
  species: "vellum",
  sshUser,
  hatchedAt: new Date().toISOString(),
});
setActiveAssistant(name);

const entry = {
  assistantId: name,
  runtimeUrl,
  cloud: "gcp" as const,
  project,
  zone,
  sshUser,
  hatchedAt: new Date().toISOString(),
};

try {
  await leaseGcpGuardianTokenViaLocalTunnel(
    name,
    project,
    zone,
    account,
  );
} catch (err) {
  console.warn(
    `Warning: could not lease guardian token: ${err instanceof Error ? err.message : err}`,
  );
  console.warn("Run: bun run scripts/lease-gce-token.ts --name", name);
}

if (process.env.GEMINI_API_KEY?.trim()) {
  try {
    console.log("Configuring Gemini from GEMINI_API_KEY...");
    await configureAssistantGemini(entry);
  } catch (err) {
    console.warn(
      `Warning: Gemini setup failed: ${err instanceof Error ? err.message : err}`,
    );
    console.warn(
      "Run: GEMINI_API_KEY=... bun run scripts/configure-gce-gemini.ts --name",
      name,
    );
  }
}

console.log(`Done. Assistant URL: ${runtimeUrl}`);
