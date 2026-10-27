# index.html (public homepage)

Single file (~115 KB): CSS, SVG sprites, markup, JS all inline. Inline `<script>` blocks, in order:

1. **Gallery**: managed from admin > Gallery. On `DOMContentLoaded` fetches `get_gallery`, keeps `place='home'`, calls `galShow()`. The `GALLERY` array is only the fallback if Supabase fails (`label`, `note`, `img`, optional `thumb`/`video`/`alt`/`pos`); keep it in the admin "Numeric order" (see [admin.md](admin.md)). Rest is carousel + lightbox. Section is `hidden` until it has items.
2. **Quote form** (`#qf`): vehicle year/make/model, services (starlight / ambient / speaker), pricing, date, contact.
   - `D` = makes/models string; each model ends in a size code (`s` sedan, `u`, `t` truck, `x` SUV, `c` coupe) mapped to base price via `R`. `rec()` recommends a star count. Every make's list ends in `OTH` ("Other / not listed"); that or make `Other` shows free-text `#xmk`/`#xmd` (required when shown, via `vo()`). Optional `#vtr` trim. `veh()` builds the "Vehicle:" line (admin's `vehicle_of()` parses it).
   - `sync()` recomputes estimate, deposit ($150 per service) and summary chips on any change. `need()` / `flag()` validate (`NM` = field labels).
   - Submit: POSTs Supabase RPC `create_booking_request`, then also FormSubmit.co (`FORMSPREE` const, AJAX). Success if either works; if both fail, SMS / email / copy fallback buttons.
   - Option wording changes must also go into SQL `materials_for()` (see [backend.md](backend.md)).
3. **Calendar**: `cal()` month grid, max one year out; disabled = past/today, Sundays, `BLOCKED`, or `taken`. `loadTaken()` fills `taken` from `get_taken_days` + `get_blocked_days`. Fails silently offline.
4. **Hero film** (`#hv` `<video>`): 24 s loop `images/hero/hero-1280.mp4` (phones: `hero-854.mp4` via `<source media>`), poster `hero-poster.webp` also the `.hero` background. Plays only on screen; skipped for `prefers-reduced-motion` and Save-Data. Rendered offline in Python/OpenCV (renderer not in repo).
   - **Revert to pre-hero-film site:** tag `pre-hero-video` / branch `backup-before-hero-video` (`93cc3cf`): `git checkout pre-hero-video -- index.html`, commit, push.
5. **Quote backdrop** (`#qsky` canvas in sticky `.qbg`): twinkling stars drifting with scroll, shooting star every 6-13 s, speaker-ring glows on wide screens. Pauses off screen; static frame for reduced motion.

**Halloween decor** (remove after 2026-10-31; sale pricing was already removed 2026-10-15): `i-pumpkin`/`i-web`/`i-skull`... `<symbol>`s, the `.dc` decor elements, and the second `:root{--org...}` CSS block, in index, reviews and gallery.

**Styling**: CSS custom properties on `:root`, dark mode via `prefers-color-scheme` + `data-theme` override. Breakpoints 900px / 600px. `reviews.html` and `gallery.html` copy this CSS/sprites/header, so shared look changes go in all three.
