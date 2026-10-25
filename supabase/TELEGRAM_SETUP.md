# Telegram quote alerts: setup

Every new quote request is sent to the owner's Telegram by the bot **@ezcustomz_bot** with three buttons:

- **✅ Send link**: approves the quote with the amounts on the card (the form's estimate and deposit), holds the day 48 hours and emails the customer the pay link. Same as "Approve and create deposit link" in the admin panel.
- **✏️ Change price**: the bot asks for a new price. Reply `1200 300` (total, deposit) or just `1200` to keep the deposit; you get a new card to confirm.
- **❌ Decline**: asks once more, then declines (restore it from the admin panel if needed).

Send **/pending** to the bot to get cards for every request still waiting. The admin panel keeps working as before; whichever you use first wins, and the other side says "Already handled".

Only the chat in `TELEGRAM_CHAT_ID` can use the buttons. Anyone else who finds the bot is ignored.

## Steps

1. **SQL**: Supabase Dashboard > SQL Editor > paste `supabase/telegram.sql` > Run (safe to re-run). It turns on `pg_net`, adds `bookings.tg_notified_at`, lets the service role pass `is_admin()`, and adds the trigger that pings the bot on each new booking.
2. **Function**: Edge Functions > Deploy a new function > name `telegram-bot`, paste `supabase/functions/telegram-bot/index.ts`, deploy, turn **off** "Enforce JWT verification". (CLI: `supabase functions deploy telegram-bot`.)
3. **Secrets** (Edge Functions > Secrets):
   - `TELEGRAM_BOT_TOKEN`: the token from BotFather.
   - `TELEGRAM_CHAT_ID`: `8314557213` (the owner's chat; find another with `https://api.telegram.org/bot<TOKEN>/getUpdates` after messaging the bot, before step 4).
4. **Webhook**: open this once in a browser (replace `<TOKEN>`; `<SECRET>` is the SHA-256 hex of `<TOKEN>:ez-hook`):
   `https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://umvdxjnhzehcoujrishh.supabase.co/functions/v1/telegram-bot&secret_token=<SECRET>&allowed_updates=["message","callback_query"]`
5. **Test**: message the bot (it replies), submit a test quote on the site, tap the buttons.

If the token ever leaks: BotFather > `/revoke`, put the new token in `TELEGRAM_BOT_TOKEN`, redo step 4.
