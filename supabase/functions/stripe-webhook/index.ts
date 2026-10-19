// Stripe webhook. Only a signature-verified event can confirm a booking.
// Events: checkout.session.completed, checkout.session.async_payment_succeeded, checkout.session.expired, charge.refunded.
// Idempotent: each event id is stored once (stripe_events) in the same transaction as the booking update.
// Secrets: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, optional OWNER_EMAIL, SITE_URL, RESEND_API_KEY + RESEND_FROM.
import Stripe from 'npm:stripe@22.6.2';

// Only used for signature checks (no API calls), so a placeholder keeps the function booting if the key secret is missing.
const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY') || 'sk_unset', { httpClient: Stripe.createFetchHttpClient() });
const WH = Deno.env.get('STRIPE_WEBHOOK_SECRET') ?? '';
const SITE = (Deno.env.get('SITE_URL') ?? 'https://ezcustomz.co').replace(/\/$/, '');
const OWNER = Deno.env.get('OWNER_EMAIL') ?? 'hunteraucoin12@gmail.com';
const RESEND = Deno.env.get('RESEND_API_KEY') ?? '';
const RESEND_FROM = Deno.env.get('RESEND_FROM') ?? '';
const SB_URL = Deno.env.get('SUPABASE_URL')!;
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const crypto = Stripe.createSubtleCryptoProvider();

async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  const j = await r.json().catch(() => null);
  if (!r.ok) throw new Error(`${fn}: ${j?.message ?? r.status}`);
  return j;
}

