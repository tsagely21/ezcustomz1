// Telegram bot for the owner: new quote requests arrive as messages with buttons
//   ✅ Send link  -> admin_send_deposit_link (48 h hold) + send-deposit-link email, same as the admin panel
//   ✏️ Change price -> owner replies "1200 300" (total, deposit), gets a new card to confirm
//   ❌ Decline -> asks again, then decline_booking
// Two kinds of POST: { new_booking: id } from the bookings insert trigger (telegram.sql), and Telegram updates
// (checked with the X-Telegram-Bot-Api-Secret-Token header). Cards go to TELEGRAM_CHAT_ID (a private chat or a group);
// only users in TELEGRAM_ADMIN_IDS (comma-separated, default = TELEGRAM_CHAT_ID) can act, and only inside that chat.
// /id (anyone, any chat) replies with the chat and user ids, for setup.
// Secrets: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, optional TELEGRAM_ADMIN_IDS, SITE_URL. Setup in supabase/TELEGRAM_SETUP.md.
const SB_URL = Deno.env.get('SUPABASE_URL')!;
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const TOKEN = Deno.env.get('TELEGRAM_BOT_TOKEN') ?? '';
const CHAT = Deno.env.get('TELEGRAM_CHAT_ID') ?? '';
const ADMINS = (Deno.env.get('TELEGRAM_ADMIN_IDS') || CHAT).split(',').map((s) => s.trim()).filter(Boolean);
const SITE = (Deno.env.get('SITE_URL') ?? 'https://ezcustomz.co').replace(/\/$/, '');
const HOLD_HOURS = 48;

const ok = () => new Response('ok');
const usd = (c: number | null) => '$' + ((c ?? 0) / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const day = (d: string) => new Date(d + 'T12:00:00Z').toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' });
const when = (t: string) => new Date(t).toLocaleString('en-US', { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: 'America/Chicago' }) + ' Central';
const esc = (s: unknown) => String(s ?? '').replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]!));
const cents = (s: string | undefined) => { const n = parseFloat(String(s ?? '').replace(/[$,\s]/g, '')); return isFinite(n) ? Math.round(n * 100) : null; };
const fromSel = (sel: string, re: RegExp) => cents((sel.match(re) ?? [])[1]);
const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, isId = (s: unknown) => typeof s === 'string' && new RegExp(`^${UUID.source}$`).test(s);
const ERR: Record<string, string> = {
  not_pending: 'Already handled (maybe in the admin panel).', slot_taken: 'That day is already confirmed for someone else.',
  slot_held: 'That day is held for another customer with a deposit link.', day_blocked: 'That day is marked as a day off.',
  bad_estimate: 'The total must be between $1 and $100,000.', bad_deposit: 'The deposit must be at least $1 and no more than the total.', not_found: 'Booking not found.',
};

