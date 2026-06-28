import { describe, expect, it } from "vitest";
import { SELF } from "cloudflare:test";

// T017 smoke — verifies the Miniflare-backed vitest pool boots and the
// Worker stub responds. Real contract tests land in T020-T023.
describe("worker scaffold", () => {
    it("unknown path returns 404 with JSON body", async () => {
        // Method must be POST (T045+ rejects non-POST with 405); GET on
        // an unknown path therefore short-circuits at the method check.
        // For a 404 we send POST to an unknown path.
        const res = await SELF.fetch("https://example.com/whatever", { method: "POST" });
        expect(res.status).toBe(404);
        const body = await res.json();
        expect(body).toMatchObject({ error: "not_found" });
    });
});
