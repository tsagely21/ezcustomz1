-- Stripe deposits for EZ CUSTOMZ: payment fields on bookings, versioned Deposit & Payment Terms,
-- proof-of-agreement records, processed Stripe events, temporary date holds.
-- Run in Supabase: Dashboard > SQL Editor > New query > paste this file > Run. Safe to run again.
-- Needs days_off.sql to have been run first.
--
-- Flow: request (pending/none) -> owner approves + sets price and deposit (pending/awaiting, date held until hold_until)
--       -> customer accepts terms (agreement row) -> Stripe Checkout -> verified webhook -> approved/paid (day booked).
-- Stripe secret key and webhook secret live only in Edge Function secrets, never here or in the HTML.

-- ---------- bookings: payment columns ----------
alter table public.bookings
  add column if not exists estimate_cents int,
  add column if not exists deposit_cents int,
  add column if not exists pay_status text not null default 'none',
  add column if not exists pay_token text,
  add column if not exists hold_until timestamptz,
  add column if not exists link_sent_at timestamptz,
  add column if not exists checkout_session_id text,
  add column if not exists checkout_lock timestamptz,
  add column if not exists payment_intent_id text,
  add column if not exists deposit_paid_cents int,
  add column if not exists deposit_paid_at timestamptz,
  add column if not exists refunded_cents int not null default 0,
  add column if not exists stripe_livemode boolean,
  add column if not exists balance_paid_at timestamptz,
  add column if not exists pay_note text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'bookings_pay_status_chk') then
    alter table public.bookings add constraint bookings_pay_status_chk
      check (pay_status in ('none', 'awaiting', 'paid', 'partially_refunded', 'refunded', 'conflict'));
  end if;
end $$;
create unique index if not exists bookings_pay_token_key on public.bookings (pay_token) where pay_token is not null;

-- ---------- terms (versioned; published versions are never edited) ----------
create table if not exists public.deposit_terms (
  version text primary key check (version ~ '^[A-Za-z0-9._-]{1,40}$'),
  body text not null,
  checkbox text not null,
  status text not null default 'draft' check (status in ('draft', 'active', 'retired')),
  created_at timestamptz not null default now(),
  published_at timestamptz
);
create unique index if not exists deposit_terms_one_active on public.deposit_terms ((true)) where status = 'active';
alter table public.deposit_terms enable row level security;
revoke all on public.deposit_terms from anon, authenticated;

