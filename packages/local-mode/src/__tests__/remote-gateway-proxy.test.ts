import { describe, expect, test } from "bun:test";

import { resolveRemoteGatewayProxyTarget } from "../remote-gateway-proxy";

const allow =
  (...entries: Array<[string, string]>) =>
  () =>
    new Map<string, string>(entries);

describe("resolveRemoteGatewayProxyTarget", () => {
  test("passes non-remote pathnames through untouched", () => {
    expect(
      resolveRemoteGatewayProxyTarget("/index.html", allow(["gce", "http://x"])),
    ).toEqual({ kind: "pass" });
    expect(
      resolveRemoteGatewayProxyTarget("/__gateway/7830/v1", allow()),
    ).toEqual({ kind: "pass" });
  });

  test("forwards an allowlisted assistant to its runtime URL", () => {
    expect(
      resolveRemoteGatewayProxyTarget(
        "/__remote/gce/v1/assistants",
        allow(["gce", "http://34.55.200.115:7830"]),
      ),
    ).toEqual({
      kind: "forward",
      target: { assistantId: "gce", path: "/v1/assistants" },
      runtimeUrl: "http://34.55.200.115:7830",
    });
  });

  test("accepts the renderer's /assistant mount prefix", () => {
    expect(
      resolveRemoteGatewayProxyTarget(
        "/assistant/__remote/gce/auth/token",
        allow(["gce", "http://34.55.200.115:7830"]),
      ),
    ).toEqual({
      kind: "forward",
      target: { assistantId: "gce", path: "/auth/token" },
      runtimeUrl: "http://34.55.200.115:7830",
    });
  });

  test("rejects malformed assistant ids", () => {
    expect(
      resolveRemoteGatewayProxyTarget("/__remote/../etc/v1", allow()),
    ).toEqual({ kind: "invalid-id" });
  });

  test("forbids assistants that are not registered in the lockfile", () => {
    expect(
      resolveRemoteGatewayProxyTarget("/__remote/gce/v1", allow()),
    ).toEqual({ kind: "forbidden-id", assistantId: "gce" });
  });
});
