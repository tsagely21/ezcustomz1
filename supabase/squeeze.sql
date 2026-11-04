-- "Need us to squeeze you in?" (+$250): lets a customer book a day that is already taken,
-- but only when that day's confirmed work is ambient lighting alone. At most one squeeze-in per day.
-- Run once in Supabase SQL Editor, then hardening.sql (create_booking_request takes p_squeeze).
-- deposits.sql already calls day_taken(). Safe to run again.

alter table public.bookings add column if not exists squeeze boolean not null default false;

drop index if exists public.bookings_one_approved_per_day;
create unique index bookings_one_approved_per_day on public.bookings (slot_date) where status = 'approved' and not squeeze;
create unique index if not exists bookings_one_squeeze_per_day on public.bookings (slot_date) where status = 'approved' and squeeze;

-- Is p_day unavailable? Regular: any confirmed booking. Squeeze-in: a confirmed squeeze-in or anything besides ambient-only.
create or replace function public.day_taken(p_day date, p_squeeze boolean, p_except uuid default null)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bookings b where b.slot_date = p_day and b.status = 'approved'
    and b.id is distinct from p_except and (not p_squeeze or b.squeeze or b.service <> 'Ambient lighting'));
$$;
revoke execute on function public.day_taken(date, boolean, uuid) from public, anon, authenticated;

-- Public: booked days a squeeze-in can still take (dates only).
create or replace function public.get_squeeze_days(from_date date, to_date date)
returns table(day date) language sql stable security definer set search_path = public as $$
  select b.slot_date from public.bookings b
  where b.status = 'approved' and b.slot_date between from_date and least(to_date, from_date + 120)
    and not exists (select 1 from public.blocked_days d where d.day = b.slot_date)
    and not public.day_held(b.slot_date)
  group by b.slot_date having bool_and(b.service = 'Ambient lighting' and not b.squeeze) order by 1;
$$;
grant execute on function public.get_squeeze_days(date, date) to anon, authenticated;

create or replace function public.approve_booking(p_id uuid)
returns public.bookings language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  select * into b from public.bookings where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if b.status <> 'pending' then raise exception 'not_pending'; end if;
  if public.day_taken(b.slot_date, b.squeeze, b.id) then raise exception 'slot_taken'; end if;
  begin
    update public.bookings set status = 'approved', decided_at = now() where id = p_id returning * into b;
  exception when unique_violation then
    raise exception 'slot_taken';
  end;
  return b;
end $$;

notify pgrst, 'reload schema';
