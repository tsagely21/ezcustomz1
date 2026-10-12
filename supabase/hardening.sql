-- Hardens public booking requests: input length limits and spam caps.
-- Run once in Supabase: Dashboard > SQL Editor > New query > paste this file > Run.
-- Safe to run again. Replaces create_booking_request in place (grants are kept).
--
-- Added on top of the existing checks (date, day_ok, email, phone, slot_taken, 3 per phone):
--   * max lengths on every text field
--   * max 3 open requests per email address
--   * max 40 new requests per hour across the whole site

create or replace function public.create_booking_request(
  p_date date, p_name text, p_phone text, p_email text, p_service text, p_selections text
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  new_id uuid;
  today_cst date := (now() at time zone 'America/Chicago')::date;
  v_name text := trim(coalesce(p_name, ''));
  v_phone text := trim(coalesce(p_phone, ''));
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  if p_date <= today_cst or p_date > today_cst + 365 then raise exception 'invalid_date'; end if;
  if not public.day_ok(p_date) then raise exception 'invalid_day'; end if;

  if v_name = '' or length(v_name) > 100
     or length(v_phone) > 30
     or length(v_email) > 254
     or length(coalesce(p_service, '')) > 200
     or length(coalesce(p_selections, '')) > 4000 then
    raise exception 'invalid_input';
  end if;

  if v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then raise exception 'invalid_email'; end if;
  if length(regexp_replace(v_phone, '\D', '', 'g')) < 10 then raise exception 'invalid_phone'; end if;

  if exists (select 1 from public.bookings where status = 'approved' and slot_date = p_date) then
    raise exception 'slot_taken';
  end if;

  -- spam brakes: per phone, per email, and site-wide per hour
  if (select count(*) from public.bookings
        where status = 'pending'
          and regexp_replace(phone, '\D', '', 'g') = regexp_replace(v_phone, '\D', '', 'g')) >= 3
     or (select count(*) from public.bookings
           where status = 'pending' and lower(email) = v_email) >= 3
     or (select count(*) from public.bookings
           where created_at > now() - interval '1 hour') >= 40 then
    raise exception 'too_many_requests';
  end if;

  insert into public.bookings (slot_date, name, phone, email, service, selections)
  values (p_date, v_name, v_phone, v_email, p_service, p_selections)
  returning id into new_id;
  return new_id;
end $$;

notify pgrst, 'reload schema';
