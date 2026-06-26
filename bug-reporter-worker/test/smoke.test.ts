import { describe, expect, it } from "vitest";
import { SELF } from "cloudflare:test";

// T017 smoke — verifies the Miniflare-backed vitest pool boots and the
// Worker stub responds. Real contract tests land in T020-T023.
describe("worker scaffold", () => {
    it("unknown path returns 501 with JSON body", async () => {
        const res = await SELF.fetch("https://example.com/whatever");
        expect(res.status).toBe(501);
        const body = await res.json();
        expect(body).toMatchObject({ error: "not_implemented" });
    });
});
