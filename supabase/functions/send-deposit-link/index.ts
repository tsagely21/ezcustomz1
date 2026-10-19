// POST { booking_id } with the admin's login token -> emails the customer their deposit pay link through Resend.
// Only works for a signed-in admin (checked with is_admin() as that user). Returns { error: 'not_configured' }
// when RESEND_API_KEY / RESEND_FROM aren't set, so the admin panel can fall back to FormSubmit.
// Secrets: RESEND_API_KEY, RESEND_FROM (e.g. "EZ CUSTOMZ <bookings@ezcustomz.co>"), optional OWNER_EMAIL, SITE_URL.
const SB_URL = Deno.env.get('SUPABASE_URL')!;
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY') ?? SB_KEY;
const RESEND = Deno.env.get('RESEND_API_KEY') ?? '';
const FROM = Deno.env.get('RESEND_FROM') ?? '';
const OWNER = Deno.env.get('OWNER_EMAIL') ?? 'hunteraucoin12@gmail.com';
const SITE = (Deno.env.get('SITE_URL') ?? 'https://ezcustomz.co').replace(/\/$/, '');

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type, apikey, authorization', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const out = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const usd = (c: number | null) => '$' + ((c ?? 0) / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const day = (d: string) => new Date(d + 'T12:00:00Z').toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' });
const when = (t: string) => new Date(t).toLocaleString('en-US', { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: 'America/Chicago' }) + ' Central';
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

async function rpc(fn: string, args: Record<string, unknown>, bearer: string, apikey = SB_KEY) {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey, Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
  return r.ok ? r.json() : null;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method !== 'POST') return out(405, { error: 'method_not_allowed' });
  const jwt = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!jwt || (await rpc('is_admin', {}, jwt, ANON)) !== true) return out(401, { error: 'not_admin' });
  if (!RESEND || !FROM) return out(503, { error: 'not_configured' });

  const { booking_id } = await req.json().catch(() => ({}));
  const b = typeof booking_id === 'string' ? await rpc('admin_booking_for_email', { p_id: booking_id }, SB_KEY) : null;
  if (!b || !b.email || !b.pay_token || b.status !== 'pending' || b.pay_status !== 'awaiting') return out(404, { error: 'not_found' });

  const link = `${SITE}/pay.html?t=${b.pay_token}`, first = String(b.name).split(' ')[0];
  const rows: [string, string][] = [...(b.vehicle ? [['Vehicle', b.vehicle] as [string, string]] : []), ['Service', b.service], ['Appointment date', day(b.slot_date)],
    ['Estimated total', usd(b.estimate_cents)], ['Deposit to lock in your date', usd(b.deposit_cents)]];
  const text = [`Hi ${first},`, '', 'Good news: your EZ CUSTOMZ quote is approved!', '', ...rows.map(([k, v]) => `${k}: ${v}`), '',
    "Pay your deposit securely here (you'll review our Deposit & Payment Terms first):", link, '',
    `We're holding your date until ${when(b.hold_until)}. After that it may be offered to someone else. The deposit comes out of your total.`, '',
    'Questions? Call or text 225.615.4554.', 'EZ CUSTOMZ, Baton Rouge, Louisiana'].join('\n');
  const html = `<div style="font-family:system-ui,sans-serif;max-width:560px;margin:auto;color:#1a1428"><div style="background:#0f0a20;color:#fff;padding:18px 22px;border-radius:12px 12px 0 0;font-weight:700;font-size:20px">EZ CUSTOMZ</div>
<div style="border:1px solid #e3dded;border-top:0;border-radius:0 0 12px 12px;padding:22px"><h2 style="margin:0 0 8px;color:#6d33b8">Your quote is approved</h2><p>Hi ${esc(first)}, here are the details:</p>
<table style="width:100%;border-collapse:collapse">${rows.map(([k, v]) => `<tr><td style="padding:6px 0;color:#6b6478">${esc(k)}</td><td style="padding:6px 0;text-align:right;font-weight:600">${esc(v)}</td></tr>`).join('')}</table>
<p style="text-align:center;margin:24px 0"><a href="${esc(link)}" style="background:#8f4fe0;color:#fff;text-decoration:none;font-weight:700;padding:14px 26px;border-radius:10px;display:inline-block">Pay ${esc(usd(b.deposit_cents))} deposit</a></p>
<p style="font-size:14px;color:#6b6478">You'll review our Deposit &amp; Payment Terms before paying. We're holding your date until ${esc(when(b.hold_until))}. The deposit comes out of your total.</p>
<p>Questions? Call or text 225.615.4554.</p></div></div>`;

  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST', headers: { Authorization: `Bearer ${RESEND}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: FROM, to: [b.email], bcc: [OWNER], reply_to: OWNER, subject: 'Your EZ CUSTOMZ quote is approved: pay your deposit', text, html }),
  });
  if (!r.ok) { const e = await r.json().catch(() => ({})); console.error('resend', r.status, e); return out(502, { error: 'send_failed', message: e?.message ?? `Resend HTTP ${r.status}` }); }
  return out(200, { ok: true });
});
