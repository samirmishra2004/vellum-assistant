import { existsSync } from "node:fs";
import { dirname, join } from "node:path";

/**
 * Resolve the gcloud CLI executable for child_process.spawn.
 * On Windows, Bun/Node cannot execute bare `gcloud` — use gcloud.cmd or the
 * bundled python entry point instead.
 */
export function resolveGcloudCommand(): string {
  if (process.env.GCLOUD_PATH && existsSync(process.env.GCLOUD_PATH)) {
    return process.env.GCLOUD_PATH;
  }

  if (process.platform !== "win32") {
    return "gcloud";
  }

  const roots = [
    process.env.CLOUDSDK_ROOT,
    process.env.LOCALAPPDATA
      ? join(process.env.LOCALAPPDATA, "Google", "Cloud SDK", "google-cloud-sdk")
      : undefined,
    process.env.ProgramFiles
      ? join(process.env.ProgramFiles, "Google", "Cloud SDK", "google-cloud-sdk")
      : undefined,
    process.env["ProgramFiles(x86)"]
      ? join(
          process.env["ProgramFiles(x86)"],
          "Google",
          "Cloud SDK",
          "google-cloud-sdk",
        )
      : undefined,
  ].filter((root): root is string => !!root);

  for (const root of roots) {
    const cmdPath = join(root, "bin", "gcloud.cmd");
    if (existsSync(cmdPath)) {
      return cmdPath;
    }
  }

  return "gcloud.cmd";
}

function resolveGcloudSdkRoot(): string | null {
  if (process.env.CLOUDSDK_ROOT && existsSync(process.env.CLOUDSDK_ROOT)) {
    return process.env.CLOUDSDK_ROOT;
  }
  const cmdPath = resolveGcloudCommand();
  if (cmdPath === "gcloud.cmd" || cmdPath === "gcloud") {
    return null;
  }
  return dirname(dirname(cmdPath));
}

function isGcloudCommand(command: string): boolean {
  if (command === "gcloud" || command === "gcloud.cmd") {
    return true;
  }
  if (process.platform !== "win32") {
    return false;
  }
  const normalized = command.replace(/\//g, "\\").toLowerCase();
  const cmdPath = resolveGcloudCommand().replace(/\//g, "\\").toLowerCase();
  return normalized === cmdPath || normalized.endsWith("\\gcloud.cmd");
}

export function expandGcloudSpawnTarget(
  command: string,
  args: string[],
): { command: string; args: string[] } | null {
  if (!isGcloudCommand(command)) {
    return null;
  }

  if (process.platform !== "win32") {
    return { command: "gcloud", args };
  }

  const root = resolveGcloudSdkRoot();
  if (!root) {
    return null;
  }

  const python = join(root, "platform", "bundledpython", "python.exe");
  const gcloudPy = join(root, "lib", "gcloud.py");
  if (!existsSync(python) || !existsSync(gcloudPy)) {
    return null;
  }

  return {
    command: python,
    args: [gcloudPy, ...args],
  };
}
