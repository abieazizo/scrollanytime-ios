# RESTORE.md — putting Scroll Anytime back after something goes wrong

This is the document you read at 2am. It assumes nothing and skips nothing.

**A backup you have never restored is not a backup — it is a file.** The restore below has been
executed once for real against a scratch database, and the row-count diff is recorded in SHIP.md.

---

## What exists

| Thing | Where | How often | Kept |
|---|---|---|---|
| Full D1 dump (all tables, all rows) | R2 `zerem-media` → `backups/d1/YYYY-MM-DD.sql` | Nightly, on the 03:15 UTC cron | 30 days |
| Media (video, posters, captions, avatars) | R2 `zerem-media` → `media/…`, `avatars/…` | — | Live, plus the weekly mirror below |
| Media mirror | R2 `zerem-media-backup` | Weekly, GitHub Action | Rolling |
| Source downloads | R2 `zerem-media` → `originals/…` | On every ingest | Rolling |
| Code + config (non-secret) | git | Every commit | Forever |
| Secrets | Your password manager. **Never in a backup.** | — | — |

The dump is plain SQL and contains **data only, no secrets**. Its header lists the secret *names*
the restored Worker needs, so you can tell instantly whether you have everything.

---

## Check that a backup exists (do this monthly, takes 10 seconds)

Open `/admin` → **Errors** tab → the **Ops** card. It shows the newest dump, its size, its row count
and how many are being kept. Or from a terminal:

```bash
npx wrangler r2 object get zerem-media/backups/d1/$(date -u +%F).sql --file=- --remote | head -20
```

If today's has not been written yet (the cron runs at 03:15 UTC), press **Back up now** in /admin.

---

## RESTORE — the database

### Step 1. Get the dump

```bash
cd worker
npx wrangler r2 object get zerem-media/backups/d1/2026-09-02.sql --file=restore.sql --remote
```

Replace the date with the one you want. To see what you have:

```bash
npx wrangler r2 object list zerem-media --prefix backups/d1/ --remote
```

### Step 2. Decide where it goes

**Never restore straight over production on the first attempt.** Make a scratch database, restore
into that, look at it, and only then decide.

```bash
npx wrangler d1 create zerem-restore-test
```

Copy the `database_id` it prints.

### Step 3. Restore

```bash
npx wrangler d1 execute zerem-restore-test --remote --file=restore.sql
```

The dump drops and recreates every table, so it is safe to run twice. It ends by rebuilding the
full-text search index from `clips` (the FTS shadow tables are deliberately not replayed — replaying
an index representation produces a corrupt index).

### Step 4. Prove it worked

```bash
npx wrangler d1 execute zerem-restore-test --remote --command \
  "SELECT (SELECT COUNT(*) FROM clips) clips, (SELECT COUNT(*) FROM users) users, (SELECT COUNT(*) FROM rabbis) rabbis, (SELECT COUNT(*) FROM seen) seen, (SELECT COUNT(*) FROM saves) saves"
```

Run the identical command against `zerem` (production) and **compare the numbers**. They should match
the moment the dump was taken. Also check search survived:

```bash
npx wrangler d1 execute zerem-restore-test --remote --command \
  "SELECT COUNT(*) FROM clips_fts WHERE clips_fts MATCH 'torah'"
```

A non-zero answer means the index rebuilt.

### Step 5. Cut over (only if you actually mean to)

Edit `worker/wrangler.jsonc` → `d1_databases[0].database_id` → the restored database's id.
Then `npm run deploy` from the repo root, and confirm `/version` reports your commit.

Afterwards, delete the scratch database so it cannot be confused for the real one later:

```bash
npx wrangler d1 delete zerem-restore-test
```

---

## RESTORE — the media

Video and images are **not** in the D1 dump; they live in R2 and are mirrored weekly to
`zerem-media-backup`.

To restore everything from the mirror, on a machine with [rclone](https://rclone.org) installed and
an R2 API token (Cloudflare dashboard → R2 → Manage API tokens):

```bash
rclone sync :s3:zerem-media-backup :s3:zerem-media \
  --s3-provider=Cloudflare \
  --s3-endpoint="https://<ACCOUNT_ID>.r2.cloudflarestorage.com" \
  --s3-access-key-id="$R2_ACCESS_KEY_ID" \
  --s3-secret-access-key="$R2_SECRET_ACCESS_KEY" \
  --checksum --progress
```

To restore **one** clip, you don't need rclone:

```bash
npx wrangler r2 object get zerem-media-backup/media/<clipId>/v1/video.mp4 --file=v.mp4 --remote
npx wrangler r2 object put zerem-media/media/<clipId>/v1/video.mp4 --file=v.mp4 --remote
```

If the mirror is also gone, the clips can be re-ingested from source — `originals/` holds the raw
downloads, and `npm run ingest -- --all --reprocess-known` rebuilds the derived media.

---

## What a restore does NOT bring back

Be clear-eyed about this:

- **Secrets.** Set them again with `npx wrangler secret put NAME` from `worker/`. The dump's header
  lists every name.
- **Anything written after the dump was taken.** Worst case that is 24 hours of watch history,
  saves, follows and new sign-ups. Clips ingested that day are re-ingestible; user activity is not.
- **Sessions.** Everyone is signed out and signs in again with an email code. Their account, saves,
  follows and streak are intact — only the token is gone.

---

## If you are not sure what broke

1. `curl https://scrollanytime.com/health` — is the Worker alive?
2. `curl https://scrollanytime.com/version` — is the running code the commit you expect?
3. `curl https://scrollanytime.com/health/monitor` — what did the last synthetic check see?
4. `/admin` → Errors — is there a red spike banner?
5. `npx wrangler tail zerem` — watch live requests and exceptions.

A bad deploy is far more likely than data loss. Rolling back the code is one command:

```bash
git checkout <last-good-sha> && npm run deploy
```

Do that **before** you consider restoring a database.
