# Stripe deposits: setup

Stays in **test mode** until you deliberately switch (step 8). Nothing here needs a secret key in the HTML or in this repo.

## How it fits together

- **GitHub Pages** keeps serving the site. It can't hold secrets, so the two pieces that talk to Stripe run as **Supabase Edge Functions** in the project you already use (`umvdxjnhzehcoujrishh`). No new hosting, no new database.
- `supabase/deposits.sql` adds the payment columns to `bookings`, plus `deposit_terms` (versioned terms), `deposit_agreements` (proof of acceptance + payment ledger) and `stripe_events` (duplicate protection).
- `supabase/functions/create-checkout`: called by `pay.html`. Re-checks the token, the hold, and that the customer ticked the box for the live terms version; saves the agreement; then creates the Stripe Checkout Session with the amount **from the database**.
- `supabase/functions/stripe-webhook`: the only thing that can confirm a booking. Verifies Stripe's signature, records the payment, marks the day booked, emails you and the customer.

## 1. Run the SQL

Supabase Dashboard > SQL Editor > New query > paste `supabase/deposits.sql` > Run. Safe to run again.

## 2. Stripe account

1. Sign in at dashboard.stripe.com. Keep the **Test mode / Sandbox** toggle on.
2. **Settings > Payment methods**: turn on Cards, Apple Pay, Google Pay. Turn **off** Bank (ACH), Klarna, Affirm, Cash App unless you want them (bank payments take days to clear, longer than a date hold).
3. **Settings > Business > Public details**: business name, support phone/email, statement descriptor (e.g. `EZ CUSTOMZ`).
4. **Developers > API keys**: copy the **Secret key** (`sk_test_...`). Don't paste it in chat, the HTML or git.

## 3. Deploy the two functions

Easiest (no install): Supabase Dashboard > **Edge Functions > Deploy a new function > Via editor**.

- Name `create-checkout`, paste `supabase/functions/create-checkout/index.ts`, deploy.
- Name `stripe-webhook`, paste `supabase/functions/stripe-webhook/index.ts`, deploy.
- For **both**: open the function > Details/Settings > turn **off "Enforce JWT verification"** (they have their own checks; Stripe can't send a Supabase login).

Or with the Supabase CLI: `supabase functions deploy create-checkout stripe-webhook` (uses `supabase/config.toml`).

## 4. Secrets

Supabase Dashboard > **Edge Functions > Secrets** (Project Settings > Edge Functions on some layouts). Add:

| Name | Value |
|---|---|
| `STRIPE_SECRET_KEY` | your `sk_test_...` key |
| `STRIPE_WEBHOOK_SECRET` | from step 5 (`whsec_...`) |
| `SITE_URL` | `https://ezcustomz.co` (default if unset) |
| `OWNER_EMAIL` | optional, defaults to `hunteraucoin12@gmail.com` |
| `RESEND_API_KEY`, `RESEND_FROM` | optional: branded customer emails via resend.com (verify ezcustomz.co there, e.g. `RESEND_FROM=EZ CUSTOMZ <bookings@ezcustomz.co>`). Without them the customer gets FormSubmit's plain-text autoresponse. |
| `STRIPE_ALLOW_LIVE` | leave **unset** until going live (live keys are refused without it) |
| `STRIPE_AUTOMATIC_TAX` | leave unset unless your accountant says deposits need sales tax and Stripe Tax is set up |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided to functions automatically.

## 5. Webhook

Stripe Dashboard > **Developers > Webhooks > Add endpoint**:

- URL: `https://umvdxjnhzehcoujrishh.supabase.co/functions/v1/stripe-webhook`
- Events: `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.expired`, `charge.refunded`
- Copy the **Signing secret** into `STRIPE_WEBHOOK_SECRET` (step 4).

## 6. Publish the terms

Admin panel > **Terms** tab. Version `v1` is a **draft** with your lawyer's three sections. Have them review it, edit if needed, then **Publish**. Until something is published, customers can't pay (the pay page says to call you).

## 7. Test (test mode)

1. Request a quote on the site for some day.
2. Admin > New requests > set total + deposit > **Approve and create deposit link**. Use **Preview** (or text it to yourself).
3. On the pay page: the button stays off until you tick the box. Pay with card `4242 4242 4242 4242`, any future date, any CVC/ZIP.
4. You land back on the pay page, which shows "Confirming…" then "Your appointment is confirmed" once the webhook arrives. Check: admin > Confirmed, Payments (proof + Stripe ID), the public calendar day greyed out, both emails received.
5. Also try: `4000 0000 0000 0002` (declined, booking stays unconfirmed), closing Checkout (cancel page, no charge), a refund in Stripe (shows in Payments, booking unchanged).
6. If something fails: Stripe > Webhooks > your endpoint shows each delivery and its response; Supabase > Edge Functions > Logs shows errors.

The first FormSubmit email to a new address triggers an activation email; click it once.

## 8. Going live (only when you decide)

1. Activate your Stripe account (business + bank details).
2. Switch the Dashboard to live, repeat steps 2 and 5 in live mode (live webhook has its own signing secret).
3. Update secrets: `STRIPE_SECRET_KEY=sk_live_...`, `STRIPE_WEBHOOK_SECRET=<live whsec>`, and `STRIPE_ALLOW_LIVE=true`.
4. Do one real small deposit and refund it.

To pause online payments any time, delete `STRIPE_ALLOW_LIVE` (live) or the secret key.
