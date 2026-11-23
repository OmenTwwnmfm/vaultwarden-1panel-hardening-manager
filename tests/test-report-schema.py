#!/usr/bin/env python3
"""断言报告 JSON 字段齐全、含 schema_version，评级逻辑正确。"""
import json, os, subprocess, sys, tempfile
root = os.path.join(os.path.dirname(__file__), "..")
rules = os.path.join(root, "scripts", "vh_rules.py")
with tempfile.TemporaryDirectory() as d:
    tsv = os.path.join(d, "r.tsv")
    with open(tsv, "w", encoding="utf-8") as f:
        f.write("A-01\tP0\tfail\t1panel\tguided\t关闭开放注册\tSIGNUPS_ALLOWED=true\n")
        f.write("D-02\tP1\tpass\thost\tauto\t数据目录权限\tok\n")
    j, m = os.path.join(d, "r.json"), os.path.join(d, "r.md")
    subprocess.run([sys.executable, rules, "report", tsv, j, m], check=True, capture_output=True)
    doc = json.load(open(j, encoding="utf-8"))
    assert doc["schema_version"] == 1
    assert doc["grade"] == "D"
    for r in doc["results"]:
        assert set(r) == {"id", "severity", "status", "owner", "fix_type", "title", "evidence"}
    assert subprocess.run([sys.executable, rules, "vercmp", "1.32.5", "1.32.4"]).returncode == 0
    assert subprocess.run([sys.executable, rules, "vercmp", "1.31.0", "1.32.4"]).returncode == 1
print("PASS report-schema")