// Webhook secret derived from the bot token, so there's one less secret to manage.
async function hookSecret() {
  const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(TOKEN + ':ez-hook'));
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function tg(method: string, body: Record<string, unknown>) {
  const r = await fetch(`https://api.telegram.org/bot${TOKEN}/${method}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const j = await r.json().catch(() => ({}));
  if (!j.ok) console.error('telegram', method, j);
  return j;
}
async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
  const j = await r.json().catch(() => null);
  return r.ok ? { data: j, err: '' } : { data: null, err: String(j?.message ?? `HTTP ${r.status}`) };
}
async function booking(id: string, claim = false) {
  const q = `${SB_URL}/rest/v1/bookings?id=eq.${id}` + (claim ? '&status=eq.pending&tg_notified_at=is.null' : '');
  const r = await fetch(q, { method: claim ? 'PATCH' : 'GET', headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json', Prefer: 'return=representation' },
    body: claim ? JSON.stringify({ tg_notified_at: new Date().toISOString() }) : undefined });
  const rows = r.ok ? await r.json() : [];
  return rows[0] ?? null;
}

const who = (b: any) => { const veh = (String(b.selections ?? '').match(/^Vehicle: (.*)$/m) ?? [])[1];
  return [`<b>${esc(b.name)}</b>`, `📅 ${esc(day(b.slot_date))}`, ...(veh ? [`🚗 ${esc(veh)}`] : []), `🛠 ${esc(b.service)}`, `📞 ${esc(b.phone)}`, `✉️ ${esc(b.email)}`].join('\n'); };
// The quote card. est/dep default to what the customer's form calculated.
function card(b: any, est: number | null, dep: number | null, title = '🆕 <b>New quote request</b>') {
  const text = [title, '', who(b), '', `<blockquote expandable>${esc(b.selections)}</blockquote>`, '',
    `💵 Total: <b>${est != null ? usd(est) : 'not calculated'}</b>`, `💳 Deposit: <b>${dep != null ? usd(dep) : '—'}</b>`, '',
    est != null && dep != null ? `Send ${esc(b.name.split(' ')[0])} the deposit link with these amounts?` : 'Set a price to send the deposit link.'].join('\n');
  const amt = `${est ?? ''}:${dep ?? ''}`, row1 = est != null && dep != null ? [[{ text: `✅ Send link (${usd(dep)} deposit)`, callback_data: `ok:${b.id}:${amt}` }]] : [];
  return { text, parse_mode: 'HTML', reply_markup: { inline_keyboard: [...row1, [{ text: '✏️ Change price', callback_data: `ch:${b.id}` }, { text: '❌ Decline', callback_data: `no:${b.id}:${amt}` }]] } };
}
const defaults = (b: any) => [fromSel(String(b.selections ?? ''), /Estimate: \$([\d,.]+)/), fromSel(String(b.selections ?? ''), /Deposit to schedule: \$([\d,.]+)/)] as const;
const pendingNow = (b: any) => b && b.status === 'pending' && b.pay_status === 'none';

// Replace a card (and its buttons) with the customer summary plus a result line, signed with who tapped (for groups).
async function settle(m: any, b: any, line: string, buttons: unknown[][] = []) {
  await tg('editMessageText', { chat_id: CHAT, message_id: m.message_id, text: (b ? `${who(b)}\n\n` : '') + line + (m.by ?? ''), parse_mode: 'HTML', link_preview_options: { is_disabled: true },
    reply_markup: { inline_keyboard: buttons } });
}

async function sendLink(m: any, b: any, est: number, dep: number) {
  const id = b.id, r = await rpc('admin_send_deposit_link', { p_id: id, p_estimate_cents: est, p_deposit_cents: dep, p_hold_hours: HOLD_HOURS });
  if (r.err) return tg('sendMessage', { chat_id: CHAT, reply_to_message_id: m.message_id, text: `⚠️ Couldn't create the link: ${ERR[r.err] ?? r.err}` });
  const link = `${SITE}/pay.html?t=${r.data.pay_token}`;
  // Same email the admin panel sends (Resend). The service key counts as admin (telegram.sql).
  const e = await fetch(`${SB_URL}/functions/v1/send-deposit-link`, { method: 'POST', headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ booking_id: id }) });
  const ej = await e.json().catch(() => ({}));
  const mail = e.ok && ej.ok ? `📧 Emailed to ${esc(b.email)}.` : `⚠️ The email didn't go through (${esc(ej.message ?? ej.error ?? `HTTP ${e.status}`)}). Text or email them the link below.`;
  // Telegram buttons only open web links, so text.html hands the message to the phone's Messages app (sent from your own number).
  const sms = `Hi ${String(b.name).split(' ')[0]}, your EZ CUSTOMZ quote is approved! Estimated total ${usd(est)}. To lock in ${day(b.slot_date)}, please review our deposit terms and pay your ${usd(dep)} deposit here: ${link} . We're holding the date until ${when(r.data.hold_until)}.`;
  const textIt = `${SITE}/text.html#` + new URLSearchParams({ p: String(b.phone ?? ''), b: sms });
  await settle(m, b, `✅ <b>Deposit link created</b>: total ${usd(est)}, deposit ${usd(dep)}. Day held until ${esc(when(r.data.hold_until))}.\n${mail}\n🔗 ${esc(link)}`,
    [[{ text: '📱 Text it from my phone', url: textIt }]]);
}