-- Seed: the three requirements from the owner's lawyer, as a DRAFT. Payments stay off until it is
-- reviewed and published from the admin Terms tab.
insert into public.deposit_terms (version, body, checkbox) values ('v1', $t$Please read these terms before paying your deposit.

## 1. All deposits are nonrefundable
All deposits paid to EZ Customz are nonrefundable. By submitting a deposit, you acknowledge and agree that the deposit is intended to reserve your appointment and secure your requested services. Deposits will be applied toward the total cost of the agreed-upon work. This policy is subject to any refund rights required by applicable law.

## 2. Estimates are subject to change
All estimates provided by EZ Customz are based on the information available at the time of the quote and are subject to change. Additional costs may arise from unforeseen vehicle conditions, existing modifications, installation complications, additional required materials or labor, or customer-requested changes. EZ Customz will notify the customer of proposed changes to the estimated price and obtain customer approval before performing additional work that increases the agreed-upon cost.

An estimate may be adjusted because of:
- Unexpected vehicle conditions discovered during installation.
- Existing damage or modifications that interfere with the requested work.
- Additional labor or materials required due to unforeseen complications.
- Customer-requested changes or additional customization.
- Vehicle-specific installation difficulties that could not reasonably be identified before work began.
- Necessary changes in materials or components, subject to customer approval.

## 3. Payment terms beyond the initial deposit
The deposit paid at the time of booking will be credited toward the total service cost. Any remaining balance will be due upon completion of the agreed-upon services and must be paid in full before the vehicle is released to the customer. Any approved additional services or price adjustments will be reflected in the final balance.$t$,
  $c$I have read, understand, and agree to EZ Customz's Deposit & Payment Terms, including the nonrefundable deposit policy, the possibility of changes to estimates, and my responsibility for the remaining balance.$c$)
on conflict (version) do nothing;

-- ---------- proof of agreement + payment ledger (kept even if a booking is deleted) ----------
create table if not exists public.deposit_agreements (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null,
  name text not null,
  email text not null,
  slot_date date,
  vehicle text,
  service text,
  deposit_cents int not null,
  estimate_cents int not null,
  terms_version text not null,
  terms_text text not null,
  checkbox_text text not null,
  accepted boolean not null check (accepted),
  accepted_at timestamptz not null default now(),
  user_agent text,
  status text not null default 'accepted' check (status in ('accepted', 'paid', 'expired', 'refunded', 'partially_refunded')),
  checkout_session_id text,
  payment_intent_id text,
  paid_cents int,
  paid_at timestamptz,
  refunded_cents int not null default 0,
  livemode boolean
);
create index if not exists deposit_agreements_session on public.deposit_agreements (checkout_session_id);
create index if not exists deposit_agreements_booking on public.deposit_agreements (booking_id);
alter table public.deposit_agreements enable row level security;
revoke all on public.deposit_agreements from anon, authenticated;

-- ---------- Stripe events already processed (webhook idempotency) ----------
create table if not exists public.stripe_events (
  id text primary key,
  type text not null,
  received_at timestamptz not null default now()
);
alter table public.stripe_events enable row level security;
revoke all on public.stripe_events from anon, authenticated;

-- ---------- helpers ----------
create or replace function public.day_held(p_day date, p_except uuid default null)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bookings b where b.slot_date = p_day and b.status = 'pending'
    and b.pay_status = 'awaiting' and b.hold_until > now() and b.id is distinct from p_except);
$$;
create or replace function public.lock_day(p_day date)
returns void language sql security definer set search_path = public as $$
  select pg_advisory_xact_lock(hashtext('ezday'), p_day - date '2000-01-01');
$$;
create or replace function public.vehicle_of(p_sel text)
returns text language sql immutable as $$ select nullif(trim(substring(coalesce(p_sel, '') from 'Vehicle: ([^\n]*)')), '') $$;

-- ---------- public ----------
-- Dates held for a customer who has a deposit link (no personal data). Shown as unavailable.
create or replace function public.get_held_days(from_date date, to_date date)
returns table(day date) language sql stable security definer set search_path = public as $$
  select distinct b.slot_date from public.bookings b
  where b.status = 'pending' and b.pay_status = 'awaiting' and b.hold_until > now()
    and b.slot_date between from_date and to_date order by 1;
$$;

create or replace function public.get_deposit_terms()
returns table(version text, body text, checkbox text, published_at timestamptz)
language sql stable security definer set search_path = public as $$
  select t.version, t.body, t.checkbox, t.published_at from public.deposit_terms t where t.status = 'active';
$$;

-- Pay page: what the customer holding this link needs to see. Nothing else about the booking.
create or replace function public.get_deposit_request(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'first_name', split_part(b.name, ' ', 1), 'slot_date', b.slot_date, 'service', b.service, 'vehicle', public.vehicle_of(b.selections),
    'estimate_cents', b.estimate_cents, 'deposit_cents', b.deposit_cents, 'deposit_paid_cents', b.deposit_paid_cents,
    'remaining_cents', b.estimate_cents - coalesce(b.deposit_paid_cents, 0) + b.refunded_cents,
    'status', b.status, 'pay_status', b.pay_status, 'hold_until', b.hold_until,
    'expired', b.pay_status = 'awaiting' and (b.hold_until is null or b.hold_until <= now()),
    'terms_version', (select a.terms_version from public.deposit_agreements a where a.booking_id = b.id and a.status = 'paid' order by a.paid_at desc limit 1))
  from public.bookings b where length(coalesce(p_token, '')) = 64 and b.pay_token = p_token;
$$;

-- New requests can't land on a day that is held for someone else's deposit.
create or replace function public.reject_held_booking()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.day_held(new.slot_date) then raise exception 'slot_taken'; end if;
  return new;
