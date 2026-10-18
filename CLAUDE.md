# CLAUDE.md

EZ CUSTOMZ (ezcustomz.co): marketing + quote/booking site for a custom car interior shop (starlight headliners, ambient lighting, speaker builds) in Louisiana. Static site on GitHub Pages (`CNAME` = `ezcustomz.co`). No build step, no package manager, no tests. Edit the HTML and push to `main`.

## Files

| File | What it is |
|---|---|
| `index.html` | Public site (~90 KB, single file: CSS, SVG sprites, markup, JS all inline) |
| `reviews.html` | Public customer reviews page (same CSS/sprites/header copied from `index.html`). Lists reviews via RPC `get_reviews`, "Leave a review" form posts to `submit_review` |
| `gallery.html` | Public gallery page: every photo/video as a tile grid with the same lightbox as the homepage, blurred `images/admin-bg.webp` background. Has its **own copy** of the `GALLERY` array (add photos here too; some photos are gallery-page-only) |
| `supabase/reviews.sql` | `reviews` table + `get_reviews` / `submit_review` RPCs. Reviews start `pending` and show only once approved in the admin Reviews tab |
| `admin.html` | Private admin panel (`noindex`), single file. Supabase email/password login, manage bookings and days off |
| `supabase/days_off.sql` | Idempotent SQL for the `blocked_days` table, RPCs and the booking trigger. Run by hand in the Supabase SQL Editor |
| `pay.html` | Customer deposit page (`?t=<64-hex token>`): quote summary, full Deposit & Payment Terms, required checkbox, then POST to Edge Function `create-checkout` and redirect to Stripe. `&s=done` polls `get_deposit_request` until the webhook confirms; never trusts the redirect |
| `terms.html` | Public Deposit & Payment Terms, rendered from the live `deposit_terms` row (`get_deposit_terms`). Linked in every footer |
| `supabase/deposits.sql` | Stripe deposits: payment columns on `bookings`, `deposit_terms`, `deposit_agreements`, `stripe_events`, holds/triggers, admin + service-role RPCs. Setup steps in `supabase/STRIPE_SETUP.md` |
| `supabase/functions/` | Deno Edge Functions `create-checkout` and `stripe-webhook` (`npm:stripe@22.6.2`). Secrets live in Supabase, never in the repo |
| `images/gallery/*.webp` | Gallery photos used by `GALLERY` in `index.html` |

The base tables, `bookings` RPCs and `is_admin()` are **not** in the repo (only `days_off.sql` is); they live in the Supabase project.

## Run / deploy

- Local: open `index.html` directly, or any static server (`python -m http.server`). Nothing to compile.
- Deploy: commit and push to `main`; GitHub Pages serves it.
- Schema changes: edit `supabase/days_off.sql` and re-run it in Supabase by hand (safe to re-run).

## index.html layout

Inline `<script>` blocks, in order:
1. **Gallery** — `GALLERY` array near the top is the only thing to edit to add/remove cards (`label`, `note`, `img`, optional `thumb`/`alt`/`pos`). The rest is carousel + lightbox code. Section is `hidden` until it has items.
2. **Quote form** (`#qf`) — Vehicle year/make/model, services (starlight / ambient / speaker), pricing, date, contact.
   - `D` = vehicle makes/models string; each model ends in a size code (`s` sedan, `u`, `t` truck, `x` SUV, `c` coupe) mapped to base price via `R`. `rec()` recommends a star count from it.
   - `sync()` recomputes the estimate, deposit ($150 per service) and summary chips on any change.
   - `need()` / `flag()` do required-field validation (`NM` holds the field labels).
   - Submit: builds a text summary, POSTs to Supabase RPC `create_booking_request`, then also POSTs the form to FormSubmit.co (`FORMSPREE` const, AJAX endpoint; no submission limit). Success if either works. If both fail the user gets SMS / email / copy fallback buttons.
3. **Calendar** — Month grid (`cal()`); disabled = past/today, Sundays, `BLOCKED` array, or `taken` set. `loadTaken()` fills `taken` from RPCs `get_taken_days` (approved bookings, 120 days) and `get_blocked_days` (admin days off, ~1 year). Fails silently if Supabase is unreachable.
4. **Starfield** canvas hero animation (respects `prefers-reduced-motion`).

Seasonal theme: Halloween sale. `SALE_OFF` / `SALE_END` (`'2026-10-31'`, America/Chicago) control $150 off every starlight package. After `SALE_END` the banners (`#hw`, `#hwn`) remove themselves and prices revert. Halloween decor lives in the `i-pumpkin`/`i-web`/`i-skull`... SVG `<symbol>`s and the second `:root{--org...}` CSS block; remove those to retire the theme.

Styling: CSS custom properties on `:root`, dark mode via `prefers-color-scheme` plus `data-theme` override. Mobile breakpoints at 900px and 600px.

