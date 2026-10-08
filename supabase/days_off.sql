-- Days off / blocked dates for the EZ CUSTOMZ booking calendar.
-- Run once in Supabase: Dashboard > SQL Editor > New query > paste this file > Run.
-- Safe to run again.

create table if not exists public.blocked_days (
  day date primary key,
  note text not null default '',
  created_at timestamptz not null default now()
);
alter table public.blocked_days enable row level security;
revoke all on public.blocked_days from anon, authenticated;

-- Public: dates only (notes stay private), used by the quote page calendar.
create or replace function public.get_blocked_days(from_date date, to_date date)
returns table(day date) language sql stable security definer set search_path = public as $$
  select b.day from public.blocked_days b where b.day between from_date and to_date order by b.day;
$$;

-- Admin: list with notes.
create or replace function public.admin_list_blocked_days()
returns setof public.blocked_days language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  return query select * from public.blocked_days where day >= current_date - 1 order by day;
end $$;

-- Admin: block one day or a range (inclusive). Re-blocking a day updates its note.
create or replace function public.block_days(p_from date, p_to date, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  if p_to is null then p_to := p_from; end if;
  if p_to < p_from then raise exception 'bad_range'; end if;
  if p_to - p_from > 366 then raise exception 'range_too_long'; end if;
  insert into public.blocked_days(day, note)
    select d::date, coalesce(p_note, '') from generate_series(p_from, p_to, interval '1 day') d
  on conflict (day) do update set note = excluded.note;
end $$;

-- Admin: open a day back up.
create or replace function public.unblock_day(p_day date)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  delete from public.blocked_days where day = p_day;
end $$;

revoke all on function public.get_blocked_days(date, date) from public;
revoke all on function public.admin_list_blocked_days() from public;
revoke all on function public.block_days(date, date, text) from public;
revoke all on function public.unblock_day(date) from public;
grant execute on function public.get_blocked_days(date, date) to anon, authenticated;
grant execute on function public.admin_list_blocked_days() to authenticated;
grant execute on function public.block_days(date, date, text) to authenticated;
grant execute on function public.unblock_day(date) to authenticated;

-- Server-side guard: new booking requests can't land on a blocked day.
create or replace function public.reject_blocked_booking()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.blocked_days where day = new.slot_date) then
    raise exception 'day_blocked';
  end if;
  return new;
end $$;

drop trigger if exists bookings_reject_blocked on public.bookings;
create trigger bookings_reject_blocked before insert on public.bookings
  for each row execute function public.reject_blocked_booking();

notify pgrst, 'reload schema';