end $$;
drop trigger if exists bookings_reject_held on public.bookings;
create trigger bookings_reject_held before insert on public.bookings for each row execute function public.reject_held_booking();

-- No one else can be confirmed on a day held for a deposit (covers the admin "Confirm without deposit" button too).
create or replace function public.guard_held_approval()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' and public.day_held(new.slot_date, new.id) then
    raise exception 'slot_held';
  end if;
  return new;
end $$;
drop trigger if exists bookings_guard_held on public.bookings;
create trigger bookings_guard_held before update on public.bookings for each row execute function public.guard_held_approval();

-- Cancelling a confirmed booking does not reopen the day by itself: it goes to Days off, and the owner removes it to release it.
create or replace function public.keep_day_on_cancel()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'approved' and new.status = 'cancelled' and old.slot_date >= (now() at time zone 'America/Chicago')::date then
    insert into public.blocked_days(day, note) values (old.slot_date, left('Cancelled booking (' || old.name || '). Remove to reopen this day.', 200))
    on conflict (day) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists bookings_keep_day_on_cancel on public.bookings;
create trigger bookings_keep_day_on_cancel after update on public.bookings for each row execute function public.keep_day_on_cancel();

-- Pay right after submitting: the quote page calls this with the id create_booking_request just returned.
-- Standard deposit ($150 per service) computed here, never sent by the browser. The day is held for 2 hours.
-- Returns null (site falls back to "we'll review it") for speaker builds (no price yet), old/handled requests, or a taken day.
create or replace function public.start_instant_deposit(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.bookings; dep int; est int;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if not found or b.status <> 'pending' or b.pay_status <> 'none' or b.created_at < now() - interval '30 minutes' then return null; end if;
  if coalesce(b.service, '') = '' or b.service ~* 'speaker' then return null; end if;
  dep := 15000 * array_length(regexp_split_to_array(b.service, '\s*\+\s*'), 1);
  est := replace(substring(b.selections from 'Estimate: \$([0-9,]{1,9})'), ',', '')::int * 100;
  if est is null or est < dep or est > 10000000 then return null; end if;
  perform public.lock_day(b.slot_date);
  if exists (select 1 from public.bookings where slot_date = b.slot_date and status = 'approved')
     or exists (select 1 from public.blocked_days where day = b.slot_date)
     or public.day_held(b.slot_date, b.id) then return null; end if;
  update public.bookings set estimate_cents = est, deposit_cents = dep, pay_status = 'awaiting',
    hold_until = now() + interval '2 hours', link_sent_at = now(),
    pay_token = replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
  where id = b.id returning * into b;
  return jsonb_build_object('pay_token', b.pay_token, 'deposit_cents', dep, 'hold_until', b.hold_until);
end $$;

-- ---------- admin ----------
-- Approve a quote: set the price and deposit, hold the day, and get the customer's pay link token. Re-run to change amounts or extend the hold.
create or replace function public.admin_send_deposit_link(p_id uuid, p_estimate_cents int, p_deposit_cents int, p_hold_hours int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  if p_estimate_cents is null or p_estimate_cents < 100 or p_estimate_cents > 10000000 then raise exception 'bad_estimate'; end if;
  if p_deposit_cents is null or p_deposit_cents < 100 or p_deposit_cents > p_estimate_cents then raise exception 'bad_deposit'; end if;
  if p_hold_hours is null or p_hold_hours < 1 or p_hold_hours > 336 then raise exception 'bad_hold'; end if;
  select * into b from public.bookings where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if b.status <> 'pending' or b.pay_status not in ('none', 'awaiting') then raise exception 'not_pending'; end if;
  perform public.lock_day(b.slot_date);
  if exists (select 1 from public.bookings where slot_date = b.slot_date and status = 'approved') then raise exception 'slot_taken'; end if;
  if exists (select 1 from public.blocked_days where day = b.slot_date) then raise exception 'day_blocked'; end if;
  if public.day_held(b.slot_date, b.id) then raise exception 'slot_held'; end if;
  update public.bookings set estimate_cents = p_estimate_cents, deposit_cents = p_deposit_cents, pay_status = 'awaiting',
    hold_until = now() + make_interval(hours => p_hold_hours), link_sent_at = now(),
    pay_token = coalesce(pay_token, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
  where id = p_id returning * into b;
  return jsonb_build_object('pay_token', b.pay_token, 'hold_until', b.hold_until);
end $$;

-- Stop waiting for a deposit: the day is released and the pay link stops working.
create or replace function public.admin_release_hold(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  update public.bookings set pay_status = 'none', hold_until = null, pay_token = null, checkout_session_id = null
  where id = p_id and status = 'pending' and pay_status = 'awaiting';
  if not found then raise exception 'not_pending'; end if;
end $$;

-- Price adjustment (approved by the customer) after the deposit: remaining balance follows.
create or replace function public.admin_set_estimate(p_id uuid, p_estimate_cents int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  if p_estimate_cents is null or p_estimate_cents < 100 or p_estimate_cents > 10000000 then raise exception 'bad_estimate'; end if;
  update public.bookings set estimate_cents = p_estimate_cents where id = p_id and pay_status <> 'awaiting';
  if not found then raise exception 'not_found'; end if;
end $$;

create or replace function public.admin_set_balance_paid(p_id uuid, p_paid boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  update public.bookings set balance_paid_at = case when p_paid then now() end where id = p_id;
  if not found then raise exception 'not_found'; end if;
end $$;

-- Move a confirmed booking (or a paid-but-conflicted one) to another free day. The old day goes to Days off for the owner to release.
create or replace function public.admin_reschedule(p_id uuid, p_date date)
returns void language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  select * into b from public.bookings where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if not (b.status = 'approved' or b.pay_status = 'conflict') then raise exception 'not_approved'; end if;
  if p_date is null or p_date <= (now() at time zone 'America/Chicago')::date then raise exception 'invalid_date'; end if;
  if p_date = b.slot_date and b.status = 'approved' then return; end if;
  perform public.lock_day(p_date);
  if exists (select 1 from public.bookings where slot_date = p_date and status = 'approved' and id <> p_id) then raise exception 'slot_taken'; end if;
  if exists (select 1 from public.blocked_days where day = p_date) then raise exception 'day_blocked'; end if;
  if public.day_held(p_date, p_id) then raise exception 'slot_held'; end if;
  if b.status = 'approved' and b.slot_date >= (now() at time zone 'America/Chicago')::date then
    insert into public.blocked_days(day, note) values (b.slot_date, left('Rescheduled booking (' || b.name || '). Remove to reopen this day.', 200))
    on conflict (day) do nothing;
  end if;
  update public.bookings set slot_date = p_date, status = 'approved', decided_at = coalesce(decided_at, now()),
    pay_status = case when pay_status = 'conflict' then 'paid' else pay_status end
  where id = p_id;
end $$;

create or replace function public.admin_list_agreements()
returns setof public.deposit_agreements language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  return query select * from public.deposit_agreements order by accepted_at desc limit 500;
end $$;

create or replace function public.admin_list_terms()
returns setof public.deposit_terms language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  return query select * from public.deposit_terms order by created_at desc;
end $$;

-- Save a draft (new version name, or edit an existing draft). Published versions can't be changed.
create or replace function public.admin_save_terms(p_version text, p_body text, p_checkbox text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  if coalesce(p_version, '') !~ '^[A-Za-z0-9._-]{1,40}$' then raise exception 'bad_version'; end if;
  if length(trim(coalesce(p_body, ''))) < 50 or length(p_body) > 20000 or length(trim(coalesce(p_checkbox, ''))) < 20 or length(p_checkbox) > 1000 then
    raise exception 'invalid_input';
  end if;
  insert into public.deposit_terms (version, body, checkbox) values (p_version, trim(p_body), trim(p_checkbox))
  on conflict (version) do update set body = excluded.body, checkbox = excluded.checkbox where deposit_terms.status = 'draft';
  if not found then raise exception 'terms_locked'; end if;
end $$;

create or replace function public.admin_publish_terms(p_version text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  if not exists (select 1 from public.deposit_terms where version = p_version and status = 'draft') then raise exception 'not_found'; end if;
  update public.deposit_terms set status = 'retired' where status = 'active';
  update public.deposit_terms set status = 'active', published_at = now() where version = p_version;
end $$;

-- ---------- server only (Edge Functions, service_role) ----------
-- Customer ticked the box and pressed Pay: re-check everything, record the agreement, take a short checkout lock.
create or replace function public.deposit_checkout_begin(p_token text, p_accepted boolean, p_terms_version text, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.bookings; t public.deposit_terms; aid uuid;
begin
  if p_accepted is not true then raise exception 'terms_not_accepted'; end if;
  select * into t from public.deposit_terms where status = 'active';
  if not found then raise exception 'terms_not_published'; end if;
  if p_terms_version is distinct from t.version then raise exception 'terms_changed'; end if;
  select * into b from public.bookings where length(coalesce(p_token, '')) = 64 and pay_token = p_token for update;
  if not found then raise exception 'not_found'; end if;
  if b.pay_status in ('paid', 'partially_refunded', 'refunded', 'conflict') then raise exception 'already_paid'; end if;
  if b.status <> 'pending' or b.pay_status <> 'awaiting' then raise exception 'not_found'; end if;
  if b.hold_until is null or b.hold_until <= now() then raise exception 'link_expired'; end if;
  if b.deposit_cents is null or b.estimate_cents is null then raise exception 'not_found'; end if;
  if b.checkout_lock > now() - interval '30 seconds' then raise exception 'busy'; end if;
  update public.bookings set checkout_lock = now() where id = b.id;
  insert into public.deposit_agreements (booking_id, name, email, slot_date, vehicle, service, deposit_cents, estimate_cents,
      terms_version, terms_text, checkbox_text, accepted, user_agent)
    values (b.id, b.name, b.email, b.slot_date, public.vehicle_of(b.selections), b.service, b.deposit_cents, b.estimate_cents,
      t.version, t.body, t.checkbox, true, left(p_user_agent, 300))
    returning id into aid;
  return jsonb_build_object('booking_id', b.id, 'agreement_id', aid, 'name', b.name, 'email', b.email, 'slot_date', b.slot_date,
    'service', b.service, 'vehicle', public.vehicle_of(b.selections), 'deposit_cents', b.deposit_cents, 'estimate_cents', b.estimate_cents,
    'hold_until', b.hold_until, 'session_id', b.checkout_session_id, 'terms_version', t.version);
end $$;

create or replace function public.deposit_checkout_attach(p_booking_id uuid, p_agreement_id uuid, p_session_id text, p_expires_at timestamptz)
returns void language sql security definer set search_path = public as $$
  update public.deposit_agreements set checkout_session_id = p_session_id where id = p_agreement_id;
  update public.bookings set checkout_session_id = p_session_id, checkout_lock = null,
    hold_until = greatest(hold_until, p_expires_at) where id = p_booking_id and pay_status = 'awaiting';
$$;

create or replace function public.deposit_checkout_unlock(p_booking_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.bookings set checkout_lock = null where id = p_booking_id;
$$;

-- Verified checkout.session.completed with payment_status = paid. One transaction: event row + booking + agreement.
-- result: confirmed (send emails) | duplicate (already handled) | conflict (paid but not confirmed, owner must act).
create or replace function public.deposit_mark_paid(p_event_id text, p_session_id text, p_payment_intent text,
  p_amount_cents int, p_booking_id uuid, p_livemode boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.bookings; reason text; a public.deposit_agreements;
begin
  insert into public.stripe_events (id, type) values (p_event_id, 'checkout.session.completed') on conflict do nothing;
  if not found then return jsonb_build_object('result', 'duplicate'); end if;

  -- Every Pay click records an acceptance; the latest one before payment is the one tied to the money.
  select * into a from public.deposit_agreements where checkout_session_id = p_session_id order by accepted_at desc limit 1;
  update public.deposit_agreements set status = 'paid', payment_intent_id = p_payment_intent, paid_cents = p_amount_cents,
    paid_at = now(), livemode = p_livemode where id = a.id;

  select * into b from public.bookings where id = p_booking_id for update;
  if not found then
    return jsonb_build_object('result', 'conflict', 'reason', 'Booking was deleted before the payment arrived.', 'session_id', p_session_id,
      'payment_intent', p_payment_intent, 'amount_cents', p_amount_cents, 'name', a.name, 'email', a.email, 'slot_date', a.slot_date);
  end if;
  if b.payment_intent_id = p_payment_intent then return jsonb_build_object('result', 'duplicate'); end if;

  perform public.lock_day(b.slot_date);
  if b.pay_status <> 'awaiting' or b.status <> 'pending' then
    reason := case when b.payment_intent_id is not null then 'A second deposit was paid for a booking that was already paid. Refund one of them in Stripe.'
                   else 'The deposit link had been released or the booking was no longer pending.' end;
  elsif a.id is null then reason := 'No agreement on file for this checkout session.';
  elsif exists (select 1 from public.bookings where slot_date = b.slot_date and status = 'approved' and id <> b.id) then reason := 'Another booking is already confirmed for that day.';
  elsif exists (select 1 from public.blocked_days where day = b.slot_date) then reason := 'That day was marked as a day off.';
  elsif public.day_held(b.slot_date, b.id) then reason := 'That day is held for another customer.';
  end if;

  if reason is null then
    update public.bookings set status = 'approved', decided_at = now(), pay_status = 'paid', deposit_paid_cents = p_amount_cents,
      deposit_paid_at = now(), payment_intent_id = p_payment_intent, checkout_session_id = p_session_id, stripe_livemode = p_livemode,
      hold_until = null, checkout_lock = null
    where id = b.id returning * into b;
  elsif b.payment_intent_id is null then
    update public.bookings set pay_status = 'conflict', deposit_paid_cents = p_amount_cents, deposit_paid_at = now(),
      payment_intent_id = p_payment_intent, checkout_session_id = p_session_id, stripe_livemode = p_livemode, hold_until = null, pay_note = reason
    where id = b.id returning * into b;
  end if;

  return jsonb_build_object('result', case when reason is null then 'confirmed' else 'conflict' end, 'reason', reason,
    'booking_id', b.id, 'name', b.name, 'email', b.email, 'phone', b.phone, 'slot_date', b.slot_date, 'service', b.service,
    'vehicle', public.vehicle_of(b.selections), 'estimate_cents', b.estimate_cents, 'deposit_paid_cents', p_amount_cents,
    'remaining_cents', b.estimate_cents - p_amount_cents, 'terms_version', a.terms_version, 'accepted_at', a.accepted_at,
    'payment_intent', p_payment_intent, 'session_id', p_session_id, 'pay_token', b.pay_token);
end $$;

create or replace function public.deposit_mark_expired(p_event_id text, p_session_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.stripe_events (id, type) values (p_event_id, 'checkout.session.expired') on conflict do nothing;
  update public.deposit_agreements set status = 'expired' where checkout_session_id = p_session_id and status = 'accepted';
  update public.bookings set checkout_session_id = null where checkout_session_id = p_session_id and pay_status = 'awaiting';
end $$;

-- charge.refunded: record the refunded total. Booking status and the calendar are left alone (owner decides).
create or replace function public.deposit_mark_refund(p_event_id text, p_payment_intent text, p_refunded_cents int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  insert into public.stripe_events (id, type) values (p_event_id, 'charge.refunded') on conflict do nothing;
  if not found then return jsonb_build_object('result', 'duplicate'); end if;
  update public.deposit_agreements set refunded_cents = p_refunded_cents,
    status = case when p_refunded_cents >= coalesce(paid_cents, 0) then 'refunded' else 'partially_refunded' end
  where payment_intent_id = p_payment_intent and status in ('paid', 'refunded', 'partially_refunded');
  update public.bookings set refunded_cents = p_refunded_cents,
    pay_status = case when pay_status = 'conflict' then 'conflict' when p_refunded_cents >= coalesce(deposit_paid_cents, 0) then 'refunded' else 'partially_refunded' end
  where payment_intent_id = p_payment_intent returning * into b;
  return jsonb_build_object('result', 'ok', 'name', b.name, 'email', b.email, 'slot_date', b.slot_date, 'status', b.status,
    'deposit_paid_cents', b.deposit_paid_cents, 'refunded_cents', p_refunded_cents, 'payment_intent', p_payment_intent);
end $$;

-- ---------- grants ----------
revoke execute on function public.day_held(date, uuid) from anon, authenticated, public;
revoke execute on function public.lock_day(date) from anon, authenticated, public;
revoke execute on function public.reject_held_booking() from anon, authenticated, public;
revoke execute on function public.guard_held_approval() from anon, authenticated, public;
revoke execute on function public.keep_day_on_cancel() from anon, authenticated, public;

revoke execute on function public.get_held_days(date, date) from public;
revoke execute on function public.get_deposit_terms() from public;
revoke execute on function public.get_deposit_request(text) from public;
grant execute on function public.get_held_days(date, date) to anon, authenticated;
grant execute on function public.get_deposit_terms() to anon, authenticated;
grant execute on function public.get_deposit_request(text) to anon, authenticated;
revoke execute on function public.start_instant_deposit(uuid) from public;
grant execute on function public.start_instant_deposit(uuid) to anon, authenticated;

revoke execute on function public.admin_send_deposit_link(uuid, int, int, int) from anon, public;
revoke execute on function public.admin_release_hold(uuid) from anon, public;
revoke execute on function public.admin_set_estimate(uuid, int) from anon, public;
revoke execute on function public.admin_set_balance_paid(uuid, boolean) from anon, public;
revoke execute on function public.admin_reschedule(uuid, date) from anon, public;
revoke execute on function public.admin_list_agreements() from anon, public;
revoke execute on function public.admin_list_terms() from anon, public;
revoke execute on function public.admin_save_terms(text, text, text) from anon, public;
revoke execute on function public.admin_publish_terms(text) from anon, public;
grant execute on function public.admin_send_deposit_link(uuid, int, int, int) to authenticated;
grant execute on function public.admin_release_hold(uuid) to authenticated;
grant execute on function public.admin_set_estimate(uuid, int) to authenticated;
grant execute on function public.admin_set_balance_paid(uuid, boolean) to authenticated;
grant execute on function public.admin_reschedule(uuid, date) to authenticated;
grant execute on function public.admin_list_agreements() to authenticated;
grant execute on function public.admin_list_terms() to authenticated;
grant execute on function public.admin_save_terms(text, text, text) to authenticated;
grant execute on function public.admin_publish_terms(text) to authenticated;

revoke execute on function public.deposit_checkout_begin(text, boolean, text, text) from anon, authenticated, public;
revoke execute on function public.deposit_checkout_attach(uuid, uuid, text, timestamptz) from anon, authenticated, public;
revoke execute on function public.deposit_checkout_unlock(uuid) from anon, authenticated, public;
revoke execute on function public.deposit_mark_paid(text, text, text, int, uuid, boolean) from anon, authenticated, public;
revoke execute on function public.deposit_mark_expired(text, text) from anon, authenticated, public;
revoke execute on function public.deposit_mark_refund(text, text, int) from anon, authenticated, public;
grant execute on function public.deposit_checkout_begin(text, boolean, text, text) to service_role;
grant execute on function public.deposit_checkout_attach(uuid, uuid, text, timestamptz) to service_role;
grant execute on function public.deposit_checkout_unlock(uuid) to service_role;
grant execute on function public.deposit_mark_paid(text, text, text, int, uuid, boolean) to service_role;
grant execute on function public.deposit_mark_expired(text, text) to service_role;
grant execute on function public.deposit_mark_refund(text, text, int) to service_role;

notify pgrst, 'reload schema';
