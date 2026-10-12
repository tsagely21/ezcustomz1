# EZ CUSTOMZ

Website and booking system for [EZ CUSTOMZ](https://ezcustomz.co), a custom vehicle interior shop in Baton Rouge, Louisiana specializing in starlight headliners, ambient lighting and speaker builds.

## Features

- **Instant quote builder**: pick a vehicle, services and options and see a live price estimate and deposit.
- **Booking calendar**: customers request a day; confirmed bookings and days off are greyed out automatically.
- **Admin panel** (`/admin.html`): accept, decline, cancel or delete requests, and block days off, behind a secure login.
- **Photo gallery**: swipeable carousel with a full-screen lightbox.
- **Seasonal promotions**: sale pricing with an automatic end date.
- **Accessible and responsive**: works on phones, supports light/dark mode and reduced motion.

## Tech stack

Plain HTML, CSS and JavaScript. No framework, no build step, no dependencies.

| Piece | Service |
|---|---|
| Hosting | GitHub Pages (custom domain via `CNAME`) |
| Database, auth, booking logic | [Supabase](https://supabase.com) (Postgres with row-level security and RPC functions) |
| Quote email fallback | [Formspree](https://formspree.io) |

## Project structure

```
index.html            Public site: quote form, calendar, gallery
admin.html            Private admin panel
supabase/               Database SQL and backend notes (see supabase/README.md)
images/gallery/       Gallery photos
assets/               Favicon and social share images
favicon.ico           Browser tab icon
CNAME                 Custom domain for GitHub Pages
CLAUDE.md             Codebase notes for AI coding assistants
```

## Running locally

No install needed. Open `index.html` in a browser, or serve the folder:

```
python -m http.server 8000
```

Then visit <http://localhost:8000>.

## Common edits

- **Gallery**: edit the `GALLERY` list at the top of the gallery script in `index.html`.
- **Sale**: change `SALE_OFF` and `SALE_END` in `index.html`.
- **Days off**: use the *Days off* tab in the admin panel. First-time setup: run `supabase/days_off.sql` in the Supabase SQL Editor.

## Deployment

Push to `main`. GitHub Pages publishes the site automatically.

## Security

The Supabase URL and publishable (anon) key in the HTML are public by design. Access is enforced in the database with row-level security and admin-only functions. Never commit a `service_role` key.
