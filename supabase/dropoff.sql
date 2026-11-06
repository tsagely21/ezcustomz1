-- Drop-off time the owner sets with the deposit link; shown in the deposit-paid confirmation email.
alter table public.bookings add column if not exists dropoff_time time;

create or replace function public.admin_set_dropoff(p_id uuid, p_time time)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  update public.bookings set dropoff_time = p_time where id = p_id;
  if not found then raise exception 'not_found'; end if;
end $$;
revoke execute on function public.admin_set_dropoff(uuid, time) from anon, public;
grant execute on function public.admin_set_dropoff(uuid, time) to authenticated;
-- deposit_mark_paid (deposits.sql) returns dropoff_time; re-run it after this file.
