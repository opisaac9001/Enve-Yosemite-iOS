# Wording overlays

`tools/build_content.py` merges these files into the extracted factual records before writing the app packs. Each file is a JSON object keyed by record `id`; the value is an object of fields to replace. Only prose fields are rewritten here (summary, details, notice, sourceNote, accessibility, schedule, location, cost, registration, reaches, highlights, services, cautions, facts, notes). Factual fields (coordinates, hours strings, phone numbers, dates, URLs, source lists) stay with the extracted record so provenance is unchanged.

Files: `places.json`, `trails.json`, `campgrounds.json`, `permits.json`, `contacts.json`, `events.json`, `regions.json`, `webcams.json`, `documents.json`.

Run `python3 -I tools/build_content.py` after editing; the output reports how many records each overlay touched.
