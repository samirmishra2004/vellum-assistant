/**
 * Register the active GCP assistant with the platform and inject credentials
 * into the running instance. Requires `vellum login` first (platform token).
 */
import {
  lookupAssistantByIdentifier,
  resolveAssistant,
} from "../src/lib/assistant-config.js";
import { computeDeviceId } from "../src/lib/guardian-token.js";
import { leaseGcpGuardianTokenViaLocalTunnel } from "../src/lib/gcp.js";
import {
  ensureSelfHostedLocalRegistration,
  fetchCurrentUser,
  fetchOrganizationId,
  getPlatformUrl,
  injectCredentialsIntoAssistant,
  readGatewayCredential,
  readPlatformToken,
  reprovisionAssistantApiKey,
} from "../src/lib/platform-client.js";
import {
  fetchAssistantIngressUrl,
  fetchCurrentVersion,
} from "../src/lib/upgrade-lifecycle.js";

const args = process.argv.slice(2);
let name: string | null = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--name" && args[i + 1]) {
    name = args[++i];
  }
}

const token = readPlatformToken();
if (!token) {
  console.error(
    "Not logged in to the platform. Run `vellum login` first, then re-run this script.",
  );
  process.exit(1);
}

let entry;
if (name) {
  const lookup = lookupAssistantByIdentifier(name);
  if (lookup.status !== "found") {
    console.error(
      lookup.status === "ambiguous"
        ? `Ambiguous assistant name "${name}".`
        : `Assistant "${name}" not found.`,
    );
    process.exit(1);
  }
  entry = lookup.entry;
} else {
  entry = resolveAssistant();
  if (!entry) {
    console.error("No active assistant. Pass --name <assistant-id>.");
    process.exit(1);
  }
}

if (entry.cloud === "gcp") {
  try {
    await leaseGcpGuardianTokenViaLocalTunnel(
      entry.assistantId,
      entry.project!,
      entry.zone!,
      process.env.GCP_ACCOUNT_EMAIL,
    );
  } catch (err) {
    console.warn(
      `Warning: could not lease guardian token: ${err instanceof Error ? err.message : err}`,
    );
  }
}

const orgId = await fetchOrganizationId(token);
const user = await fetchCurrentUser(token);
const clientInstallationId = computeDeviceId();
const [assistantVersion, ingressUrl] = await Promise.all([
  fetchCurrentVersion(entry.runtimeUrl),
  fetchAssistantIngressUrl(entry.runtimeUrl, entry.bearerToken),
]);

console.log(`Registering ${entry.assistantId} with platform...`);
const registration = await ensureSelfHostedLocalRegistration(
  token,
  orgId,
  clientInstallationId,
  entry.assistantId,
  "cli",
  assistantVersion,
  getPlatformUrl(),
  ingressUrl,
);

console.log(
  `Registered: ${registration.assistant.name} (${registration.assistant.id})`,
);

let assistantApiKey = registration.assistant_api_key;
if (!assistantApiKey) {
  const cached = await readGatewayCredential(
    entry.runtimeUrl,
    "vellum:assistant_api_key",
    entry.bearerToken,
  );
  if (cached.value) {
    assistantApiKey = cached.value;
  } else if (!cached.unreachable) {
    console.log("No API key locally — reprovisioning...");
    const reprovision = await reprovisionAssistantApiKey(
      token,
      orgId,
      clientInstallationId,
      entry.assistantId,
      "cli",
    );
    assistantApiKey = reprovision.provisioning.assistant_api_key;
  }
}

const injected = await injectCredentialsIntoAssistant({
  gatewayUrl: entry.runtimeUrl,
  bearerToken: entry.bearerToken,
  assistantApiKey,
  platformAssistantId: registration.assistant.id,
  platformBaseUrl: getPlatformUrl(),
  organizationId: orgId,
  userId: user.id,
  webhookSecret: registration.webhook_secret,
});

if (injected) {
  console.log("Injected platform credentials into assistant.");
} else {
  console.warn("Some credentials could not be injected.");
  process.exit(1);
}

console.log(
  "Done. Verify with: vellum exec",
  entry.assistantId,
  "-- assistant platform status",
);
