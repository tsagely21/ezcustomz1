# Supabase backend

The site's data lives in a Supabase project (Postgres + Auth). The front end only talks to it through the REST API with the public anon key; all protection is in the database.

## Files

| File | Purpose |
|---|---|
| `days_off.sql` | `blocked_days` table, days-off functions, and the trigger that rejects bookings on blocked days |
| `hardening.sql` | Replaces `create_booking_request` with input length limits and spam caps |
| `reviews.sql` | `reviews` table (`pending` / `approved` / `rejected`), public `get_reviews` (approved only) and `submit_review` (length limits, spam caps), admin `admin_list_reviews`, `set_review_status`, `delete_review` |

Run each file once in **Dashboard > SQL Editor**. They are safe to re-run.

> The original `bookings` and `admins` tables and the booking functions were created directly in the dashboard and are not in this repo. To capture them exactly, run `supabase db dump --schema public -f supabase/schema.sql` (needs the [Supabase CLI](https://supabase.com/docs/guides/cli)) and commit the result.

## Data model

- **`bookings`**: `id`, `slot_date`, `name`, `phone`, `email`, `service`, `selections`, `status` (`pending`, `approved`, `declined`, `cancelled`), `created_at`, `decided_at`. A unique index (`bookings_one_approved_per_day`) allows only one approved booking per day.
- **`blocked_days`**: `day`, `note`. Days off set from the admin panel.
- **`admins`**: `user_id`. Users in this table are admins (`is_admin()`).

## Functions

| Function | Callable by | Does |
|---|---|---|
| `create_booking_request` | public | Validates and inserts a pending request |
| `get_taken_days` | public | Dates with an approved booking (no personal data) |
| `get_blocked_days` | public | Days off (dates only, notes stay private) |
| `approve_booking`, `decline_booking`, `cancel_booking`, `delete_booking` | admin | Manage a booking by id |
| `admin_list_blocked_days`, `block_days`, `unblock_day` | admin | Manage days off |
| `is_admin` | internal | `exists (select 1 from admins where user_id = auth.uid())` |

All are `SECURITY DEFINER` with `search_path=public`, and every admin function starts by raising `not_admin` unless `is_admin()` is true.

## Security model

- Row-level security is on. `anon` has no table access. `authenticated` can only `SELECT` from `bookings`, and only if `is_admin()`.
- Writes only happen through the functions above.
- Supabase's linter warns that these `SECURITY DEFINER` functions are callable through the API. That is expected: public ones are meant to be, and admin ones check `is_admin()` internally.

## Recommended project settings

- Authentication > Sign In: **disable "Allow new users to sign up"**. Only the admin needs an account.
- Use a long, unique admin password, and enable leaked-password protection if your plan includes it.
- Free-tier projects pause after about a week of inactivity. Upgrade, or visit the admin panel regularly.

## Backups

See the notes in the project settings under **Database > Backups**. Free projects have no automatic backups. Periodically export `bookings` (Table Editor > Export to CSV) and keep the schema file above in this repo.
