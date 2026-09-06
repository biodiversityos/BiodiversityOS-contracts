#!/usr/bin/env python3
"""Convert the Cozumel shark field database into registry-ready JSON.

The spreadsheet carries more than the registry stores, and some of the surplus
is personal data. Anything written here lands on a public chain permanently, so
observer names and private media links are dropped unless explicitly asked for.

Usage:
    python3 prepare_data.py <workbook.xlsx> -o sightings.json [--privacy MODE]

Privacy modes:
    redact  (default) strip personal names and URLs from the free-text comment
    drop              omit the comment field entirely
    raw               publish observations verbatim  -- names and links included
"""
import argparse, json, re, sys, unicodedata
from classify_behavior import classify
from collections import Counter
from datetime import datetime, timezone, timedelta

# Cozumel is UTC-5 year round. Field notes record only a part of day, so each
# record is pinned to a representative local hour and converted to UTC. Without
# this a midnight-UTC timestamp would render as the previous day locally.
TZ = timezone(timedelta(hours=-5))
HOUR_BY_PART_OF_DAY = {"am": 9, "pm": 15, "noche": 21}

SPECIES_BY_COMMON_NAME = {
    "nurse shark":            "nurse_shark",
    "caribbean reef shark":   "caribbean_reef_shark",
    "great hammerhead shark": "great_hammerhead_shark",
    "hammerhead shark":       "hammerhead_shark",
    "scalloped hammerhead":   "scalloped_hammerhead_shark",
    "bull shark":             "bull_shark",
    "tiger shark":            "tiger_shark",
    "whale shark":            "whale_shark",
    "sandbar shark":          "sandbar_shark",
}

COL = {
    "id": 1, "year": 2, "month": 3, "day": 4,
    "lat": 8, "lon": 9, "observer": 12, "species_en": 14,
    "scientific": 17, "count": 18, "part_of_day": 19,
    "site_official": 7, "observations": 23, "depth_ft": 25,
    "size_class": 26, "media": 28,
}

URL_RE = re.compile(r"(https?://\S+|www\.\S+)", re.I)
# The media column mixes prose with links; only the link is machine-usable.
MEDIA_URL_RE = re.compile(r"https?://\S+", re.I)


def text(value):
    return "" if value is None else str(value).strip()


def as_int(value):
    """Parse ints that the spreadsheet stores inconsistently as int or string."""
    s = text(value)
    if not s or s.upper() == "NA":
        return None
    try:
        return int(float(s))
    except ValueError:
        return None


def normalize(s):
    s = unicodedata.normalize("NFKD", s.lower())
    return "".join(c for c in s if not unicodedata.combining(c))


def observed_at(row):
    """Unix seconds, or 0 when the field date is genuinely unknown."""
    year, month, day = (as_int(row[COL[k]]) for k in ("year", "month", "day"))
    if not year or not month or not day:
        return 0
    hour = HOUR_BY_PART_OF_DAY.get(normalize(text(row[COL["part_of_day"]])), 12)
    try:
        return int(datetime(year, month, day, hour, tzinfo=TZ).timestamp())
    except ValueError:
        return 0


def build_name_vocabulary(rows):
    """Personal names to redact, harvested from the observer column itself."""
    names = set()
    org_markers = ("divers", "dollar", "dive", "shop", "boat", "scuba", "tours")
    for row in rows:
        for token in re.split(r"[,/&]| y | con | and ", normalize(text(row[COL["observer"]]))):
            token = token.strip()
            if len(token) > 3 and not any(m in token for m in org_markers):
                names.add(token)
    return names


def redact(comment, names):
    out = URL_RE.sub("[link removed]", comment)
    for name in sorted(names, key=len, reverse=True):
        out = re.sub(rf"\b{re.escape(name)}\b", "[name removed]", out, flags=re.I)
    # Collapse runs of adjacent redactions left by "nadia y carlos".
    out = re.sub(r"(\[name removed\][\s,y/&]*)+", "[name removed] ", out)
    return re.sub(r"\s{2,}", " ", out).strip()


def convert(path, privacy):
    import openpyxl
    rows = list(openpyxl.load_workbook(path, data_only=True)["merged"].iter_rows(values_only=True))
    rows = [r for r in rows[1:] if any(v is not None for v in r)]
    names = build_name_vocabulary(rows)

    sightings, stats = [], Counter()
    for row in rows:
        common = normalize(text(row[COL["species_en"]]))
        species = SPECIES_BY_COMMON_NAME.get(common)
        if species is None:
            species = "unknown"
            stats[f"unmapped species: {common!r}"] += 1

        comment = text(row[COL["observations"]])
        if privacy == "drop":
            comment = ""
        elif privacy == "redact":
            comment = redact(comment, names)

        # These point at Drive folders and social posts rather than image files,
        # so consumers must treat mediaUrl as "a link to media", not an <img src>.
        media_match = MEDIA_URL_RE.search(text(row[COL["media"]]))
        media_url = media_match.group(0).rstrip(".,;") if media_match else ""
        if privacy == "drop":
            media_url = ""

        # Behaviour comes from the original note, not the redacted one: redaction
        # removes names and links, and must not change what the record says.
        behavior, _ = classify(text(row[COL["observations"]]))
        if behavior != "unknown":
            stats[f"behaviour: {behavior}"] += 1

        ts = observed_at(row)
        if ts == 0:
            stats["date unknown"] += 1

        count = as_int(row[COL["count"]]) or 1
        depth = as_int(row[COL["depth_ft"]]) or 0

        sightings.append({
            "sourceId":   as_int(row[COL["id"]]),
            "latitude":   round(float(row[COL["lat"]]) * 1_000_000),
            "longitude":  round(float(row[COL["lon"]]) * 1_000_000),
            "species":    species,
            "count":      min(count, 65535),
            # Read from the reporter's own note where they described what the
            # animal was doing; unknown where they did not. See classify_behavior.
            "behavior":   behavior,
            "observedAt": ts,
            "mediaUrl":   media_url,
            "comment":    comment,
            "siteName":   text(row[COL["site_official"]]),
            "depthFt":    min(depth, 65535),
            "sizeClass":  normalize(text(row[COL["size_class"]])),
        })
        stats[f"species: {species}"] += 1
        if media_url:
            stats["with media link"] += 1

    return sightings, stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("workbook")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--privacy", choices=("redact", "drop", "raw"), default="redact")
    args = ap.parse_args()

    sightings, stats = convert(args.workbook, args.privacy)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(sightings, fh, ensure_ascii=False, indent=1)

    print(f"wrote {len(sightings)} sightings to {args.out} (privacy={args.privacy})")
    for key, n in sorted(stats.items()):
        print(f"  {n:5}  {key}")
    if any(k.startswith("unmapped") for k in stats):
        print("\nWARNING: unmapped species fell back to 'unknown'.", file=sys.stderr)


if __name__ == "__main__":
    main()
