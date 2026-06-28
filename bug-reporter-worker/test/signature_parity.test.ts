// Feature 027 T040: cross-language parity for the cluster signature.
//
// Loads tests/fixtures/signature_vectors.json (the same fixture
// signature.lua's T002 test consumes) and asserts the Worker-side
// signature.ts hashes every vector identically. A divergence here =
// production silently creates twin clusters across Lua and TS sides;
// caught at test time so it never ships.

import { describe, expect, it } from "vitest";
import { compute } from "../src/signature";
import fixtures from "../../tests/fixtures/signature_vectors.json";

interface Vector {
    name: string;
    capture_type: "user_submitted" | "automatic";
    last_commands: string[];
    error_message: string | null;
    user_description: string | null;
    expected_sig: string;
}

describe("signature parity (TS ↔ Lua)", () => {
    for (const v of fixtures.vectors as Vector[]) {
        it(`vector ${v.name} → ${v.expected_sig.slice(0, 8)}`, async () => {
            const got = await compute(v.capture_type, v.last_commands, v.error_message, v.user_description);
            expect(got).toBe(v.expected_sig);
        });
    }
});
