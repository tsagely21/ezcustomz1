-- Materials: a master shopping list of parts for jobs with a paid deposit (admin > Materials tab).
-- One row per item per job; admin.html groups rows by item ("650 starlight kit x2") and the owner checks them off once ordered.
-- Rows are added automatically when a booking's deposit is paid (trigger below) and can also be added by hand.
-- Idempotent: safe to re-run in the Supabase SQL Editor.

create table if not exists public.materials (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid references public.bookings(id) on delete cascade, -- null = general stock, not for one job
  item text not null check (length(item) between 1 and 120),
  qty int not null default 1 check (qty between 1 and 99),
  auto boolean not null default false,  -- true = generated from the quote, false = added by hand
  ordered_at timestamptz,                -- null = still to order
  created_at timestamptz not null default now()
);
create index if not exists materials_booking_idx on public.materials (booking_id);
alter table public.materials enable row level security;
revoke all on public.materials from anon, authenticated;

-- What a quote needs, read from the summary lines index.html writes into bookings.selections.
create or replace function public.materials_for(p_service text, p_sel text)
returns table (item text) language sql immutable set search_path = public as $$
  select x from (values
    (case when p_sel !~ 'Customer supplies kit' then substring(p_sel from '(?:^|\n)Starlights: (\d+) stars') || ' starlight kit' end),
    (case when substring(p_sel from '(?:^|\n)Upgrades: ([^\n]*)') ilike '%suede wrap%' then 'Suede wrap' end),
    (case when substring(p_sel from '(?:^|\n)Upgrades: ([^\n]*)') ilike '%shooting stars%' then 'Shooting star kit' end),
    (case when p_sel ~ '(^|\n)Standard sunroof with LED strips' then 'Sunroof LED strips (standard)'
          when p_sel ~ '(^|\n)Panoramic sunroof with LED strips' then 'Sunroof LED strips (panoramic)' end),
    (case when coalesce(p_service, '') ilike '%ambient lighting%' then 'Ambient lighting kit' end),
    -- "Speakers: Speaker box (Center console)" -> "Speaker box: Center console"
    (left(regexp_replace(substring(p_sel from '(?:^|\n)Speakers: ([^\n]*)'), '^(Speaker \w+) \((.*)\)$', '\1: \2'), 120)),
    (case when p_sel ~ '(^|\n)Custom logo: yes' then 'Custom logo' end)
  ) v(x) where x is not null;
$$;

create or replace function public.materials_add_for_booking(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.materials where booking_id = p_id and auto) then return; end if;
  insert into public.materials (booking_id, item, auto)
  select b.id, m.item, true from public.bookings b, public.materials_for(b.service, b.selections) m where b.id = p_id;
end $$;

-- Deposit paid -> add that job's materials. Never lets a materials problem block the payment from confirming.
create or replace function public.materials_on_paid()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.pay_status = 'paid' and old.pay_status is distinct from 'paid' then
    begin
      perform public.materials_add_for_booking(new.id);
    exception when others then
      raise warning 'materials_on_paid(%): %', new.id, sqlerrm;
    end;
  end if;
  return null;
end $$;
drop trigger if exists bookings_materials on public.bookings;
create trigger bookings_materials after update of pay_status on public.bookings
  for each row execute function public.materials_on_paid();

-- Backfill jobs that were already paid before this existed (skips any that already have materials).
select public.materials_add_for_booking(id) from public.bookings where status = 'approved' and pay_status = 'paid';

-- Rows for confirmed jobs and general stock. Ordered rows drop off once the job date has passed
-- (general stock: 30 days after ordering), so the list stays about upcoming work.
create or replace function public.admin_list_materials()
returns table (id uuid, item text, qty int, auto boolean, ordered_at timestamptz, booking_id uuid, slot_date date, name text, vehicle text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  return query
    select m.id, m.item, m.qty, m.auto, m.ordered_at, m.booking_id, b.slot_date, b.name, substring(b.selections from '(?:^|\n)Vehicle: ([^\n]*)')
    from public.materials m left join public.bookings b on b.id = m.booking_id
    where (m.booking_id is null or b.status = 'approved')
      and (m.ordered_at is null or (b.id is not null and b.slot_date >= current_date) or (b.id is null and m.ordered_at > now() - interval '30 days'))
    order by m.item, b.slot_date nulls last, m.created_at;
end $$;

create or replace function public.admin_set_materials_ordered(p_ids uuid[], p_ordered boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  update public.materials set ordered_at = case when p_ordered then coalesce(ordered_at, now()) end where id = any(p_ids);
end $$;

create or replace function public.admin_add_material(p_item text, p_qty int, p_booking uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  if length(trim(coalesce(p_item, ''))) not between 1 and 120 then raise exception 'bad_item'; end if;
  if p_qty is null or p_qty not between 1 and 99 then raise exception 'bad_qty'; end if;
  if p_booking is not null and not exists (select 1 from public.bookings where id = p_booking) then raise exception 'not_found'; end if;
  insert into public.materials (booking_id, item, qty) values (p_booking, trim(p_item), p_qty) returning id into new_id;
  return new_id;
end $$;

create or replace function public.admin_delete_material(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  delete from public.materials where id = p_id;
  if not found then raise exception 'not_found'; end if;
end $$;

revoke execute on function public.materials_for(text, text) from anon, authenticated, public;
revoke execute on function public.materials_add_for_booking(uuid) from anon, authenticated, public;
revoke execute on function public.materials_on_paid() from anon, authenticated, public;
revoke execute on function public.admin_list_materials() from anon, public;
revoke execute on function public.admin_set_materials_ordered(uuid[], boolean) from anon, public;
revoke execute on function public.admin_add_material(text, int, uuid) from anon, public;
revoke execute on function public.admin_delete_material(uuid) from anon, public;
grant execute on function public.admin_list_materials() to authenticated;
grant execute on function public.admin_set_materials_ordered(uuid[], boolean) to authenticated;
grant execute on function public.admin_add_material(text, int, uuid) to authenticated;
grant execute on function public.admin_delete_material(uuid) to authenticated;

notify pgrst, 'reload schema';
