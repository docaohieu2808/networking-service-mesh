#!/usr/bin/env python3
"""Fail if a Helm values file contains a key the chart does not use.

Helm ignores unknown values silently, which hides typos like `bpfMasquerade`
(the real key is bpf.masquerade). A key counts as known when it appears in the
chart's default values, in its values.schema.json, or is read by a template as
`.Values.<path>` (some documented options, e.g. loadBalancer.mode, are only
commented examples in values.yaml).

Usage: check-helm-values-keys.py <values.yaml> <untarred-chart-dir> [--freeform a.b ...]
       (helm pull cilium/cilium --version X --untar)
--freeform marks a path whose children are free-form (e.g. Istio's meshConfig,
which is a protobuf message, not a fixed Helm schema).
"""
import json
import pathlib
import re
import sys

import yaml


def walk(node, path=()):
    if isinstance(node, dict):
        for key, value in node.items():
            yield path + (str(key),), value
            yield from walk(value, path + (str(key),))


def in_tree(tree, path, key="properties"):
    node = tree
    for part in path:
        if not isinstance(node, dict):
            return False
        node = node.get(key, node) if key and key in node and part not in node else node
        if part not in node:
            return False
        node = node[part]
    return True


def main(values_file, chart_dir, freeform):
    chart = pathlib.Path(chart_dir)
    values = yaml.safe_load(open(values_file))
    defaults = yaml.safe_load((chart / "values.yaml").read_text())
    # Istio charts keep their defaults under this key.
    internal = defaults.pop("_internal_defaults_do_not_set", None)
    if isinstance(internal, dict):
        defaults = {**internal, **defaults}
    schema_file = chart / "values.schema.json"
    schema = json.loads(schema_file.read_text()) if schema_file.exists() else {}
    templates = "\n".join(
        p.read_text(errors="ignore") for p in chart.rglob("*") if p.is_file() and p.suffix in {".yaml", ".tpl", ".txt"}
        and p.name != "values.yaml"
    )

    def known(path):
        if in_tree(defaults, path, key=None):
            return True
        node = schema
        for part in path:
            node = node.get("properties", {}).get(part) if isinstance(node, dict) else None
            if node is None:
                break
        else:
            return True
        dotted = r"\.".join(re.escape(p) for p in path)
        return re.search(r"\.Values\." + dotted + r"\b", templates) is not None

    bad = []
    free_paths = [tuple(f.split(".")) for f in freeform]
    for path, _ in walk(values):
        if any(path[: len(f)] == f for f in free_paths):
            continue
        # Kubernetes resource blocks: requests/limits (and their cpu/memory/...) are always valid.
        if any(path[i] == "resources" and i + 1 < len(path) and path[i + 1] in {"requests", "limits"}
               for i in range(len(path))):
            continue
        # Below a free-form map (empty default, e.g. annotations) any key is fine.
        free = False
        for i in range(1, len(path)):
            sub = defaults
            for part in path[:i]:
                sub = sub.get(part) if isinstance(sub, dict) else None
            if isinstance(sub, dict) and not sub:
                free = True
                break
        if not free and not known(path):
            bad.append(".".join(path))
    if bad:
        print("Keys the chart does not know (Helm would ignore them):")
        for p in bad:
            print("  -", p)
        return 1
    print(f"{values_file}: every key is known to the chart")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    free = [args[i + 1] for i, a in enumerate(args) if a == "--freeform"]
    pos = [a for i, a in enumerate(args) if a != "--freeform" and (i == 0 or args[i - 1] != "--freeform")]
    sys.exit(main(pos[0], pos[1], free))
