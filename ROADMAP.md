# Pinchflat Personal Edition — Roadmap

Fork of kieraneglin/pinchflat @ 67d8bd5, now FULLY DETACHED and rebranded **re:Pinchflat**
(upstream dormant since 2025-12-16; this fork is for one personal Unraid deployment and is
not shared publicly). `personal` is the default branch; no upstream syncing.

Goal status: bugs fixed (Phase 1), mechanics improved (Phase 2), UI reworked (Phase 3+).

Deployment target: Unraid via Docker (`docker/selfhosted.Dockerfile`), SQLite on local disk.

---

## Phase 1 — Bug fixes (correctness first)

Ordered by impact. Each item: upstream issue → fix strategy → done-when.

### 1.1 Cookie/auth bypass doesn't cover all download operations (#878) — *user pain #1*
The YouTube cookie pass-through only applies to indexing + error_recovery, NOT normal
downloads — so cookies don't prevent the exact blocks users set them up for.
**Fix**: route cookie args through every yt-dlp invocation path (DownloadOptionBuilder,
MediaDownloader, quality upgrades, metadata fetches). Add a test asserting cookies appear
in the constructed args for each operation type.
**Done when**: with cookies set, a fresh download of a bot-blocked video succeeds.

### 1.2 Stale yt-dlp inside shipped image (#868/#854/#886/#867) — *user pain #1*
yt-dlp is baked at image build; upstream releases weekly; YouTube breaks old versions fast.
**Fix**: add optional startup + scheduled yt-dlp self-update job (env-gated,
`YT_DLP_AUTO_UPDATE=nightly|boot|off`, default `nightly`), logged to app logs + surfaced in UI
settings. Keep image pins as fallback.
**Done when**: container running ≥1 week has yt-dlp newer than its build date.

### 1.3 Transient download failures permanently marked "Manually Ignored" (#789)
One transient error (network blip, rate limit) silently drops a video forever.
**Fix**: distinguish transient vs permanent error classes; retry transient N times with
backoff; only mark ignored for confirmed-permanent causes (deleted/private/members-only).
**Done when**: simulated transient failure re-queues automatically.

### 1.4 Livestream VODs stuck in "pending" forever (#851)
`post_live` status persists after processing completes.
**Fix**: normalize post_live state in the indexer/status transitions; re-check the
status on each indexing pass instead of trusting the cached value.
**Done when**: a completed livestream VOD reaches "downloaded" without manual poke.

### 1.5 Infinite download workflow loop (#889)
A missing/mis-ordered workflow step causes endless re-enqueue.
**Fix**: add loop guard (max attempts + poison-message state in Oban), surface stuck
items in the UI instead of silently looping.
**Done when**: the reported repro converges to a failed state with a visible reason.

### 1.6 No error visibility — add Errors tab (#870, #816, #617)
Failures are invisible; "Pending vs Failed" semantics are unclear.
**Fix**: minimal viable version in Phase 1: structured `last_error` on media items/sources
shown inline in the UI; full errors console moves to Phase 3.
**Done when**: a failed download shows its yt-dlp stderr excerpt in the media list.

### 1.7 Container restart loop if custom output dir missing (#898)
**Fix**: create the directory at boot (like /config handling) + clear boot error if unwritable.
**Done when**: container boots with a not-yet-existing output path.

### 1.8 Root-owned downloads / permission handling (#709)
**Fix**: honor PUID/PGID-style env or document+enforce UMASK path; ensure files chown'd to
the runtime user.
**Done when**: downloaded files match the container runtime user on the host.

### 1.9 Unsanitized series_directory (#902)
**Fix**: sanitize path segments (no traversal/empty/mismatched segments); validate on save.
**Done when**: hostile template input is rejected or normalized.

## Phase 2 — Mechanical improvements (the engine)

- **DB resilience & scale** (#887 bloat, #873 timeouts, #832 busy-DB, #591 sources timeout,
  #903 checkout timeout): WAL tuning + busy_timeout, query audit on Sources/Media pages
  (N+1 hunts, add indexes), periodic VACUUM/optimize job, eval read-replica pattern or
  Postgres option (#790) only if SQLite work is insufficient.
- **Download engine**: smarter retry/backoff classes (shared with 1.3), per-source
  concurrency caps, exponential rate-limit detection ("429 seen → globally throttle").
- **File management** (#408 rename existing on template change, #139 Sonarr-style moves,
  #805 don't re-download externally deleted media): a "reconcile library" job that
  diffs desired vs on-disk layout.
- **Format passthrough** (#845): pass user yt-dlp format selectors through instead of
  forcing m4a/AAC.
- **Indexing**: optional instant re-index (manual "check now" per source), members-only
  filter (#648).

## Phase 3 — UI/UX tuning

- Real-time status overhaul: honest per-item state machine (queued/indexing/downloading/
  failed-with-reason/done) streamed over LiveView; activity feed.
- Errors console (#870 full version): filterable, per-source, raw yt-dlp output viewer.
- Bulk actions (#346), delete-all-pending (#724), multi-source manual download (#478).
- Source-add UX: inline validation + clear errors (#816).
- Settings surface for new engine knobs (auto-update, concurrency, cookies health check).
- Optional: simple REST API (#435/#791) for Home Assistant integrations.

## Working agreements

- Dev loop: `docker compose up phx` → http://localhost:4008 (mix test inside container).
- Every fix ships with a test in `test/pinchflat/...` mirroring the module.
- Small PR-style commits on fix branches (`fix/878-cookies-all-ops`), merged to `personal`.