const usd = (c: number | null | undefined) => '$' + ((c ?? 0) / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const day = (d: string) => new Date(d + 'T12:00:00Z').toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' });
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

// Owner notification through the site's existing FormSubmit inbox. Without Resend, FormSubmit's autoresponse
// (sent to the "email" field) carries the customer's confirmation.
async function formsubmit(fields: Record<string, string>) {
  const r = await fetch(`https://formsubmit.co/ajax/${OWNER}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json', Origin: SITE, Referer: SITE + '/' },
    body: JSON.stringify({ _template: 'table', _captcha: 'false', ...fields }),
  });
  if (!r.ok) console.error('formsubmit', r.status, await r.text().catch(() => ''));
}

async function resend(to: string, subject: string, text: string, html: string) {
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${RESEND}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: RESEND_FROM, to: [to], reply_to: OWNER, subject, text, html }),
  });
  if (!r.ok) console.error('resend', r.status, await r.text().catch(() => ''));
  return r.ok;
}

// deno-lint-ignore no-explicit-any
async function confirmed(p: any) {
  const rows: [string, string][] = [
    ['Customer', p.name], ['Vehicle', p.vehicle ?? 'See your quote'], ['Service', p.service], ['Appointment date', day(p.slot_date)],
    ['Estimated total', usd(p.estimate_cents)], ['Deposit paid', usd(p.deposit_paid_cents)], ['Estimated remaining balance', usd(p.remaining_cents)],
  ];
  const terms = `${SITE}/terms.html`, status = `${SITE}/pay.html?t=${p.pay_token}`;
  const text = [`EZ CUSTOMZ: your appointment is confirmed`, '', `Hi ${p.name},`, '', `Your deposit was received and your appointment is confirmed. Here are the details:`, '',
    ...rows.map(([k, v]) => `${k}: ${v}`), '',
    `You accepted the EZ CUSTOMZ Deposit & Payment Terms (version ${p.terms_version}) on ${new Date(p.accepted_at).toLocaleString('en-US', { timeZone: 'America/Chicago' })} Central.`,
    `Deposits are nonrefundable except where required by law and are credited toward your total. The remaining balance is due when the work is complete, before the vehicle is released. The estimate can change only as described in the terms, and we will ask for your approval before any additional work that increases the price.`,
    `Full terms: ${terms}`, `Your booking: ${status}`, '', 'Questions? Call or text 225.615.4554.', 'EZ CUSTOMZ, Baton Rouge, Louisiana'].join('\n');

  let customerSent = false;
  if (RESEND && RESEND_FROM && p.email) {
    const html = `<div style="font-family:system-ui,sans-serif;max-width:560px;margin:auto;color:#1a1428"><div style="background:#0f0a20;color:#fff;padding:18px 22px;border-radius:12px 12px 0 0;font-weight:700;font-size:20px">EZ CUSTOMZ</div>
<div style="border:1px solid #e3dded;border-top:0;border-radius:0 0 12px 12px;padding:22px"><h2 style="margin:0 0 8px;color:#6d33b8">Your appointment is confirmed</h2><p>Hi ${esc(p.name)}, your deposit was received. Here are the details:</p>
<table style="width:100%;border-collapse:collapse">${rows.map(([k, v]) => `<tr><td style="padding:6px 0;color:#6b6478">${esc(k)}</td><td style="padding:6px 0;text-align:right;font-weight:600">${esc(v)}</td></tr>`).join('')}</table>
<p style="font-size:14px;color:#6b6478">You accepted the EZ CUSTOMZ Deposit &amp; Payment Terms (version ${esc(p.terms_version)}). Deposits are nonrefundable except where required by law and are credited toward your total. The remaining balance is due when the work is complete, before the vehicle is released.</p>
<p><a href="${esc(terms)}" style="color:#6d33b8">Read the full Deposit &amp; Payment Terms</a> · <a href="${esc(status)}" style="color:#6d33b8">View your booking</a></p><p>Questions? Call or text 225.615.4554.</p></div></div>`;
    customerSent = await resend(p.email, 'Your EZ CUSTOMZ appointment is confirmed', text, html);
  }
  await formsubmit({
    _subject: `Deposit paid: ${p.name}, ${day(p.slot_date)}`,
    Status: 'Confirmed, deposit paid. The day is now booked on the calendar.',
    name: p.name, email: p.email, Phone: p.phone ?? '', Vehicle: p.vehicle ?? '', Service: p.service, 'Appointment date': day(p.slot_date),
    'Estimated total': usd(p.estimate_cents), 'Deposit paid': usd(p.deposit_paid_cents), 'Remaining balance': usd(p.remaining_cents),
    'Terms accepted': `${p.terms_version} at ${p.accepted_at}`, 'Stripe payment': p.payment_intent,
    ...(customerSent ? {} : { _autoresponse: text }),
  });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  if (!WH) { console.error('STRIPE_WEBHOOK_SECRET is not set'); return new Response('not configured', { status: 500 }); }
  const body = await req.text();
  let ev: Stripe.Event;
  try {
    ev = await stripe.webhooks.constructEventAsync(body, req.headers.get('stripe-signature') ?? '', WH, undefined, crypto);
  } catch (e) {
    console.error('bad signature', (e as Error).message);
    return new Response('invalid signature', { status: 400 });
  }

  try {
    if (ev.type === 'checkout.session.completed' || ev.type === 'checkout.session.async_payment_succeeded') {
      const s = ev.data.object as Stripe.Checkout.Session;
      if (s.metadata?.booking_id && s.payment_status === 'paid') {
        const r = await rpc('deposit_mark_paid', { p_event_id: ev.id, p_session_id: s.id, p_payment_intent: String(s.payment_intent ?? ''),
          p_amount_cents: s.amount_total, p_booking_id: s.metadata.booking_id, p_livemode: ev.livemode });
        if (r.result === 'confirmed') await confirmed(r).catch((e) => console.error('email', e));
        if (r.result === 'conflict') await formsubmit({ _subject: `ACTION NEEDED: deposit paid but booking not confirmed (${r.name ?? 'unknown'})`,
          Problem: r.reason, name: r.name ?? '', Customer_email: r.email ?? '', 'Appointment date': r.slot_date ?? '', 'Amount paid': usd(s.amount_total),
          'Stripe payment': String(s.payment_intent ?? ''), 'What to do': 'Open the admin panel (Awaiting deposit tab) to reschedule, or refund the payment in the Stripe Dashboard.' }).catch(() => {});
      }
    } else if (ev.type === 'checkout.session.expired') {
      await rpc('deposit_mark_expired', { p_event_id: ev.id, p_session_id: (ev.data.object as Stripe.Checkout.Session).id });
    } else if (ev.type === 'charge.refunded') {
      const ch = ev.data.object as Stripe.Charge;
      const r = await rpc('deposit_mark_refund', { p_event_id: ev.id, p_payment_intent: String(ch.payment_intent ?? ''), p_refunded_cents: ch.amount_refunded });
      if (r.result === 'ok' && r.name) await formsubmit({ _subject: `Deposit refunded: ${r.name}`, name: r.name, Customer_email: r.email ?? '',
        'Appointment date': r.slot_date ?? '', 'Deposit paid': usd(r.deposit_paid_cents), 'Refunded so far': usd(r.refunded_cents),
        Note: 'The booking and calendar were not changed. Cancel it in the admin panel if the appointment is off.' }).catch(() => {});
    }
  } catch (e) {
    console.error('webhook failed', ev.type, ev.id, e);
    return new Response('retry', { status: 500 }); // nothing was committed, Stripe will retry
  }
  return new Response(JSON.stringify({ received: true }), { headers: { 'Content-Type': 'application/json' } });
});
