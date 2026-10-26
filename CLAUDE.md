# CLAUDE.md

EZ CUSTOMZ (ezcustomz.co): marketing + quote/booking site for a custom car interior shop (starlight headliners, ambient lighting, speaker builds) in Louisiana. Static site on GitHub Pages (`CNAME`). No build step, no package manager, no tests. Edit HTML, push to `main`.

## Every session

- **Start:** `git fetch origin; git status -sb`. If behind, `git pull --ff-only` (local edits in other files are fine; if it refuses, stop and tell the owner). Never work on a stale checkout.
- **Read only what the task needs.** This file is the map; details live in `docs/` (below). Don't open every doc up front.
- **End (when the owner says "update claude md"):** add new standing instructions and facts a future session needs, delete anything stale/finished (old sales, removed features, one-off fixes), keep each fact in exactly one place (here for rules/map, `docs/*.md` for detail), keep this file under ~80 lines. Then commit and push.

## Map

| Area | Files | Details |
|---|---|---|
| Homepage (gallery ribbon, quote form, calendar, hero film, sale) | `index.html` | [docs/index-html.md](docs/index-html.md) |
| Admin panel (bookings, days off, reviews, gallery upload, materials) | `admin.html` | [docs/admin.md](docs/admin.md) |
| Supabase DB, Stripe deposits, Telegram bot, emails | `supabase/*.sql`, `supabase/functions/*` | [docs/backend.md](docs/backend.md) |
| Reviews page | `reviews.html` (`get_reviews`, `submit_review`; reviews start `pending`) | backend.md |
| Gallery page | `gallery.html` (`get_gallery`, all non-hidden; local `GALLERY` = offline fallback; `place` = `home`/`gallery`/`hidden`) | admin.md |
| Deposit / terms pages | `pay.html` (`?t=<token>`), `terms.html` | backend.md > Deposits |
| Refund & return policy | `refund.html` (static, no DB; deposits/completed work final, faulty supplied parts replaced). URL is set in Stripe's checkout store policies; linked in every footer | |
| SMS helper for the bot | `text.html` (`noindex`) | backend.md > Telegram |
| Media | `images/gallery/*.webp`, `images/hero/*`, `assets/` (icons, logo, og-image) | |

## Conventions / gotchas

- Dense, minified-style vanilla JS (`$ = getElementById`, terse names). Match it; no frameworks, no dependencies.
- Dates are `YYYY-MM-DD` strings via `iso()` / `isoD()`; display parsing uses `T12:00:00` to avoid timezone shifts.
- Supabase URL + anon key are duplicated in index, admin, reviews, gallery, pay, terms; change all together. Never commit `service_role`.
- Business phone/email are hard-coded in `index.html` (`linkUp()`, error strings, footer); grep before changing.
- SQL in `supabase/` is idempotent and run by hand (SQL Editor or Supabase MCP); pushing doesn't apply it. Edge Functions are deployed separately too.

## Workflow rules (from the owner)

- **Always test in a real browser before pushing** (playwright-cli, `--browser chrome`, local `python -m http.server`). Verify it renders/works, not just that the file saved.
- When told to do something and push: do it, test it, push without asking again.
- Look/style changes: get the owner's OK (screenshots / branch) before pushing live.
- Python 3.12 (`python`, or `%LOCALAPPDATA%\Programs\Python\Python312\python.exe` if PATH is stale); no ffmpeg. One-off scripts: `uv run --with <pkg> python ...` (e.g. `opencv-python-headless` to grab a video frame).
- **Compress new images**: convert to `.webp` (quality ~80, `uv run --with pillow python`) when smaller, delete the original, compress oversized files, clean names (no spaces/parens). Video cards need a `thumb` image + `.mp4`.
