#!/usr/bin/env python3
"""Apply validated declarative operations to a complete layout_spec."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from typing import Any


TARGETS = {"product_image", "headline", "subtitle", "cta", "logo", "background"}
OPERATIONS = {"scale", "move", "replace_text", "change_color"}


def clamp(value: float, minimum: float, maximum: float) -> float:
    return max(minimum, min(value, maximum))


def scale_box(element: dict[str, Any], requested: float, safety: dict[str, Any], target: str) -> dict[str, Any]:
    limits = safety["product_scale" if target == "product_image" else "logo_scale"]
    requested = clamp(requested, float(limits["min"]), float(limits["max"]))
    old_x, old_y = float(element["x"]), float(element["y"])
    old_w, old_h = float(element["width"]), float(element["height"])
    applied = requested
    if target == "product_image":
        bounds = safety["product_bounds"]
        text_area = (safety.get("safe_areas") or {}).get("text") or {}
        safe_gap = float((safety.get("collision_rules") or {}).get("safe_gap", 0))
        protected_min_x = float(text_area.get("x", 0)) + float(text_area.get("width", 0)) + safe_gap if text_area else float(bounds["min_x"])
        minimum_x = max(float(bounds["min_x"]), protected_min_x)
        max_width = float(bounds["max_right"]) - minimum_x
        max_height = float(bounds["max_bottom"]) - float(bounds["min_y"])
        applied = min(applied, max_width / old_w, max_height / old_h)
    new_w, new_h = round(old_w * applied), round(old_h * applied)
    center_x, center_y = old_x + old_w / 2, old_y + old_h / 2
    new_x, new_y = round(center_x - new_w / 2), round(center_y - new_h / 2)
    if target == "product_image":
        bounds = safety["product_bounds"]
        text_area = (safety.get("safe_areas") or {}).get("text") or {}
        safe_gap = float((safety.get("collision_rules") or {}).get("safe_gap", 0))
        protected_min_x = float(text_area.get("x", 0)) + float(text_area.get("width", 0)) + safe_gap if text_area else float(bounds["min_x"])
        minimum_x = max(float(bounds["min_x"]), protected_min_x)
        new_x = round(clamp(new_x, minimum_x, float(bounds["max_right"]) - new_w))
        new_y = round(clamp(new_y, float(bounds["min_y"]), float(bounds["max_bottom"]) - new_h))
    element.update({"x": new_x, "y": new_y, "width": new_w, "height": new_h, "scale": round(float(element.get("scale", 1.0)) * applied, 4)})
    return {"target": target, "operation": "scale", "requested_value": requested, "applied_value": round(applied, 4), "result": {"x": new_x, "y": new_y, "width": new_w, "height": new_h}}


def move_element(element: dict[str, Any], value: dict[str, Any], safety: dict[str, Any], target: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"direction", "amount"}:
        raise ValueError("Move exige direction e amount.")
    direction = str(value["direction"]).lower()
    if direction not in {"up", "down", "left", "right"}:
        raise ValueError("Direcao invalida.")
    requested_amount = float(value["amount"])
    if requested_amount <= 0:
        raise ValueError("Amount deve ser positivo.")
    step = round(clamp(requested_amount, 1, float(safety["max_total_move"])))
    dx = step if direction == "right" else -step if direction == "left" else 0
    dy = step if direction == "down" else -step if direction == "up" else 0
    new_x, new_y = int(element["x"]) + dx, int(element["y"]) + dy
    if target == "product_image":
        bounds = safety["product_bounds"]
        text_area = (safety.get("safe_areas") or {}).get("text") or {}
        safe_gap = int((safety.get("collision_rules") or {}).get("safe_gap", 0))
        protected_min_x = int(text_area.get("x", 0)) + int(text_area.get("width", 0)) + safe_gap if text_area else int(bounds["min_x"])
        minimum_x = max(int(bounds["min_x"]), protected_min_x)
        new_x = round(clamp(new_x, minimum_x, int(bounds["max_right"]) - int(element["width"])))
        new_y = round(clamp(new_y, int(bounds["min_y"]), int(bounds["max_bottom"]) - int(element["height"])))
    else:
        new_x = round(clamp(new_x, 0, 1080 - int(element["width"])))
        new_y = round(clamp(new_y, 0, 1080 - int(element.get("height", 100))))
    element.update({"x": new_x, "y": new_y})
    return {"target": target, "operation": "move", "requested_value": value, "applied_value": {"direction": direction, "amount": step}, "result": {"x": new_x, "y": new_y}}


def apply_changes(payload: dict[str, Any]) -> dict[str, Any]:
    layout = copy.deepcopy(payload["layout_spec"])
    changes = payload["changes"]
    safety = layout.get("safety")
    if not safety:
        raise ValueError("layout_spec sem limites de seguranca.")
    applied: list[dict[str, Any]] = []
    for change in changes:
        target, operation, value = change.get("target"), change.get("operation"), change.get("value")
        if target not in TARGETS or operation not in OPERATIONS:
            raise ValueError("Target/operation nao permitido.")
        element = layout[target]
        if operation == "scale":
            if target not in {"product_image", "logo"} or not isinstance(value, (int, float)):
                raise ValueError("Scale invalido.")
            applied.append(scale_box(element, float(value), safety, target))
        elif operation == "move":
            if target not in {"product_image", "headline", "subtitle", "cta", "logo"} or not isinstance(value, dict):
                raise ValueError("Move invalido.")
            applied.append(move_element(element, value, safety, target))
        elif operation == "replace_text":
            if target not in {"headline", "subtitle", "cta"} or not isinstance(value, str) or not value.strip() or len(value) > 160:
                raise ValueError("Replace text invalido.")
            element["text"] = value
            applied.append({"target": target, "operation": operation, "requested_value": value, "applied_value": value})
        elif operation == "change_color":
            if target not in {"background", "headline", "subtitle", "cta"} or not isinstance(value, str) or value not in layout["palette"]:
                raise ValueError("Cor fora da paleta da marca.")
            field = "color"
            element[field] = value
            applied.append({"target": target, "operation": operation, "requested_value": value, "applied_value": value})
    layout.update({"schema_version": "2.0", "content_id": payload["content_id"], "version_id": payload["version_id"], "version_label": payload["version_label"]})
    layout["output"] = {"path": payload["output_path"], "format": "PNG", "width": 1080, "height": 1080}
    layout["revision"] = {"source_version_id": payload["source_version_id"], "change_request_id": payload["change_request_id"], "requested_changes": changes, "applied_changes": applied}
    return {"layout_spec": layout, "applied_changes": applied}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--result", required=True)
    args = parser.parse_args()
    payload = json.loads(Path(args.input).read_text(encoding="utf-8"))
    result = apply_changes(payload)
    Path(args.result).write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
