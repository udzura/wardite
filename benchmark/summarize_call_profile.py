"""Summarize an xctrace time-profile XML export, without third-party packages."""

import collections
import json
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
references = {element.get("id"): element for element in root.iter() if element.get("id")}


def resolve(element):
    if element is not None and element.get("ref"):
        return references[element.get("ref")]
    return element


self_time = collections.Counter()
inclusive_time = collections.Counter()
total = 0
missing = 0
samples = 0
for row in root.iter("row"):
    stack = resolve(row.find("tagged-backtrace"))
    weight = resolve(row.find("weight"))
    if stack is None or weight is None:
        missing += 1
        continue
    frames = [resolve(frame).get("name", "unknown") for frame in stack.findall("frame")]
    if not frames:
        missing += 1
        continue
    nanoseconds = int(weight.text)
    samples += 1
    total += nanoseconds
    self_time[frames[0]] += nanoseconds
    for name in set(frames):
        inclusive_time[name] += nanoseconds

if not total:
    raise SystemExit("No weighted stack samples found")

print(json.dumps({
    "sampled_cpu_ms": total / 1e6,
    "stack_samples": samples,
    "missing_stack_rows": missing,
    "note": "Inclusive percentages overlap; these are sampled CPU weights, not wall-clock attribution.",
    "functions": [{
        "name": name,
        "self_ms": weight / 1e6,
        "self_percent": weight * 100 / total,
        "inclusive_percent": inclusive_time[name] * 100 / total,
    } for name, weight in self_time.most_common()],
}, indent=2))
