#!/usr/bin/env python3
"""Build Lume/Resources/F1Circuits.json from bacinger/f1-circuits.

The outlines come from https://github.com/bacinger/f1-circuits (MIT), a
GeoJSON LineString per circuit. ESPN identifies circuits by its own ids, so
the table below maps each to the dataset's. Run with the dataset's
f1-circuits.geojson; add a row when ESPN's calendar gains a circuit.

  python3 Scripts/generate-f1-circuits.py path/to/f1-circuits.geojson

Each outline is projected (longitude scaled by the cosine of the latitude, so
corners keep their shape), fitted to a unit box with its aspect kept and north
up, then simplified (Ramer-Douglas-Peucker) and rounded to keep the file small.
"""

import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Lume" / "Resources" / "F1Circuits.json"

# ESPN circuit id -> dataset id. The 2026 calendar, matched by name and city.
ESPN_TO_DATASET = {
    "601": "au-1953",   # Melbourne
    "619": "cn-2004",   # Shanghai
    "618": "jp-1962",   # Suzuka
    "603": "bh-2002",   # Bahrain
    "4069": "sa-2021",  # Jeddah
    "4243": "us-2022",  # Miami
    "608": "ca-1978",   # Montreal
    "606": "mc-1929",   # Monaco
    "5826": "es-1991",  # Barcelona-Catalunya
    "779": "at-1969",   # Red Bull Ring
    "611": "gb-1948",   # Silverstone
    "616": "be-1925",   # Spa-Francorchamps
    "613": "hu-1986",   # Hungaroring
    "1102": "nl-1948",  # Zandvoort
    "615": "it-1922",   # Monza
    "605": "es-2026",   # Madring
    "607": "az-2016",   # Baku
    "602": "my-1999",   # Sepang
    "740": "sg-2008",   # Marina Bay
    "609": "us-2012",   # Circuit of the Americas
    "782": "mx-1962",   # Hermanos Rodriguez
    "617": "br-1940",   # Interlagos
    "4250": "us-2023",  # Las Vegas
    "4211": "qa-2004",  # Losail
    "744": "ae-2009",   # Yas Marina
}

TOLERANCE = 0.004  # in unit-box widths: invisible at any size the app draws
COPYRIGHT = "Circuit outlines: f1-circuits, Copyright (c) 2019-2025 Tomislav Bacinger, MIT License. https://github.com/bacinger/f1-circuits"


def project(coordinates):
    lat0 = math.radians(sum(lat for _, lat in coordinates) / len(coordinates))
    points = [(lon * math.cos(lat0), lat) for lon, lat in coordinates]
    xs, ys = [x for x, _ in points], [y for _, y in points]
    span = max(max(xs) - min(xs), max(ys) - min(ys))
    return [((x - min(xs)) / span, (max(ys) - y) / span) for x, y in points]


def simplify(points, tolerance):
    if len(points) < 3:
        return points

    def distance(point, start, end):
        (x, y), (x1, y1), (x2, y2) = point, start, end
        dx, dy = x2 - x1, y2 - y1
        if dx == dy == 0:
            return math.hypot(x - x1, y - y1)
        return abs(dy * x - dx * y + x2 * y1 - y2 * x1) / math.hypot(dx, dy)

    index, worst = 0, 0.0
    for i in range(1, len(points) - 1):
        d = distance(points[i], points[0], points[-1])
        if d > worst:
            index, worst = i, d
    if worst <= tolerance:
        return [points[0], points[-1]]
    return simplify(points[: index + 1], tolerance)[:-1] + simplify(points[index:], tolerance)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    features = {f["properties"]["id"]: f for f in json.loads(Path(sys.argv[1]).read_text())["features"]}
    circuits = {}
    for espn_id, dataset_id in sorted(ESPN_TO_DATASET.items(), key=lambda item: int(item[0])):
        feature = features[dataset_id]
        points = simplify(project(feature["geometry"]["coordinates"]), TOLERANCE)
        circuits[espn_id] = {
            "name": feature["properties"]["Name"],
            "length": feature["properties"]["length"],
            "points": [[round(x, 3), round(y, 3)] for x, y in points],
        }
    OUTPUT.write_text(json.dumps({"attribution": COPYRIGHT, "circuits": circuits}, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {len(circuits)} circuits, {OUTPUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
