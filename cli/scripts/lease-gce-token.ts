/**
 * Lease a guardian JWT for a GCP assistant via SSH tunnel.
 *
 * Required when the gateway has no bootstrap secret (loopback-only init)
 * or when finish-gce-bootstrap ran without token leasing.
 */
import { leaseGcpGuardianTokenViaLocalTunnel } from "../src/lib/gcp.ts";
import { lookupAssistantByIdentifier } from "../src/lib/assistant-config.ts";

const args = process.argv.slice(2);
let name: string | null = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--name" && args[i + 1]) {
    name = args[++i];
  }
}

if (!name) {
  console.error("Usage: bun run scripts/lease-gce-token.ts --name <instance>");
  process.exit(1);
}

const result = lookupAssistantByIdentifier(name);
if (result.status !== "found" || result.entry.cloud !== "gcp") {
  console.error(`Error: GCP assistant '${name}' not found in lockfile.`);
  process.exit(1);
}

const { entry } = result;
const project = entry.project ?? process.env.GCP_PROJECT;
const zone = entry.zone ?? process.env.GCP_DEFAULT_ZONE;
if (!project || !zone) {
  console.error("Error: Set GCP_PROJECT and GCP_DEFAULT_ZONE, or hatch first.");
  process.exit(1);
}

await leaseGcpGuardianTokenViaLocalTunnel(
  entry.assistantId,
  project,
  zone,
  process.env.GCP_ACCOUNT_EMAIL,
  typeof entry.guardianBootstrapSecret === "string"
    ? entry.guardianBootstrapSecret
    : undefined,
);
