# Backend: Supabase, Stripe, Telegram

Supabase project `umvdxjnhzehcoujrishh`. Base tables, `bookings` RPCs and `is_admin()` are **not** in the repo; they live in the project. SQL files in `supabase/` are idempotent and run by hand in the SQL Editor (or via the Supabase MCP). File list: `supabase/README.md`.

## Security model
- RLS on, direct table access revoked, everything through `security definer` RPCs checking `is_admin()` (also true for `service_role`, so Edge Functions can call admin RPCs). `tighten_security.sql` revokes anon execute on admin RPCs; `hardening.sql` adds length limits + spam caps to `create_booking_request` (3 open per phone/email, 40/hour site-wide).
- Publishable anon key is public by design. **Never commit the `service_role` key**; secrets live in Supabase Edge Function secrets.
- `get_blocked_days` returns dates only; notes stay admin-only.

## Bookings
- Statuses: `pending`, `approved`, `declined`, `cancelled`. Approved blocks the whole day publicly.
- `reject_blocked_booking` before-insert trigger raises `day_blocked`; site surfaces `slot_taken`, `day_blocked`, `too_many_requests`.
- Cancelling an approved booking copies the day into `blocked_days` (owner releases it in Days off).

## Deposits (Stripe) — `deposits.sql`, `supabase/STRIPE_SETUP.md`
- Flow: request (`pending`/`pay_status=none`) -> `admin_send_deposit_link` sets `estimate_cents`, `deposit_cents`, `hold_until`, `pay_token` (`awaiting`, day held via `get_held_days`) -> `pay.html?t=<token>` (accept terms) -> Edge Function `create-checkout` -> Stripe -> `stripe-webhook` -> `deposit_mark_paid` (`approved`/`paid`). `pay.html&s=done` polls `get_deposit_request`; never trusts the redirect.
- Owner reviews every quote before any deposit (instant pay-after-quote was tried and removed; don't re-add).
- Only the signature-verified webhook confirms. `stripe_events` + `payment_intent_id` = idempotent; `lock_day()` advisory lock + `bookings_reject_held` / `bookings_guard_held` stop double booking. Late/duplicate payments -> `pay_status='conflict'`.
- Refunds in Stripe Dashboard; `charge.refunded` only records them. Payment methods come from Dashboard settings (API rejects `payment_method_types`). Functions use `npm:stripe@22.6.2`.
- Terms (`terms.html`, `get_deposit_terms`): published versions immutable; each acceptance snapshots text into `deposit_agreements`.
- **Test mode only** until secret `STRIPE_ALLOW_LIVE=true`.

## Materials — `materials.sql`
- `materials` rows per item per job (`ordered_at` null = to order, `auto` = from quote). `bookings_materials` trigger adds parts when `pay_status` becomes `paid` (wrapped so it can never block the webhook).
- `materials_for(service, selections)` maps quote options -> items: starlight kit by star count (skipped if "Customer supplies kit"), Suede wrap, Shooting star kit, Sunroof LED strips (standard/panoramic), Ambient lighting kit, "Speaker rack: <style>" / "Speaker box: <placement>", Custom logo. Update it when quote option wording changes.

## Telegram bot — `telegram.sql`, `functions/telegram-bot`, `supabase/TELEGRAM_SETUP.md`
- @ezcustomz_bot. Insert trigger (`pg_net`) pings the function once per booking (`tg_notified_at`). Buttons: Send link (form's estimate/deposit, 48 h hold, `admin_send_deposit_link` + `send-deposit-link` email) / Change price (reply `1200 300`) / Decline; `/pending` re-lists; `/id` shows ids.
- Cards go to `TELEGRAM_CHAT_ID` (private or group); only `TELEGRAM_ADMIN_IDS` (default = chat id) can act, inside that chat. Webhook secret = SHA-256 of `<token>:ez-hook`.
- "📱 Text it from my phone" opens `text.html#p=<phone>&b=<msg>` (fragment never hits a server), which opens the phone's Messages app (Telegram buttons can't open `sms:`).

## Emails
Owner: FormSubmit. Customer: Resend via `send-deposit-link` if configured, else FormSubmit `_autoresponse`.
