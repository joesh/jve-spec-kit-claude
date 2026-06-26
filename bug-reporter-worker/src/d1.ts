// Typed D1 access for the bug-reporter Worker (feature 027 T041).
//
// One namespace per table. Every query parameterized; no user data
// concatenated into SQL strings. Errors surface as thrown exceptions
// — the calling handler decides whether to map to 4xx or 5xx.

export interface InstallRow {
    install_id: string;
    nonce: string;
    first_seen: number;
    last_launched: number;
    jve_sha: string;
    platform: string;
    os_version: string | null;
    arch: string;
    country: string | null;
    timezone: string | null;
    cpu_model: string | null;
    cpu_cores_physical: number | null;
    cpu_cores_logical: number | null;
    cpu_perf_cores: number | null;
    cpu_eff_cores: number | null;
    system_memory_mb: number | null;
    gpu_vendor: string | null;
    gpu_model: string | null;
    gpu_memory_mb: number | null;
    gpu_api: string | null;
    unified_memory: number;
    reports_count: number;
    status: "active" | "suspended";
}

export const installs = {
    async insert(db: D1Database, r: InstallRow): Promise<void> {
        await db.prepare(`
            INSERT INTO installs (install_id, nonce, first_seen, last_launched, jve_sha,
                                  platform, os_version, arch, country, timezone,
                                  cpu_model, cpu_cores_physical, cpu_cores_logical,
                                  cpu_perf_cores, cpu_eff_cores, system_memory_mb,
                                  gpu_vendor, gpu_model, gpu_memory_mb, gpu_api,
                                  unified_memory, reports_count, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `).bind(
            r.install_id, r.nonce, r.first_seen, r.last_launched, r.jve_sha,
            r.platform, r.os_version, r.arch, r.country, r.timezone,
            r.cpu_model, r.cpu_cores_physical, r.cpu_cores_logical,
            r.cpu_perf_cores, r.cpu_eff_cores, r.system_memory_mb,
            r.gpu_vendor, r.gpu_model, r.gpu_memory_mb, r.gpu_api,
            r.unified_memory, r.reports_count, r.status,
        ).run();
    },

    async get(db: D1Database, install_id: string): Promise<InstallRow | null> {
        return await db.prepare("SELECT * FROM installs WHERE install_id = ?")
            .bind(install_id)
            .first<InstallRow>();
    },

    async update_last_launched_and_sha(db: D1Database, install_id: string, ts: number, jve_sha: string): Promise<void> {
        await db.prepare(`
            UPDATE installs SET last_launched = MAX(last_launched, ?), jve_sha = ?
            WHERE install_id = ?
        `).bind(ts, jve_sha, install_id).run();
    },

    async update_hardware(db: D1Database, install_id: string, h: Partial<InstallRow>): Promise<void> {
        // Build a per-call partial UPDATE so non-supplied columns aren't
        // clobbered to null.
        const sets: string[] = [];
        const values: unknown[] = [];
        for (const k of ["os_version", "arch", "cpu_model", "cpu_cores_physical", "cpu_cores_logical",
                         "cpu_perf_cores", "cpu_eff_cores", "system_memory_mb",
                         "gpu_vendor", "gpu_model", "gpu_memory_mb", "gpu_api", "unified_memory"]) {
            const v = (h as Record<string, unknown>)[k];
            if (v !== undefined && v !== null) {
                sets.push(`${k} = ?`);
                values.push(v);
            }
        }
        if (sets.length === 0) return;
        values.push(install_id);
        await db.prepare(`UPDATE installs SET ${sets.join(", ")} WHERE install_id = ?`)
            .bind(...values).run();
    },

    async bump_reports_count(db: D1Database, install_id: string): Promise<void> {
        await db.prepare(`UPDATE installs SET reports_count = reports_count + 1 WHERE install_id = ?`)
            .bind(install_id).run();
    },
};

