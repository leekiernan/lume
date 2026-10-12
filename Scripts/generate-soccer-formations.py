#!/usr/bin/env python3
"""Build Lume/Resources/SoccerFormations.json from kloppy's Opta formation table.

ESPN's soccer lineups give each starter an Opta formation place (1-11). What a
place means depends on the formation (in a 4-2-3-1, place 4 is a holding
midfielder; in a 4-4-2, a central one), so the pitch view needs Opta's table:
kloppy (https://github.com/PySport/kloppy, BSD 3-Clause) carries it as
formation_position_mapping. This reads that file without importing kloppy.

  python3 Scripts/generate-soccer-formations.py path/to/formation_mapping.py
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Lume" / "Resources" / "SoccerFormations.json"
COPYRIGHT = (
    "Opta formation places: kloppy, Copyright (c) 2020, PySport, BSD 3-Clause License. "
    "https://github.com/PySport/kloppy"
)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    source = Path(sys.argv[1]).read_text()
    names = dict(
        (kind, name)
        for name, kind in re.findall(r'"(\w+)": FormationType\.(\w+)', source[source.index("formation_name_mapping") :])
    )
    body = source[source.index("formation_position_mapping") :]
    formations = {}
    for kind, block in re.findall(r"FormationType\.(\w+): \{(.*?)\}", body, re.S):
        name = names.get(kind)
        if not name or not name.isdigit():
            continue  # e.g. "343d": a shape the formation string can't name
        places = {place: position for place, position in re.findall(r"(\d+): PositionType\.(\w+)", block)}
        if len(places) == 11:
            formations[name] = dict(sorted(places.items(), key=lambda item: int(item[0])))
    OUTPUT.write_text(json.dumps({"attribution": COPYRIGHT, "formations": dict(sorted(formations.items()))}, separators=(",", ":")) + "\n")
    print(f"wrote {OUTPUT.relative_to(ROOT)}: {len(formations)} formations, {OUTPUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
