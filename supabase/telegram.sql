-- Telegram quote alerts for EZ CUSTOMZ: every new booking request pings the telegram-bot Edge Function,
-- which messages the owner with Send link / Change price / Decline buttons.
-- Run in Supabase: Dashboard > SQL Editor > New query > paste this file > Run. Safe to run again.
-- Needs deposits.sql. Bot token + chat id live only in Edge Function secrets (see TELEGRAM_SETUP.md).

create extension if not exists pg_net;

-- Set when the owner has been messaged about a request, so a booking is only ever announced once.
alter table public.bookings add column if not exists tg_notified_at timestamptz;

-- The telegram-bot function acts as the owner with the service_role key, so it counts as admin.
-- service_role already bypasses RLS and every grant; this only lets it through the not_admin checks.
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(auth.role() = 'service_role', false) or exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- Fire-and-forget: queued by pg_net and sent after the insert commits. Never blocks a booking.
create or replace function public.tg_notify_new_booking()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(url := 'https://umvdxjnhzehcoujrishh.supabase.co/functions/v1/telegram-bot',
    body := jsonb_build_object('new_booking', new.id), headers := '{"Content-Type":"application/json"}'::jsonb);
  return new;
exception when others then return new;
end $$;
drop trigger if exists bookings_tg_notify on public.bookings;
create trigger bookings_tg_notify after insert on public.bookings for each row execute function public.tg_notify_new_booking();
revoke execute on function public.tg_notify_new_booking() from anon, authenticated, public;

notify pgrst, 'reload schema';
