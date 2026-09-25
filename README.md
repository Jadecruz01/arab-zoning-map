# City of Arab — Zoning & Property Map

Replacement for the Greenstone map at localgreenstone.com/arabal. One static page (`index.html`), hosted on GitHub Pages like the permit checker.

## What's in it
- Search as you type: address, owner, PPIN, parcel number, annexation name/application #, plus place names.
- Tap a parcel: zoning district with plain-English description, PPIN, parcel #, acreage, value, mailing address, coordinates, copy link, directions.
- Layers: light / streets / aerial / USGS topo (contours) base maps, zoning (per-district toggles + opacity), parcel lines, house numbers, city limits, FEMA flood zones, gas lines, annexations.
- Tools: measure distance or area (ft / mi / sq ft / acres), drop a pin, my location, shareable links (`#p-<PPIN>`, `#a-<id>`).
- Annexations tab: every tracked petition with a 6-step tracker: Received → Staff review → PC hearing → PC recommends → Council vote → Council approved.
- Staff dashboard (Staff button, or `#staff`): overview + pipeline, properties table (add / edit / delete / export CSV), parcel data import, Google Sheet feed settings. Logins still to be added — right now it's an open "Open dashboard" gate.

## Go-live checklist
1. **Parcel data** — ask Greenstone (or Marshall County) for the parcel/zoning layer as GeoJSON in WGS84 (EPSG:4326), or a shapefile and convert it at mapshaper.org. Save as `data/parcels.geojson`. Same for `data/city-limits.geojson` and `data/gas-lines.geojson`. Until these exist the map shows sample parcels. The Greenstone field names (ZONE, PARCELNUMB, OWNER, PROPPIN, PROPADDR, PROPVALUE, ACREAGE, MAILADD1…) are read as-is.
2. **Google Sheet feed** — follow the steps at the top of `apps-script.gs`, then put the /exec URL and key in `CONFIG.SHEET_API` / `CONFIG.SHEET_KEY` near the top of the script in `index.html`.
3. **Permit site hook** — when an annexation application is submitted, POST `{key, action:"upsert", row:{id, kind:"annexation", name, address, ppin, status:"submitted", application_no, submitted_date, source:"permit-site"}}` to the same /exec URL. When the Planning Commission recommends it, POST `{key, action:"upsert", row:{id, status:"approved", pc_date, pc_vote:"Recommended approval, 5–0"}}`. When it goes on the Council agenda, send `{id, status:"council", council_date}`. When the City Council approves, send `{id, status:"annexed", council_vote:"Approved 5–0", decision_date, ordinance_no}`. The map refreshes every 60 seconds.
4. **Before sharing publicly** — add staff logins (the write key is visible in page source until then; anyone with it could edit the sheet).

Statuses: submitted · review · pc_scheduled · approved (PC recommended) · council (on Council agenda) · annexed (Council approved) · denied · withdrawn

New sheet columns in this version: pc_vote, council_date, council_vote (after pc_date).
