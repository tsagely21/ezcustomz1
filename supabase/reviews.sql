-- Customer reviews for reviews.html, moderated from admin.html (Reviews tab).
-- Run in Supabase: Dashboard > SQL Editor > New query > paste this file > Run. Safe to run again.
--
-- New reviews start as 'pending' and only show on the site once approved in the admin panel.
-- Statuses: pending, approved, rejected.

create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  vehicle text,
  rating smallint not null check (rating between 1 and 5),
  comment text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
-- upgrades an earlier version of this file (had a "hidden" flag and published immediately)
alter table public.reviews add column if not exists status text not null default 'pending'
  check (status in ('pending', 'approved', 'rejected'));
alter table public.reviews add column if not exists decided_at timestamptz;
alter table public.reviews drop column if exists hidden;

alter table public.reviews enable row level security;
revoke all on public.reviews from anon, authenticated;

-- Public: approved reviews only, newest first.
create or replace function public.get_reviews()
returns table (name text, vehicle text, rating smallint, comment text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select r.name, r.vehicle, r.rating, r.comment, r.created_at
  from public.reviews r where r.status = 'approved'
  order by r.created_at desc limit 200;
$$;

-- Public submit: lands as pending. Length limits and a site-wide spam cap.
create or replace function public.submit_review(p_name text, p_rating int, p_comment text, p_vehicle text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  new_id uuid;
  v_name text := trim(coalesce(p_name, ''));
  v_comment text := trim(coalesce(p_comment, ''));
  v_vehicle text := nullif(trim(coalesce(p_vehicle, '')), '');
begin
  if v_name = '' or length(v_name) > 60
     or length(v_comment) < 3 or length(v_comment) > 1500
     or length(coalesce(v_vehicle, '')) > 80
     or p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'invalid_input';
  end if;

  if (select count(*) from public.reviews where created_at > now() - interval '1 hour') >= 15
     or (select count(*) from public.reviews where status = 'pending') >= 100 then
    raise exception 'too_many_requests';
  end if;

  insert into public.reviews (name, vehicle, rating, comment)
  values (v_name, v_vehicle, p_rating, v_comment)
  returning id into new_id;
  return new_id;
end $$;

-- Admin: list reviews by status ('pending', 'approved', 'rejected').
create or replace function public.admin_list_reviews(p_status text)
returns setof public.reviews language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  return query select * from public.reviews where status = p_status order by created_at desc;
end $$;

-- Admin: approve (show on site) or reject (keep but hide).
create or replace function public.set_review_status(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  if p_status not in ('approved', 'rejected') then raise exception 'invalid_input'; end if;
  update public.reviews set status = p_status, decided_at = now() where id = p_id;
  if not found then raise exception 'not_found'; end if;
end $$;

-- Admin: delete for good.
create or replace function public.delete_review(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  delete from public.reviews where id = p_id;
  if not found then raise exception 'not_found'; end if;
end $$;

revoke execute on function public.get_reviews() from public;
revoke execute on function public.submit_review(text, int, text, text) from public;
grant execute on function public.get_reviews() to anon, authenticated;
grant execute on function public.submit_review(text, int, text, text) to anon, authenticated;

revoke execute on function public.admin_list_reviews(text) from anon, public;
revoke execute on function public.set_review_status(uuid, text) from anon, public;
revoke execute on function public.delete_review(uuid) from anon, public;
grant execute on function public.admin_list_reviews(text) to authenticated;
grant execute on function public.set_review_status(uuid, text) to authenticated;
grant execute on function public.delete_review(uuid) to authenticated;

notify pgrst, 'reload schema';
