// POST { token, accepted: true, terms_version } -> { url } of a Stripe Checkout Session for the deposit.
// The amount always comes from the database (set by the owner), never from the browser.
// Acceptance of the Deposit & Payment Terms is re-checked and recorded in the database before any session exists.
// Secrets (Supabase > Edge Functions > Secrets): STRIPE_SECRET_KEY, optional SITE_URL, STRIPE_ALLOW_LIVE, STRIPE_AUTOMATIC_TAX.
import Stripe from 'npm:stripe@22.6.2';

const KEY = Deno.env.get('STRIPE_SECRET_KEY') ?? '';
const SITE = (Deno.env.get('SITE_URL') ?? 'https://ezcustomz.co').replace(/\/$/, '');
const LIVE_OK = Deno.env.get('STRIPE_ALLOW_LIVE') === 'true';
const TAX = Deno.env.get('STRIPE_AUTOMATIC_TAX') === 'true';
const SB_URL = Deno.env.get('SUPABASE_URL')!;
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const stripe = new Stripe(KEY, { httpClient: Stripe.createFetchHttpClient() });

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type, apikey, authorization', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const out = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
  });
  const j = await r.json().catch(() => null);
  if (!r.ok) throw Object.assign(new Error(j?.message ?? 'db_error'), { code: j?.message ?? 'db_error' });
  return j;
}

// Errors the pay page knows how to explain. Anything else is a generic failure.
const KNOWN = new Set(['terms_not_accepted', 'terms_not_published', 'terms_changed', 'not_found', 'already_paid', 'link_expired', 'busy', 'live_disabled']);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method !== 'POST') return out(405, { error: 'method_not_allowed' });
  if (!KEY) return out(500, { error: 'not_configured' });
  if (KEY.startsWith('sk_live') && !LIVE_OK) return out(503, { error: 'live_disabled' });

  const { token, accepted, terms_version } = await req.json().catch(() => ({}));
  if (accepted !== true) return out(400, { error: 'terms_not_accepted' });
  if (typeof token !== 'string' || !/^[0-9a-f]{64}$/.test(token)) return out(404, { error: 'not_found' });

  let b;
  try {
    b = await rpc('deposit_checkout_begin', { p_token: token, p_accepted: true, p_terms_version: String(terms_version ?? ''), p_user_agent: req.headers.get('user-agent') });
  } catch (e) {
    const code = (e as { code?: string }).code ?? '';
    return out(KNOWN.has(code) ? 409 : 500, { error: KNOWN.has(code) ? code : 'server_error' });
  }

  try {
    let session: Stripe.Checkout.Session | null = null;
    if (b.session_id) {
      const s = await stripe.checkout.sessions.retrieve(b.session_id);
      if (s.status === 'complete') { await rpc('deposit_checkout_unlock', { p_booking_id: b.booking_id }); return out(409, { error: 'already_paid' }); }
      if (s.status === 'open' && s.amount_total === b.deposit_cents) session = s; // reuse: one open checkout per booking, no double charge
      else if (s.status === 'open') await stripe.checkout.sessions.expire(s.id); // owner changed the amount
    }
    const now = Math.floor(Date.now() / 1000);
    const hold = Math.floor(new Date(b.hold_until).getTime() / 1000);
    const expires = Math.max(now + 31 * 60, Math.min(hold, now + 23 * 3600)); // Stripe allows 30 min .. 24 h
    if (!session) {
      const day = new Date(b.slot_date + 'T12:00:00Z').toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' });
      const meta = { booking_id: b.booking_id, agreement_id: b.agreement_id, terms_version: b.terms_version };
      session = await stripe.checkout.sessions.create({
        mode: 'payment',
        // payment methods (cards, Apple Pay, Google Pay) come from Dashboard > Settings > Payment methods
        customer_email: b.email,
        client_reference_id: b.booking_id,
        line_items: [{ quantity: 1, price_data: { currency: 'usd', unit_amount: b.deposit_cents,
          product_data: { name: `EZ CUSTOMZ appointment deposit: ${b.service}`.slice(0, 250),
            description: `${b.vehicle ? b.vehicle + ' · ' : ''}${day}. Applied to your total. Nonrefundable except where required by law.`.slice(0, 500) } } }],
        metadata: meta,
        payment_intent_data: { metadata: meta, description: `EZ CUSTOMZ deposit, ${b.name}, ${b.slot_date}`.slice(0, 500) },
        custom_text: { submit: { message: `You accepted the EZ CUSTOMZ Deposit & Payment Terms (${b.terms_version}). Deposits are nonrefundable except where required by law and are credited toward your total.` } },
        ...(TAX ? { automatic_tax: { enabled: true } } : {}),
        expires_at: expires,
        success_url: `${SITE}/pay.html?t=${token}&s=done`,
        cancel_url: `${SITE}/pay.html?t=${token}&s=cancel`,
      }, { idempotencyKey: `ezdep-${b.agreement_id}` });
    }
    await rpc('deposit_checkout_attach', { p_booking_id: b.booking_id, p_agreement_id: b.agreement_id, p_session_id: session.id, p_expires_at: new Date((session.expires_at ?? expires) * 1000).toISOString() });
    return out(200, { url: session.url });
  } catch (e) {
    console.error('checkout failed', e);
    await rpc('deposit_checkout_unlock', { p_booking_id: b.booking_id }).catch(() => {});
    return out(502, { error: 'stripe_error' });
  }
});
