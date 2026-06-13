/**
 * Sync GCP firewall rules for vellum-assistant instances.
 * Use after a partial deploy that created the VM but failed on firewall sync.
 */
import { syncFirewallRules } from "../src/lib/gcp.ts";
import { FIREWALL_TAG, GATEWAY_PORT } from "../src/lib/constants.ts";

const project = process.env.GCP_PROJECT ?? "sam-world";
const account = process.env.GCP_ACCOUNT_EMAIL;

const DESIRED_FIREWALL_RULES = [
  {
    name: "allow-vellum-assistant-gateway",
    direction: "INGRESS" as const,
    action: "ALLOW" as const,
    rules: `tcp:${GATEWAY_PORT}`,
    sourceRanges: "0.0.0.0/0",
    targetTags: FIREWALL_TAG,
    description: `Allow gateway ingress on port ${GATEWAY_PORT} for vellum-assistant instances`,
  },
  {
    name: "allow-vellum-assistant-egress",
    direction: "EGRESS" as const,
    action: "ALLOW" as const,
    rules: "all",
    destinationRanges: "0.0.0.0/0",
    targetTags: FIREWALL_TAG,
    description: "Allow all egress traffic for vellum-assistant instances",
  },
];

console.log(`Syncing firewall rules for project ${project}...`);
await syncFirewallRules(DESIRED_FIREWALL_RULES, project, FIREWALL_TAG, account);
console.log("Done.");
