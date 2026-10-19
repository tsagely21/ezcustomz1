-- Gallery managed from admin.html (Gallery tab): uploads go to the public Storage bucket "gallery",
-- one row per card in public.gallery_items. index.html and gallery.html read get_gallery().
-- Run in Supabase: SQL Editor > New query > paste this file > Run. Safe to run again.
--
-- place: 'home'    = homepage ribbon + gallery page
--        'gallery' = gallery page only
--        'hidden'  = taken down (kept so it can be put back)

create table if not exists public.gallery_items (
  id uuid primary key default gen_random_uuid(),
  label text not null check (length(label) between 1 and 60),
  note text check (length(note) <= 80),
  img text,                         -- big photo (null for videos)
  thumb text,                       -- card picture
  video text,                       -- .mp4 (null for photos)
  alt text,
  pos text,
  place text not null default 'home' check (place in ('home', 'gallery', 'hidden')),
  sort int not null default 0,
  paths text[] not null default '{}', -- Storage object names to delete with the card (empty for photos in the repo)
  created_at timestamptz not null default now(),
  check (img is not null or video is not null)
);
alter table public.gallery_items enable row level security;
revoke all on public.gallery_items from anon, authenticated;

-- First run only: copy in the photos that were hard-coded in index.html / gallery.html.
insert into public.gallery_items (label, note, img, thumb, video, alt, place, sort)
select * from (values
  ('550 Stars', 'Sedan', 'images/gallery/550-sedan.webp', null, null, null, 'home', 10),
  ('550 Stars', 'Mustang', 'images/gallery/550-mustang-interior.webp', 'images/gallery/550-mustang-interior-thumb.webp', null, '550 Stars Mustang starlight headliner installed', 'home', 20),
  ('550 Stars', 'Mustang', 'images/gallery/550-mustang-floor.webp', 'images/gallery/550-mustang-floor-thumb.webp', null, '550 Stars Mustang starlight headliner before install', 'home', 30),
  ('550 Stars', 'Mustang', null, 'images/gallery/550-mustang-thumb.jpg', 'images/gallery/550-mustang.mp4', null, 'home', 40),
  ('650 Stars', 'Sedan', 'images/gallery/650-sedan.webp', null, null, null, 'home', 50),
  ('650 Stars', 'Chevy 2009 LTZ', null, 'images/gallery/650-chevyltz-thumb.jpg', 'images/gallery/650chevyltz.mp4', null, 'home', 60),
  ('850 Stars', 'Sedan', 'images/gallery/850-sedan.webp', null, null, null, 'home', 70),
  ('850 Stars', 'Truck', 'images/gallery/850-truck.webp', null, null, null, 'home', 80),
  ('1000 Stars', 'Truck', 'images/gallery/1000-truck.webp', null, null, null, 'home', 90),
  ('1000 Stars', 'F250', null, 'images/gallery/1000-f250-thumb.jpg', 'images/gallery/1000-f250.mp4', null, 'home', 100),
  ('1000 Stars', '4Runner', 'images/gallery/1000-4runner.webp', null, null, null, 'home', 110),
  ('1000 Stars', 'Chevy Malibu', 'images/gallery/1000-malibu.webp', null, null, null, 'home', 120),
  ('1200 Stars', 'Truck', 'images/gallery/1200-truck.webp', null, null, null, 'home', 130),
  ('Panoramic Roof', '650 Stars', 'images/gallery/panoramic-roof.webp', null, null, null, 'home', 140),
  ('Starlight + Ambient', 'Truck', 'images/gallery/starlight-ambient.webp', null, null, null, 'gallery', 150)
) v where not exists (select 1 from public.gallery_items);

