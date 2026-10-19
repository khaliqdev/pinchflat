# Deploying re:Pinchflat (Unraid)

Personal deployment guide for this fork. Assumes an existing Pinchflat container
with real data in `/config` and `/downloads`.

## TL;DR — link back, don't go fresh

This fork shares upstream's database schema and app internals; your existing
`/config` (database, sources, settings, cookies) and `/downloads` carry over
directly. On first boot the container auto-runs its own migrations on top of
your current data — nothing is re-downloaded, nothing is re-indexed from
scratch.

## Cutover steps

1. **Stop the old Pinchflat container** (Unraid: stop, don't delete — you may
   want the old image for rollback). Stopping first lets SQLite checkpoint its
   WAL files cleanly.
2. **Back up `/config`**: `cp -a /mnt/user/appdata/pinchflat /mnt/user/appdata/pinchflat-backup-$(date +%F)`
   This is your rollback. Everything else is reproducible.
3. **Start re:Pinchflat** with the *same* volume mappings:
   - `/config` → your existing appdata path
   - `/downloads` → your existing downloads path
   - `TZ` as before
   - Optional new env vars (all have sane defaults):
     - `YT_DLP_AUTO_UPDATE` = `nightly` (default) — keeps yt-dlp fresh, the
       main defense against YouTube bot-blocking
     - `PUID` / `PGID` — downloaded files owned by that user instead of root
     - `DB_POOL_SIZE`, `DB_BUSY_TIMEOUT_MS`, `OBAN_PRUNER_MAX_AGE_DAYS`,
       `BACKUP_DIRECTORY` — tuning; defaults are fine
4. **First boot** runs migrations automatically (watch the log for the
   `2026101800*` entries) and prints `Permissions OK`. Healthcheck is at
   `/healthcheck`.
5. **Post-boot checklist**:
   - Sources page shows your sources with correct pending/downloaded counts
   - Downloads library opens and plays in Plex/Jellyfin (paths unchanged)
   - Config → Settings: upload a **fresh YouTube cookies.txt** (strongly
     recommended — the fork sends cookies on every operation now, but stale
     cookies are stale), and review "When a media file is deleted outside
     Pinchflat" (new default: prevent re-download)
   - Preferences section: pick your default theme
   - Errors page: previously-failed items appear here with their real error
     text; "Retry Errored" re-queues the still-pending ones

## What changes behaviorally

- **Pending items retry on the next indexing run** (same as upstream), but
  transient failures no longer vanish items or fake "ignored" states.
- **Externally-deleted media is not re-downloaded by default** (upstream
  re-downloaded it). Flip in Settings if you preferred the old behavior.
- **Rate limiting is self-managing**: a YouTube 429 trips a 15-minute global
  cooldown (banner in the top nav); cookies are applied to every operation.
- **Nightly**: database backup to `<config>/db/backups/` (7 kept) and yt-dlp
  self-update.

## Rollback

Stop re:Pinchflat, restore your `/config` backup, start the old image.
The fork's migrations are additive; upstream code ignores unknown columns.
The one caveat: after the fork runs, upstream will require thumbnails again
on its next metadata write — restore the backup rather than pointing the old
image at the migrated DB directly.

## Building the image

```sh
docker build -f docker/selfhosted.Dockerfile -t ghcr.io/khaliqdev/pinchflat:latest .
docker push ghcr.io/khaliqdev/pinchflat:latest
```
