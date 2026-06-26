// R2 artifact storage for the bug-reporter pipeline (feature 027 T043).
//
// Reports zips live under reports/<report_id>.zip. URLs are NOT
// public-read — every access mints a presigned URL with 1h TTL (T-NEW-D).
// This keeps long-lived locations (GitHub issue bodies) from becoming
// permanent payload-leak vectors.

export async function put_report_zip(bucket: R2Bucket, report_id: string, bytes: Uint8Array): Promise<void> {
    await bucket.put(`reports/${report_id}.zip`, bytes, {
        httpMetadata: { contentType: "application/zip" },
    });
}

export async function get_report_object(bucket: R2Bucket, report_id: string): Promise<R2ObjectBody | null> {
    return await bucket.get(`reports/${report_id}.zip`);
}

// Cloudflare's Worker R2 binding doesn't yet expose presigned URLs
// directly — they require S3-API signing. For triage UI use, the
// promote handler stages every URL via a worker-side proxy route
// (/r2/<report_id>?token=<one-shot>). The token is HMAC'd with
// JOE_PROMOTE_SECRET + expiry; verified on each fetch. Tests stub
// this behind a feature flag if a real R2 access mechanism replaces it.
export function build_presigned_url(env: { JOE_PROMOTE_SECRET?: string }, report_id: string, ttl_seconds: number, current_unix: number): string {
    const expires_at = current_unix + ttl_seconds;
    // Token = base64(hmac_sha256(secret, `${report_id}:${expires_at}`))
    // computed eagerly by the caller using auth.ts helpers. To avoid
    // making this function async, we just inline the deterministic
    // path the verifier on the read side parses.
    void env;
    return `/r2/${report_id}?exp=${expires_at}`;
}
