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

## Phase 4 — Source-add preview scan (specified, ready to build)

Show how many videos a source URL will download **before saving**, based on the
form's settings. Motivation: committing a channel blind means discovering a
5,000-video back-catalogue after the index has already started.

### 4.1 Scan preview on the source form

**How it works**
- New `Pinchflat.Sources.SourceScanner` context: one flat yt-dlp call per scan,
  reusing `YtDlp.MediaCollection.get_source_metadata/3` (`--skip-download`,
  `playlist_items: 0`) — fetches the channel/playlist listing without touching
  individual videos (~1 listing request per 100 videos; a 3k-video channel is
  seconds-to-a-minute).
- Must run through `CommandRunner` so scans inherit cookies and the 429 global
  RateLimit cooldown — a scan is real YouTube traffic.
- Count math applied in order: total entries found → `title_filter_regex` →
  shorts/livestream behaviour (duration + live-status heuristics) →
  `download_count` cap. Render a breakdown ("-112 by title filter, -230 shorts…").

**Honest limits (say them in the UI)**
- Description regex and members-only visibility CANNOT be applied cheaply — they
  need per-video metadata (that is what the full index fetches); members-only
  also depends on cookies present at scan time. Output is an estimate: show
  "≈N of M found will download; final count lands after the first index."

**UI + wiring**
- "Preview scan" button on new (and edit) source form; JSON endpoint
  (`POST /sources/scan`) + vanilla JS per the confirm_dialog pattern — do NOT
  wrap the form in a LiveView.
- Spinner while scanning; v1 uses a hard timeout (e.g. 90s) and surfaces a
  "channel too large for preview" message on timeout. Follow-up: move scan to an
  Oban job with a "scan running…" indicator for huge channels.

**Done when**
- With a real URL, the form shows found/matching counts + breakdown without saving;
  scan traffic respects cookies + 429 cooldown; timeout path handled; tests cover
  the count math with mocked yt-dlp output and the endpoint (including CSRF).

### 4.2 Follow-up: "add paused" (complementary, optional)

- Save the source with downloads paused, let the first index run, show the TRUE
  pending count (includes description/members-only filtering), then enable with
  one click. Zero new machinery — uses the real pipeline; pairs with 4.1
  (quick estimate at form time, exact numbers post-index).

Explicitly out of scope for both: live progress of the scan listing itself,
caching scan results across form edits.

## Phase 5 — In-app logs viewer (specified, ready to build)

View the app's own logs from the web UI. Today the only way is `docker logs`
over SSH, and the app log carries what no page shows: worker crashes, yt-dlp
auto-update events, cookie/backup/Oban errors.

### 5.1 Log buffer (additive Logger backend)

- New Logger backend GenServer capturing every log event into a bounded ETS
  ring buffer — default last 5,000 lines, env-tunable (`LOG_BUFFER_LINES`).
  Console output keeps flowing untouched (Docker logs unaffected); buffer is
  in-memory, i.e. logs-since-boot.
- Hard rules: never log from inside the backend (recursion), and any failure in
  the backend is swallowed — logging infrastructure can never take the app down.
- Store `{seq, time, level, message, metadata}`; format lines like the console
  formatter so the viewer reads like `docker logs`.
- Live delivery: batched PubSub broadcasts (~500ms flush) on a `log_buffer`
  topic — same architecture as the download-progress feature, so a chatty
  stream can't flood the websocket.
- Open decision at build time: `runtime.exs` currently defaults production
  `LOG_LEVEL` to debug (very chatty — Phoenix/Oban/ecto). Either flip the
  default to `:info` in the same change or guarantee the viewer's filters make
  debug usable. Buffer memory is trivial either way (~1 MB at 5k lines).

### 5.2 Logs viewer LiveView (Config → Logs)

- New sidebar entry under Config; monospace page styled like the /errors
  console, theme-aware (light + dark).
- Live-follow with pause and auto-scroll; level filter chips with counts
  ("3 errors since boot" visible at a glance); text search; filter by
  worker/module from Logger metadata (MediaDownloadWorker, Oban, …).
- "Download last N lines" export button for bug reports.
- Rendering must stay smooth at the buffer cap — chunked/virtualized list, not
  5,000 raw DOM nodes.
- Redaction pass while wiring: anything token-bearing gets the API-key masking
  treatment before it hits the buffer.

**Done when**: real log lines stream live in both themes; filters, search and
export work; buffer cap holds under a debug-level firehose; a deliberately
raised backend error changes nothing for the app; tests cover ring behaviour,
counts and filters; full suite green.

Explicitly out of scope: persistent file storage (follow-up: optional rotating
file under `/config`), docker-logs integration, external log aggregation.


## Phase 6 — Production audit retune (2026-10-24, specified)

Full UI/UX + feature audit of the production deployment (all 11 screens, both themes,
playwright + codex vision audit). 6 bugs found and fixed (83fa6fd, f4f3ce1): dead logs
search, dead logs auto-follow, CSRF-token leak into log redaction, Retry-Errored
scope/cap disclosure, Apprise test false-success, light-mode invisible attribute
values. Full report: ~/html-preview/re-pinchflat-audit/ (screenshots + codex-findings.md).

### 6.1 UI retune (priority order)
- **Light-theme primitives**: theme-aware input fills, badges, tab accents, helper
  text across shared components (core/button/tab components) — fixes every light
  screen at once.
- **Errors triage at scale**: collapse raw output by error signature + Details
  expansion; Select-this-page; visible totals ("showing 100 of 192").
- **Source detail**: replace the Raw-Attributes landing tab with an operational
  summary (monitoring state, counts, last/next check, profile, destination); raw
  fields collapsed under Technical details; local-timezone timestamps app-wide.
- **Keyboard accessibility**: switches/menus/disclosures are divs/spans today —
  convert to native buttons/inputs with focus rings and aria states.
- **Home history**: sort by downloaded-at, 20 rows, thumbnails beside titles.
- **Media detail**: cap player height (~420px), file status/size/destination beside it.
- **Preview scan**: invalidate result when profile/filters change; state which
  settings produced the estimate.
- **Logs polish**: trim rendered metadata to a useful subset (message-first),
  rename "All sources" -> "All modules".
- **Confirm dialogs**: consequence-named buttons ("Delete source and 63 files"),
  focus Cancel on destructive actions.

### 6.2 Feature candidates (from the feature study, daily-value ranked)
1. Retry-outcome visibility (keep last failure visible while Queued/Downloading).
2. Storage: always-on free-space stat, largest/oldest browsing, reclaim estimates,
   low-space download guard.
3. Search filters (source/state/size) in global results, kept in the URL.
4. Notification reliability: digest cursor advances only on successful send.
5. Bulk "Download selected" approval flow for index-only sources.
6. Global pause/resume downloads + visible next-check time.
7. Separate Missing-locally / Removed / Unavailable-upstream media states.

## Working agreements

- Dev loop: `docker compose up phx` → http://localhost:4008 (mix test inside container).
- Every fix ships with a test in `test/pinchflat/...` mirroring the module.
- Small PR-style commits on fix branches (`fix/878-cookies-all-ops`), merged to `personal`.
