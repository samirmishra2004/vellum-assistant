import { afterEach, describe, expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import {
  parseGatewayTokenMintPath,
  readGcpAssistantMeta,
} from "../remote-gateway-token";

describe("parseGatewayTokenMintPath", () => {
  test("matches the dev-server mount prefix", () => {
    expect(
      parseGatewayTokenMintPath("/assistant/__local/gateway-token/vellum-gce"),
    ).toEqual({
      match: true,
      valid: true,
      assistantId: "vellum-gce",
    });
  });

  test("rejects malformed assistant ids", () => {
    expect(
      parseGatewayTokenMintPath("/assistant/__local/gateway-token/bad!id"),
    ).toEqual({ match: true, valid: false });
  });

  test("passes unrelated paths through", () => {
    expect(parseGatewayTokenMintPath("/assistant/__remote/gce/auth/token")).toEqual(
      { match: false },
    );
  });
});

describe("readGcpAssistantMeta", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "vellum-lockfile-"));
  const lockfilePath = path.join(tmpDir, "lock.json");

  afterEach(() => {
    try {
      fs.unlinkSync(lockfilePath);
    } catch {
      // ignore
    }
  });

  test("reads project, zone, and gateway port from a GCP entry", () => {
    fs.writeFileSync(
      lockfilePath,
      JSON.stringify({
        assistants: [
          {
            assistantId: "vellum-gce",
            cloud: "gcp",
            project: "sam-world",
            zone: "us-central1-a",
            runtimeUrl: "http://34.55.200.115:7830",
          },
        ],
      }),
    );

    expect(readGcpAssistantMeta("vellum-gce", [lockfilePath])).toEqual({
      assistantId: "vellum-gce",
      project: "sam-world",
      zone: "us-central1-a",
      gatewayPort: 7830,
    });
  });

  test("returns null for non-GCP assistants", () => {
    fs.writeFileSync(
      lockfilePath,
      JSON.stringify({
        assistants: [
          {
            assistantId: "paired-a",
            cloud: "paired",
            runtimeUrl: "http://10.0.0.1:7830",
          },
        ],
      }),
    );

    expect(readGcpAssistantMeta("paired-a", [lockfilePath])).toBeNull();
  });
});
