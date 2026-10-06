#!/usr/bin/env python3
import json
import re
import sys

import numpy as np

SOURCE = "UJI Pen Characters (Version 2), F. Prat, M. J. Castro, D. Llorens, A. Marzal, J. M. Vilar, UCI Machine Learning Repository, https://doi.org/10.24432/C5FG8S"
LICENSE = "CC BY 4.0, https://creativecommons.org/licenses/by/4.0/"
CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
POINTS = 32
BASELINE = 1270.0
XHEIGHT = 520.0
TRAIN = range(1, 51)
HELDOUT = range(51, 61)


def parse(path):
    samples = []
    current = None
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line.startswith("WORD"):
            parts = line.split()
            if len(parts) < 3:
                current = None
                continue
            ch, session = parts[1], parts[2]
            m = re.match(r"(trn|tst)_(UJI|UPV)_W(\d+)-(\d+)", session)
            current = {"ch": ch, "writer": int(m.group(3)), "rep": int(m.group(4)), "scale": 1.52 if m.group(2) == "UPV" else 1.0, "strokes": []}
            samples.append(current)
        elif line.startswith("POINTS") and current is not None:
            nums = [float(v) for v in line.split("#", 1)[1].split()]
            pts = [(nums[i] / current["scale"], nums[i + 1] / current["scale"]) for i in range(0, len(nums) - 1, 2)]
            dedup = [pts[0]]
            for p in pts[1:]:
                if p != dedup[-1]:
                    dedup.append(p)
            current["strokes"].append(dedup)
    return [s for s in samples if s["ch"] in CHARS and len(s["ch"]) == 1]


def resample(strokes):
    lengths = []
    for s in strokes:
        a = np.array(s)
        lengths.append(float(np.sum(np.hypot(*np.diff(a, axis=0).T))) if len(a) > 1 else 0.0)
    total = sum(lengths) or 1.0
    counts = [max(2, int(round(POINTS * l / total))) for l in lengths]
    out = []
    for s, n in zip(strokes, counts):
        a = np.array(s)
        if len(a) == 1:
            out.append(np.repeat(a, n, axis=0))
            continue
        d = np.concatenate([[0], np.cumsum(np.hypot(*np.diff(a, axis=0).T))])
        if d[-1] == 0:
            out.append(np.repeat(a[:1], n, axis=0))
            continue
        t = np.linspace(0, d[-1], n)
        out.append(np.stack([np.interp(t, d, a[:, 0]), np.interp(t, d, a[:, 1])], axis=1))
    return out


def normalize(strokes):
    allp = np.concatenate(strokes)
    x0 = allp[:, 0].min()
    return [np.stack([(s[:, 0] - x0) / XHEIGHT, (s[:, 1] - BASELINE) / XHEIGHT], axis=1) for s in strokes]


def flat(strokes):
    allp = np.concatenate(strokes)
    idx = np.linspace(0, len(allp) - 1, POINTS).astype(int)
    p = allp[idx]
    p = p - p.mean(axis=0)
    return p / max(np.ptp(allp[:, 0]), np.ptp(allp[:, 1]), 1e-3)


def encode(strokes):
    return [[int(round(v * 100)) for pt in s for v in pt] for s in strokes]


def medoids(items, k):
    if len(items) <= k:
        return list(range(len(items)))
    f = np.array([flat(s).ravel() for s in items])
    d = np.sqrt(((f[:, None, :] - f[None, :, :]) ** 2).sum(axis=2))
    chosen = [int(np.argmin(d.sum(axis=1)))]
    while len(chosen) < k:
        nearest = d[:, chosen].min(axis=1)
        chosen.append(int(np.argmax(nearest)))
    for _ in range(10):
        assign = np.argmin(d[:, chosen], axis=1)
        updated = []
        for c in range(len(chosen)):
            members = np.where(assign == c)[0]
            if len(members) == 0:
                updated.append(chosen[c])
                continue
            sub = d[np.ix_(members, members)]
            updated.append(int(members[np.argmin(sub.sum(axis=1))]))
        if updated == chosen:
            break
        chosen = updated
    return chosen


def main():
    samples = parse(sys.argv[1])
    letters = {}
    heldout = []
    for ch in CHARS:
        train = [normalize(resample(s["strokes"])) for s in samples if s["ch"] == ch and s["writer"] in TRAIN]
        pick = medoids(train, int(sys.argv[4]) if len(sys.argv) > 4 else 32)
        letters[ch] = [encode(train[i]) for i in pick]
    for s in samples:
        if s["writer"] in HELDOUT:
            heldout.append({"ch": s["ch"], "writer": s["writer"], "strokes": encode(normalize(resample(s["strokes"])))})
    json.dump({"source": SOURCE, "license": LICENSE, "writers": "1-50", "letters": letters}, open(sys.argv[2], "w"), separators=(",", ":"))
    json.dump({"source": SOURCE, "license": LICENSE, "writers": "51-60", "samples": heldout}, open(sys.argv[3], "w"), separators=(",", ":"))


main()
