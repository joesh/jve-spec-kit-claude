// Cluster signature for the bug-reporter pipeline — TS twin of
// src/lua/bug_reporter/signature.lua (feature 027 T040).
//
// MUST agree byte-for-byte with the Lua side on every vector in
// tests/fixtures/signature_vectors.json. test/signature_parity.test.ts
// asserts the agreement at test time so a regression is caught before
// the Worker can ship.

function normalize_title(s: string | null | undefined): string {
    if (!s) return "";
    let out = s.toLowerCase();
    // Replace [^a-z0-9] with single space (collapse runs).
    out = out.replace(/[^a-z0-9]+/g, " ");
    const tokens = out.split(/\s+/).filter((t) => t.length > 0).slice(0, 5);
    return tokens.join(" ");
}

function normalize_error(s: string | null | undefined): string {
    if (!s) return "";
    let out = s;
    // 1) Absolute paths ending in .<lowercase-ext>.
    out = out.replace(/\/[A-Za-z0-9_.\/-]+\.[a-z]+/g, "");
    // 2) 0x-prefixed hex IDs.
    out = out.replace(/0[xX][0-9a-fA-F]+/g, "");
    // 3) Standalone hex runs of length >= 16.
    out = out.replace(/[0-9a-fA-F]+/g, (m) => (m.length >= 16 ? "" : m));
    // 4) ISO-8601 timestamps (best-effort match).
    out = out.replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[.\d]*[A-Za-z]*[+-]?[\d:]*/g, "");
    // 5) Unix-second integers >= 10^9 (10+ digit runs).
    out = out.replace(/\d+/g, (m) => (m.length >= 10 ? "" : m));
    // 6) Trailing :N line numbers.
    out = out.replace(/:(\d+)/g, "");
    // 7) Lowercase, collapse whitespace, trim.
    out = out.toLowerCase().replace(/\s+/g, " ").trim();
    return out;
}

function strip_trailing_reportbug(commands: string[]): string[] {
    if (!commands || commands.length === 0) return [];
    if (commands[commands.length - 1] === "ReportBug") {
        return commands.slice(0, commands.length - 1);
    }
    return commands;
}

async function sha256Hex(input: string): Promise<string> {
    const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
    return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function compute(
    capture_type: "user_submitted" | "automatic",
    last_3_commands: string[],
    error_message: string | null,
    user_description: string | null,
): Promise<string> {
    if (capture_type !== "user_submitted" && capture_type !== "automatic") {
        throw new Error(`signature.compute: capture_type must be 'automatic' or 'user_submitted', got ${capture_type}`);
    }
    const filtered = strip_trailing_reportbug(last_3_commands);
    const sig_input_commands = filtered.join(",");
    const sig_input_text = capture_type === "automatic"
        ? normalize_error(error_message)
        : normalize_title(user_description);
    return await sha256Hex(sig_input_commands + "|" + sig_input_text);
}

// Exported for the parity test.
export const _internal = { normalize_title, normalize_error, strip_trailing_reportbug };