-- Storage: public reads, admin-only uploads/deletes. 50 MB per file (Supabase free plan max).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('gallery', 'gallery', true, 52428800, array['image/webp', 'image/jpeg', 'image/png', 'video/mp4'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "gallery admin insert" on storage.objects;
drop policy if exists "gallery admin select" on storage.objects;
drop policy if exists "gallery admin delete" on storage.objects;
create policy "gallery admin insert" on storage.objects for insert to authenticated with check (bucket_id = 'gallery' and public.is_admin());
create policy "gallery admin select" on storage.objects for select to authenticated using (bucket_id = 'gallery' and public.is_admin());
create policy "gallery admin delete" on storage.objects for delete to authenticated using (bucket_id = 'gallery' and public.is_admin());

-- Public: everything that isn't taken down, in order. The homepage keeps only place = 'home'.
create or replace function public.get_gallery()
returns table (label text, note text, img text, thumb text, video text, alt text, pos text, place text)
language sql stable security definer set search_path = public as $$
  select g.label, g.note, g.img, g.thumb, g.video, g.alt, g.pos, g.place
  from public.gallery_items g where g.place <> 'hidden' order by g.sort, g.created_at;
$$;

create or replace function public.admin_list_gallery()
returns setof public.gallery_items language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  return query select * from public.gallery_items order by sort, created_at;
end $$;

-- p_first: put it at the start of the ribbon/grid instead of the end.
create or replace function public.admin_add_gallery_item(p_label text, p_note text, p_img text, p_thumb text, p_video text,
  p_place text, p_paths text[], p_first boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  insert into public.gallery_items (label, note, img, thumb, video, place, paths, sort)
  values (trim(p_label), nullif(trim(coalesce(p_note, '')), ''), p_img, p_thumb, p_video, p_place, coalesce(p_paths, '{}'),
    case when p_first then coalesce((select min(sort) from public.gallery_items), 0) - 10
         else coalesce((select max(sort) from public.gallery_items), 0) + 10 end)
  returning id into new_id;
  return new_id;
end $$;

create or replace function public.admin_update_gallery_item(p_id uuid, p_label text, p_note text, p_place text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  update public.gallery_items set label = trim(p_label), note = nullif(trim(coalesce(p_note, '')), ''), place = p_place where id = p_id;
  if not found then raise exception 'not_found'; end if;
end $$;

-- Swap with the neighbour before (p_dir = -1) or after (p_dir = 1).
create or replace function public.admin_move_gallery_item(p_id uuid, p_dir int)
returns void language plpgsql security definer set search_path = public as $$
declare a public.gallery_items; b public.gallery_items;
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  select * into a from public.gallery_items where id = p_id;
  if not found then raise exception 'not_found'; end if;
  if p_dir < 0 then
    select * into b from public.gallery_items where (sort, created_at) < (a.sort, a.created_at) order by sort desc, created_at desc limit 1;
  else
    select * into b from public.gallery_items where (sort, created_at) > (a.sort, a.created_at) order by sort, created_at limit 1;
  end if;
  if not found then return; end if;
  if a.sort = b.sort then -- equal sorts: spread everything out first
    update public.gallery_items g set sort = r.n * 10 from (select id, row_number() over (order by sort, created_at) n from public.gallery_items) r where g.id = r.id;
    perform public.admin_move_gallery_item(p_id, p_dir);
    return;
  end if;
  update public.gallery_items set sort = b.sort where id = a.id;
  update public.gallery_items set sort = a.sort where id = b.id;
end $$;

-- Deletes the card; returns its Storage files so admin.html can remove them too.
create or replace function public.admin_delete_gallery_item(p_id uuid)
returns text[] language plpgsql security definer set search_path = public as $$
declare p text[];
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  delete from public.gallery_items where id = p_id returning paths into p;
  if not found then raise exception 'not_found'; end if;
  return p;
end $$;

revoke execute on function public.get_gallery() from public;
grant execute on function public.get_gallery() to anon, authenticated;
revoke execute on function public.admin_list_gallery() from anon, public;
revoke execute on function public.admin_add_gallery_item(text, text, text, text, text, text, text[], boolean) from anon, public;
revoke execute on function public.admin_update_gallery_item(uuid, text, text, text) from anon, public;
revoke execute on function public.admin_move_gallery_item(uuid, int) from anon, public;
revoke execute on function public.admin_delete_gallery_item(uuid) from anon, public;
grant execute on function public.admin_list_gallery() to authenticated;
grant execute on function public.admin_add_gallery_item(text, text, text, text, text, text, text[], boolean) to authenticated;
grant execute on function public.admin_update_gallery_item(uuid, text, text, text) to authenticated;
grant execute on function public.admin_move_gallery_item(uuid, int) to authenticated;
grant execute on function public.admin_delete_gallery_item(uuid) to authenticated;

notify pgrst, 'reload schema';
