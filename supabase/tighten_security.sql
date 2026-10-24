-- Tightens Supabase Security Advisor warnings without changing how the site works.
-- Run in Supabase: SQL Editor > New query (empty) > paste this file > Run. Safe to run again.

-- Admin-only functions: signed-out visitors no longer need (or get) permission to call them.
-- (They already refused non-admins; this removes the open door entirely.) Admin login still works.
revoke execute on function public.approve_booking(uuid) from anon, public;
revoke execute on function public.decline_booking(uuid) from anon, public;
revoke execute on function public.cancel_booking(uuid) from anon, public;
revoke execute on function public.delete_booking(uuid) from anon, public;
revoke execute on function public.admin_list_blocked_days() from anon, public;
revoke execute on function public.block_days(date, date, text) from anon, public;
revoke execute on function public.unblock_day(date) from anon, public;

-- Internal trigger function: nobody should call it through the API (the database still runs it itself).
revoke execute on function public.reject_blocked_booking() from anon, authenticated, public;

-- Pin the search path on the older helper functions.
alter function public.day_ok set search_path = public;
alter function public.vehicle_of(text) set search_path = public;

notify pgrst, 'reload schema';

-- Left alone on purpose: create_booking_request, get_taken_days, get_blocked_days (the public quote page
-- needs them) and is_admin (harmless, returns false for visitors).