async function onCallback(q: any) {
  await tg('answerCallbackQuery', { callback_query_id: q.id });
  const m = q.message, [act, id, a, d] = String(q.data ?? '').split(':');
  if (!m || !isId(id)) return;
  if (q.from?.first_name) m.by = ` (by ${esc(q.from.first_name)})`;
  const b = await booking(id), amt = (s: string) => (/^\d+$/.test(s ?? '') ? +s : null);
  if (!pendingNow(b)) return settle(m, b, `ℹ️ ${b ? ERR.not_pending : ERR.not_found}`);
  if (act === 'ok') return sendLink(m, b, +a, +d);
  if (act === 'ch') return tg('sendMessage', { chat_id: CHAT, parse_mode: 'HTML', reply_markup: { force_reply: true, input_field_placeholder: 'e.g. 1200 300' },
    text: `✏️ New price for <b>${esc(b.name)}</b> (${esc(day(b.slot_date))}).\nReply to this message with the total and the deposit, like <code>1200 300</code>. Send just the total to keep the ${usd(defaults(b)[1] ?? 15000)} deposit.\nRef: ${b.id}` });
  if (act === 'no') return tg('editMessageReplyMarkup', { chat_id: CHAT, message_id: m.message_id,
    reply_markup: { inline_keyboard: [[{ text: '❌ Yes, decline it', callback_data: `nx:${id}` }, { text: '↩️ Back', callback_data: `bk:${id}:${a ?? ''}:${d ?? ''}` }]] } });
  if (act === 'bk') return tg('editMessageReplyMarkup', { chat_id: CHAT, message_id: m.message_id, reply_markup: card(b, amt(a), amt(d)).reply_markup });
  if (act === 'nx') { const r = await rpc('decline_booking', { p_id: id }); return settle(m, b, r.err ? `⚠️ ${ERR[r.err] ?? r.err}` : '❌ <b>Declined.</b> You can restore it from the admin panel if needed.'); }
}

async function onMessage(m: any) {
  const ref = String(m.reply_to_message?.text ?? '').match(new RegExp('Ref: (' + UUID.source + ')'));
  if (ref) {
    const b = await booking(ref[1]);
    if (!pendingNow(b)) return tg('sendMessage', { chat_id: CHAT, text: `ℹ️ ${b ? ERR.not_pending : ERR.not_found}` });
    const [est, dep0] = String(m.text ?? '').replace(/[$,]/g, '').match(/\d+(\.\d+)?/g) ?? [];
    const e = cents(est), d = dep0 ? cents(dep0) : defaults(b)[1];
    if (!(e && e >= 100 && e <= 1e7)) return tg('sendMessage', { chat_id: CHAT, text: `⚠️ ${ERR.bad_estimate} Tap ✏️ Change price again.` });
    if (!(d && d >= 100 && d <= e)) return tg('sendMessage', { chat_id: CHAT, text: `⚠️ ${ERR.bad_deposit} Tap ✏️ Change price again.` });
    return tg('sendMessage', { chat_id: CHAT, ...card(b, e, d, '✏️ <b>Updated price</b>') });
  }
  if (/^\/pending/.test(m.text ?? '')) { // re-send cards for every request still waiting on a decision
    const r = await fetch(`${SB_URL}/rest/v1/bookings?status=eq.pending&pay_status=eq.none&order=created_at.asc`, { headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` } });
    const rows = r.ok ? await r.json() : [];
    if (!rows.length) return tg('sendMessage', { chat_id: CHAT, text: 'No new requests waiting. 👍' });
    for (const b of rows) { const [e, d] = defaults(b); await tg('sendMessage', { chat_id: CHAT, ...card(b, e, d, '⏳ <b>Waiting for your review</b>') }); }
    return;
  }
  if (!/^\//.test(m.text ?? '')) return; // in a group, stay out of normal conversation
  return tg('sendMessage', { chat_id: CHAT, text: "Hi! I'll message you here whenever a new quote request comes in. Send /pending to see requests still waiting." });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST' || !TOKEN || !CHAT) return new Response('not configured', { status: req.method === 'POST' ? 503 : 405 });
  const body = await req.json().catch(() => ({}));
  // From the bookings trigger: announce once (the claim only succeeds the first time, for a pending request).
  if ('new_booking' in body) {
    if (!isId(body.new_booking)) return ok();
    const b = await booking(body.new_booking, true);
    if (b) { const [e, d] = defaults(b); await tg('sendMessage', { chat_id: CHAT, ...card(b, e, d) }); }
    return ok();
  }
  if (req.headers.get('x-telegram-bot-api-secret-token') !== await hookSecret()) return new Response('forbidden', { status: 403 });
  const u = body.callback_query ?? body.message, from = String(u?.from?.id ?? ''), chat = String(body.callback_query?.message?.chat?.id ?? body.message?.chat?.id ?? '');
  if (body.message && /^\/id\b/.test(body.message.text ?? '')) {
    await tg('sendMessage', { chat_id: chat, reply_to_message_id: body.message.message_id, parse_mode: 'HTML', text: `Chat ID: <code>${esc(chat)}</code>\nYour user ID: <code>${esc(from)}</code>` });
    return ok();
  }
  if (chat !== CHAT || !ADMINS.includes(from)) return ok(); // strangers, and other chats, are ignored
  try {
    if (body.callback_query) await onCallback(body.callback_query);
    else if (body.message) await onMessage(body.message);
  } catch (x) { console.error(x); }
  return ok(); // always 200 so Telegram doesn't retry
});