export const clusters = {
    async upsert(db: D1Database, signature: string, now: number): Promise<{ id: string; count: number; gh_issue_url: string | null }> {
        // SQLite ON CONFLICT clause. Generates a new UUID if no row
        // exists; otherwise bumps count. The RETURNING clause is
        // supported by D1 (SQLite 3.35+).
        const new_id = crypto.randomUUID();
        const row = await db.prepare(`
            INSERT INTO clusters (id, signature, first_seen, count)
            VALUES (?, ?, ?, 1)
            ON CONFLICT(signature) DO UPDATE SET count = count + 1
            RETURNING id, count, gh_issue_url
        `).bind(new_id, signature, now)
          .first<{ id: string; count: number; gh_issue_url: string | null }>();
        return row!;
    },

    async get(db: D1Database, cluster_id: string): Promise<{ id: string; signature: string; count: number; gh_issue_url: string | null } | null> {
        return await db.prepare("SELECT id, signature, count, gh_issue_url FROM clusters WHERE id = ?")
            .bind(cluster_id)
            .first();
    },

    async set_gh_issue_url(db: D1Database, cluster_id: string, url: string): Promise<void> {
        await db.prepare(`UPDATE clusters SET gh_issue_url = ? WHERE id = ?`)
            .bind(url, cluster_id).run();
    },
};

export interface ReportRow {
    id: string;
    install_id: string;
    ts: number;
    jve_sha: string;
    schema_version: string;
    signature: string;
    last_cmd: string | null;
    last_err: string | null;
    user_title: string;
    user_desc: string | null;
    capture_type: "user_submitted" | "automatic";
    text_only: number;
    r2_key: string;
    cluster_id: string;
}

export const reports = {
    async insert(db: D1Database, r: ReportRow): Promise<void> {
        await db.prepare(`
            INSERT INTO reports (id, install_id, ts, jve_sha, schema_version, signature,
                                 last_cmd, last_err, user_title, user_desc, capture_type,
                                 text_only, r2_key, cluster_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `).bind(
            r.id, r.install_id, r.ts, r.jve_sha, r.schema_version, r.signature,
            r.last_cmd, r.last_err, r.user_title, r.user_desc, r.capture_type,
            r.text_only, r.r2_key, r.cluster_id,
        ).run();
    },

    async count_in_window(db: D1Database, install_id: string, since_ts: number): Promise<number> {
        const row = await db.prepare(`SELECT COUNT(*) AS n FROM reports WHERE install_id = ? AND ts >= ?`)
            .bind(install_id, since_ts).first<{ n: number }>();
        return row?.n ?? 0;
    },

    async list_for_cluster(db: D1Database, cluster_id: string): Promise<Array<{ id: string; install_id: string; ts: number; r2_key: string; user_title: string }>> {
        const result = await db.prepare(`
            SELECT id, install_id, ts, r2_key, user_title FROM reports
            WHERE cluster_id = ? ORDER BY ts DESC
        `).bind(cluster_id).all<{ id: string; install_id: string; ts: number; r2_key: string; user_title: string }>();
        return result.results ?? [];
    },
};

export const report_idempotency = {
    async get(db: D1Database, install_id: string, local_id: string): Promise<{ report_id: string } | null> {
        return await db.prepare(`SELECT report_id FROM report_idempotency WHERE install_id = ? AND local_id = ?`)
            .bind(install_id, local_id).first();
    },

    async insert(db: D1Database, install_id: string, local_id: string, report_id: string, now: number): Promise<void> {
        await db.prepare(`
            INSERT INTO report_idempotency (install_id, local_id, report_id, created_at)
            VALUES (?, ?, ?, ?)
        `).bind(install_id, local_id, report_id, now).run();
    },
};

export const install_register_attempts = {
    async atomic_increment_and_check(
        db: D1Database, ip_hash: string, window_start: number, cap: number,
    ): Promise<{ count_after: number; exceeded: boolean }> {
        // INSERT OR IGNORE + UPDATE in one prepared batch — D1 routes
        // both statements to the same SQLite session so the increment
        // is atomic with respect to the count read.
        const row = await db.prepare(`
            INSERT INTO install_register_attempts (ip_hash, window_start, attempt_count)
            VALUES (?, ?, 1)
            ON CONFLICT(ip_hash, window_start) DO UPDATE SET attempt_count = attempt_count + 1
            RETURNING attempt_count
        `).bind(ip_hash, window_start).first<{ attempt_count: number }>();
        const count_after = row!.attempt_count;
        return { count_after, exceeded: count_after > cap };
    },
};
