#!/usr/bin/env python3
"""规则元数据 / JSON 报告 / 版本比对。
用法:
  vh_rules.py report RESULTS.tsv OUT.json OUT.md
  vh_rules.py vercmp CUR LATEST   # 退出码 0 表示 CUR >= LATEST
  vh_rules.py diff OLD.json NEW.json  # 打印新增 fail 的 ID
"""
import json
import re
import sys
from datetime import datetime, timezone

SCHEMA_VERSION = 1
FIELDS = ["id", "severity", "status", "owner", "fix_type", "title", "evidence"]
WEIGHT = {"P0": 10, "P1": 4, "P2": 1}


def ver(s):
    return tuple(int(x) for x in re.findall(r"\d+", s)[:3]) or (0,)


def load_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 7:
                rows.append(dict(zip(FIELDS, parts[:7])))
    return rows


def grade(rows):
    if any(r["status"] == "fail" and r["severity"] == "P0" for r in rows):
        return "D"
    lost = sum(WEIGHT.get(r["severity"], 0) for r in rows if r["status"] in ("fail", "warn"))
    return "A" if lost == 0 else "B" if lost <= 4 else "C"


def report(tsv, out_json, out_md):
    rows = load_tsv(tsv)
    doc = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "grade": grade(rows),
        "summary": {s: sum(r["status"] == s for r in rows) for s in ("pass", "fail", "warn", "unknown")},
        "results": rows,
    }
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
    icon = {"pass": "✅", "fail": "❌", "warn": "⚠️", "unknown": "❔"}
    lines = [
        f"## vhm 审计报告 · 评级 {doc['grade']}",
        "",
        "| 结果 | ID | 级别 | 检查 | owner/fix | 证据 |",
        "|---|---|---|---|---|---|",
    ]
    for r in sorted(rows, key=lambda r: (r["severity"], r["id"])):
        ev = r["evidence"].replace("|", "\\|")
        lines.append(f"| {icon.get(r['status'], '?')} | {r['id']} | {r['severity']} | {r['title']} | {r['owner']}/{r['fix_type']} | {ev} |")
    s = doc["summary"]
    lines += ["", f"通过 {s['pass']} · 失败 {s['fail']} · 警告 {s['warn']} · 未知 {s['unknown']}"]
    with open(out_md, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"评级 {doc['grade']}：通过 {s['pass']} 失败 {s['fail']} 警告 {s['warn']} 未知 {s['unknown']}")


def diff(old, new):
    def fails(p):
        try:
            return {r["id"] for r in json.load(open(p, encoding="utf-8"))["results"] if r["status"] == "fail"}
        except Exception:
            return set()
    for i in sorted(fails(new) - fails(old)):
        print(i)


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["report"] and len(a) == 4:
        report(*a[1:])
    elif a[:1] == ["vercmp"] and len(a) == 3:
        sys.exit(0 if ver(a[1]) >= ver(a[2]) else 1)
    elif a[:1] == ["diff"] and len(a) == 3:
        diff(a[1], a[2])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