## admin.html

- Login posts to Supabase `/auth/v1/token?grant_type=password`; JWT kept in `sessionStorage['ezt']`.
- All data calls go through `api()` → Supabase REST (`/rest/v1/...`) with the anon key + bearer token. A 401 / `PGRST303` signs out.
- Tabs: Pending / Review confirmed / Declined-cancelled (query `bookings` by `status`) and **Days off** (calendar + range form).
- **Reviews** tab: sub-filter Waiting / Live / Hidden (`pending` / `approved` / `rejected`) via `admin_list_reviews(p_status)`; actions `set_review_status(p_id,p_status)`, `delete_review(p_id)`. Tab label shows the waiting count.
- Booking actions are RPCs taking `p_id`: `approve_booking`, `decline_booking`, `cancel_booking`, `delete_booking`. Days off: `admin_list_blocked_days`, `block_days(p_from,p_to,p_note)`, `unblock_day(p_day)`.
- `ERR` maps Postgres exception names (`slot_taken`, `not_admin`, ...) to user-facing text.

## Backend (Supabase, project `umvdxjnhzehcoujrishh`)

- URL and the publishable anon key are hard-coded in both HTML files (public by design). **Never commit the `service_role` key.**
- Security is in the DB: RLS on, direct table access revoked, everything via `security definer` RPCs that check `is_admin()`. `get_blocked_days` returns dates only, notes stay admin-only.
- `bookings` has a `before insert` trigger (`reject_blocked_booking`) raising `day_blocked`; the site surfaces `slot_taken`, `day_blocked`, `too_many_requests` errors.
- Booking statuses: `pending`, `approved`, `declined`, `cancelled`. Approved bookings block the whole day publicly.

## Deposits (Stripe)

- Flow: request (`pending`/`pay_status=none`) -> admin `admin_send_deposit_link` sets `estimate_cents`, `deposit_cents`, `hold_until`, `pay_token` (`pending`/`awaiting`, day held via `get_held_days`) -> customer accepts terms on `pay.html` -> `create-checkout` -> Stripe -> `stripe-webhook` -> `deposit_mark_paid` (`approved`/`paid`).
- The owner reviews every quote before any deposit (owner's call; an instant pay-after-quote button was tried and removed). On "Approve and create deposit link", admin `mailLink()` emails the customer the pay link via FormSubmit `_autoresponse` (owner gets a copy); checkbox "Email the link" is on by default. No automatic SMS (would need Twilio + 10DLC registration); "Text it" opens the phone's SMS app prefilled.
- Only the signature-verified webhook confirms. `stripe_events` + `payment_intent_id` make it idempotent; `lock_day()` advisory lock + triggers (`bookings_reject_held`, `bookings_guard_held`) stop double booking. Late/duplicate payments become `pay_status='conflict'` for the owner.
- Cancelling an approved booking copies the day into `blocked_days` (owner releases it in Days off). Refunds are done in the Stripe Dashboard; `charge.refunded` only records them.
- Terms: published versions are immutable; each acceptance snapshots the exact text into `deposit_agreements`. Stripe's API rejects `payment_method_types` now: methods come from Dashboard settings.
- Test mode only until the `STRIPE_ALLOW_LIVE=true` secret is set. Emails: owner via FormSubmit, customer via Resend if configured else FormSubmit `_autoresponse`.

## Conventions / gotchas

- Dense, minified-style vanilla JS (`$ = getElementById`, terse names). Match it; no frameworks, no dependencies.
- Dates are handled as `YYYY-MM-DD` strings via `iso()` / `isoD()`; display parsing uses `T12:00:00` to avoid timezone shifts.
- User-supplied text going into `innerHTML` in admin must go through `esc()`.
- Business contact info (phone, email) is hard-coded in `index.html` (`linkUp()`, error strings, footer); grep before changing.
- Supabase URL/key are duplicated in both files; update both together.

## Workflow rules (from the owner)

- **Always test in a real browser before pushing** (playwright-cli, `--browser chrome`, local `http.server`), then push to `main`. Verify the change actually renders/works, not just that the file saved.
- When told to do something and push, do the work, test it, then push without asking again. Keep this file updated as the owner gives new standing instructions.
- Python 3.12 is installed (`python`, or full path `%LOCALAPPDATA%\Programs\Python\Python312\python.exe` if PATH is stale); no ffmpeg. `python -m http.server` works for local testing. Use `uv run --with <pkg> python ...` for one-off scripts (e.g. `opencv-python-headless` to grab a video frame for a thumb).
- **Compress new images**: convert dropped photos to `.webp` (quality ~80, via `uv run --with pillow python`) whenever that makes the file smaller, delete the original jpg/png, and compress oversized files too. Rename to clean names.
- Video cards need a `thumb` image plus `video` (.mp4); rename dropped files to clean names (no spaces/parens).
