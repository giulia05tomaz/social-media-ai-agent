#!/usr/bin/env python3
"""Deterministic renderer: template creates v1; complete layout_spec renders every version."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import time
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont


class LayoutValidationError(ValueError):
    """Raised before file creation when the resolved layout is not safe."""

    error_code = "LAYOUT_VALIDATION_FAILED"

    def __init__(self, message: str, report: dict[str, Any] | None = None):
        super().__init__(message)
        self.report = report or {"valid": False, "errors": [{"type": "layout_validation", "message": message}], "warnings": []}


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def merge_defaults(current: dict[str, Any], defaults: dict[str, Any]) -> dict[str, Any]:
    """Recursively add new template capabilities without replacing versioned choices."""
    merged = copy.deepcopy(defaults)
    for key, value in current.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = merge_defaults(value, merged[key])
        else:
            merged[key] = copy.deepcopy(value)
    return merged


def resolve_project_path(project_root: Path, value: str) -> Path:
    candidate = (project_root / value).resolve()
    if project_root != candidate and project_root not in candidate.parents:
        raise ValueError(f"Caminho fora do projeto: {value}")
    return candidate


def find_font(family: str, bold: bool = False) -> str | None:
    windows = Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts"
    lookup = {
        "Georgia Bold": [windows / "georgiab.ttf"],
        "Georgia": [windows / "georgia.ttf"],
        "Segoe UI": [windows / ("segoeuib.ttf" if bold else "segoeui.ttf")],
        "Arial": [windows / ("arialbd.ttf" if bold else "arial.ttf")],
    }
    is_serif = family.startswith("Georgia")
    linux_fallback = (
        "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf"
        if is_serif and bold
        else "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf"
        if is_serif
        else "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
        if bold
        else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    )
    candidates = lookup.get(family, []) + [Path(linux_fallback)]
    return next((str(path) for path in candidates if path.exists()), None)


def font(family: str, size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    path = find_font(family, bold)
    return ImageFont.truetype(path, size=size) if path else ImageFont.load_default(size=size)


def cover(image: Image.Image, width: int, height: int, focus_x: float, focus_y: float) -> Image.Image:
    source_ratio = image.width / image.height
    target_ratio = width / height
    if source_ratio > target_ratio:
        crop_width = int(image.height * target_ratio)
        left = max(0, min(int((image.width - crop_width) * focus_x), image.width - crop_width))
        box = (left, 0, left + crop_width, image.height)
    else:
        crop_height = int(image.width / target_ratio)
        top = max(0, min(int((image.height - crop_height) * focus_y), image.height - crop_height))
        box = (0, top, image.width, top + crop_height)
    return image.crop(box).resize((width, height), Image.Resampling.LANCZOS)


def text_width(draw: ImageDraw.ImageDraw, text: str, face: ImageFont.ImageFont) -> int:
    bounds = draw.textbbox((0, 0), text, font=face)
    return max(0, bounds[2] - bounds[0])


def split_oversized_word(draw: ImageDraw.ImageDraw, word: str, face: ImageFont.ImageFont, width: int) -> list[str]:
    """Split only a single word that cannot fit even on an empty line."""
    pieces: list[str] = []
    current = ""
    for character in word:
        candidate = current + character
        if current and text_width(draw, candidate, face) > width:
            pieces.append(current)
            current = character
        else:
            current = candidate
    if current:
        pieces.append(current)
    return pieces


def wrap_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    face: ImageFont.ImageFont,
    width: int,
    allow_word_break: bool = False,
) -> tuple[list[str], bool]:
    """Wrap measured text and never split a token unless the template opts in."""
    lines: list[str] = []
    current = ""
    mid_word_break = False
    for word in text.split():
        if text_width(draw, word, face) > width:
            if current:
                lines.append(current)
                current = ""
            if allow_word_break:
                pieces = split_oversized_word(draw, word, face, width)
                lines.extend(pieces[:-1])
                current = pieces[-1]
                mid_word_break = len(pieces) > 1
            else:
                # Keep the token intact. resolve_text_box will retry with a
                # smaller font and fail safely if min_font_size is insufficient.
                current = word
            continue
        candidate = f"{current} {word}".strip()
        if text_width(draw, candidate, face) <= width or not current:
            current = candidate
        else:
            lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines, mid_word_break


def line_bbox(draw: ImageDraw.ImageDraw, lines: list[str], face: ImageFont.ImageFont, x: int, y: int, line_height: float) -> tuple[list[int], int]:
    step = max(1, round(int(getattr(face, "size", 12)) * line_height))
    if not lines:
        return [x, y, x, y], step
    boxes = [draw.textbbox((x, y + index * step), line, font=face) for index, line in enumerate(lines)]
    return [min(box[0] for box in boxes), min(box[1] for box in boxes), max(box[2] for box in boxes), max(box[3] for box in boxes)], step


def resolve_text_box(draw: ImageDraw.ImageDraw, name: str, cfg: dict[str, Any], bold: bool = False) -> list[dict[str, Any]]:
    text = str(cfg.get("text") or "")
    x, y = int(cfg["x"]), int(cfg["y"])
    width = int(cfg.get("max_width", cfg.get("width", 0)))
    height = int(cfg.get("max_height", 1080 - y))
    initial_size = int(cfg.get("max_font_size", cfg.get("font_size", 32)))
    minimum_size = int(cfg.get("min_font_size", initial_size))
    max_lines = int(cfg.get("max_lines", 1))
    line_height = float(cfg.get("line_height", 1.15))
    allow_word_break = bool(cfg.get("allow_word_break", False))
    cfg["allow_word_break"] = allow_word_break
    if width <= 0 or height <= 0 or minimum_size <= 0 or initial_size < minimum_size or max_lines <= 0:
        raise LayoutValidationError(f"Configuracao de text box invalida: {name}.")
    if not text:
        cfg["resolved"] = {"font_size": initial_size, "lines": [], "bbox": [x, y, x, y], "line_step": 0, "mid_word_break": False}
        return []
    for size in range(initial_size, minimum_size - 1, -1):
        face = font(str(cfg["font_family"]), size, bold)
        lines, mid_word_break = wrap_text(draw, text, face, width, allow_word_break)
        bbox, step = line_bbox(draw, lines, face, x, y, line_height)
        if len(lines) <= max_lines and bbox[2] <= x + width and bbox[3] <= y + height:
            cfg["resolved"] = {"font_size": size, "lines": lines, "bbox": bbox, "line_step": step, "mid_word_break": mid_word_break}
            warnings: list[dict[str, Any]] = []
            if size != initial_size:
                warnings.append({"type": "font_size_adjusted", "element": name, "from": initial_size, "to": size})
            if len(lines) > 1:
                warnings.append({"type": "text_wrapped", "element": name, "lines": lines})
            return warnings
    raise LayoutValidationError(
        f"LAYOUT_OVERFLOW: {name} nao cabe em {width}x{height} no tamanho minimo {minimum_size}.",
        {"valid": False, "errors": [{"type": "text_overflow", "element": name, "min_font_size": minimum_size, "max_lines": max_lines, "allowed_box": [x, y, x + width, y + height]}], "warnings": []},
    )


def resolve_cta(draw: ImageDraw.ImageDraw, cfg: dict[str, Any]) -> list[dict[str, Any]]:
    text = str(cfg.get("text") or "")
    x, y = int(cfg["x"]), int(cfg["y"])
    initial_size = int(cfg.get("max_font_size", cfg.get("font_size", 24)))
    minimum_size = int(cfg.get("min_font_size", initial_size))
    min_width = int(cfg.get("min_width", cfg.get("width", 1)))
    max_width = int(cfg.get("max_width", cfg.get("width", min_width)))
    padding = int(cfg.get("horizontal_padding", 32))
    height = int(cfg["height"])
    cfg["allow_word_break"] = bool(cfg.get("allow_word_break", False))
    if not text:
        cfg["resolved"] = {"font_size": initial_size, "lines": [], "bbox": [x, y, x, y], "text_bbox": [x, y, x, y], "width": 0, "height": 0, "mid_word_break": False}
        return []
    for size in range(initial_size, minimum_size - 1, -1):
        face = font(str(cfg["font_family"]), size, True)
        raw = draw.textbbox((0, 0), text, font=face)
        required_width = text_width(draw, text, face) + padding * 2
        button_width = max(min_width, required_width)
        if button_width > max_width or raw[3] - raw[1] > height - 12:
            continue
        tx = x + (button_width - (raw[2] - raw[0])) // 2 - raw[0]
        ty = y + (height - (raw[3] - raw[1])) // 2 - raw[1]
        text_box = list(draw.textbbox((tx, ty), text, font=face))
        cfg["resolved"] = {"font_size": size, "lines": [text], "bbox": [x, y, x + button_width, y + height], "text_bbox": text_box, "width": button_width, "height": height, "mid_word_break": False}
        return ([{"type": "font_size_adjusted", "element": "cta", "from": initial_size, "to": size}] if size != initial_size else []) + ([{"type": "cta_width_adjusted", "element": "cta", "from": int(cfg.get("width", min_width)), "to": button_width}] if button_width != int(cfg.get("width", min_width)) else [])
    raise LayoutValidationError(
        f"LAYOUT_OVERFLOW: CTA nao cabe na largura maxima {max_width}.",
        {"valid": False, "errors": [{"type": "text_overflow", "element": "cta", "min_font_size": minimum_size, "max_width": max_width}], "warnings": []},
    )


def boxes_intersect(first: list[int], second: list[int], gap: int = 0) -> bool:
    return not (first[2] + gap <= second[0] or second[2] + gap <= first[0] or first[3] + gap <= second[1] or second[3] + gap <= first[1])


def box_inside(inner: list[int], outer: list[int]) -> bool:
    return inner[0] >= outer[0] and inner[1] >= outer[1] and inner[2] <= outer[2] and inner[3] <= outer[3]


def area_box(area: dict[str, Any]) -> list[int]:
    x, y = int(area["x"]), int(area["y"])
    return [x, y, x + int(area["width"]), y + int(area["height"])]


def resolve_layout(layout: dict[str, Any]) -> dict[str, Any]:
    started = time.perf_counter()
    canvas = layout["canvas"]
    scratch = Image.new("RGB", (int(canvas["width"]), int(canvas["height"])), "white")
    draw = ImageDraw.Draw(scratch)
    safety = layout["safety"]
    text_area = area_box(safety["safe_areas"]["text"])
    gaps = safety.get("gaps", {})
    warnings: list[dict[str, Any]] = []

    for name in ("headline", "subtitle"):
        cfg = layout[name]
        cfg["x"] = max(int(cfg["x"]), text_area[0])
        cfg["max_width"] = min(int(cfg.get("max_width", cfg.get("width", text_area[2] - cfg["x"]))), text_area[2] - int(cfg["x"]))

    warnings.extend(resolve_text_box(draw, "headline", layout["headline"], bold=True))
    headline_bottom = int(layout["headline"]["resolved"]["bbox"][3])
    layout["subtitle"]["y"] = max(int(layout["subtitle"]["y"]), headline_bottom + int(gaps.get("headline_subtitle", 24)))
    warnings.extend(resolve_text_box(draw, "subtitle", layout["subtitle"]))
    subtitle_bottom = int(layout["subtitle"]["resolved"]["bbox"][3])

    separator = next((item for item in layout["decorative_elements"] if item.get("id") == "copy-separator"), None)
    separator_bottom = subtitle_bottom
    if separator and "bounds" in separator:
        left, top, right, bottom = (int(value) for value in separator["bounds"])
        height = bottom - top
        new_top = max(top, subtitle_bottom + int(gaps.get("subtitle_separator", 18)))
        separator["bounds"] = [left, new_top, right, new_top + height]
        separator_bottom = new_top + height

    layout["cta"]["y"] = max(int(layout["cta"]["y"]), separator_bottom + int(gaps.get("separator_cta", 28)))
    layout["cta"]["max_width"] = min(int(layout["cta"].get("max_width", text_area[2] - int(layout["cta"]["x"]))), text_area[2] - int(layout["cta"]["x"]))
    warnings.extend(resolve_cta(draw, layout["cta"]))
    layout["layout_resolution"] = {"status": "resolved", "duration_ms": round((time.perf_counter() - started) * 1000, 3), "warnings": warnings}
    return layout


def validate_resolved_layout(layout: dict[str, Any]) -> dict[str, Any]:
    safety = layout["safety"]
    safe_areas = safety["safe_areas"]
    text_area = area_box(safe_areas["text"])
    product_area = area_box(safe_areas["product"])
    canvas_box = [0, 0, int(layout["canvas"]["width"]), int(layout["canvas"]["height"])]
    gap = int(safety.get("collision_rules", {}).get("safe_gap", 20))
    errors: list[dict[str, Any]] = []
    boxes = {
        "headline": list(layout["headline"]["resolved"]["bbox"]),
        "subtitle": list(layout["subtitle"]["resolved"]["bbox"]),
        "cta": list(layout["cta"]["resolved"]["bbox"]),
        "logo": [int(layout["logo"]["x"]), int(layout["logo"]["y"]), int(layout["logo"]["x"]) + int(layout["logo"]["width"]), int(layout["logo"]["y"]) + int(layout["logo"]["height"])],
        "product_image": [int(layout["product_image"]["x"]), int(layout["product_image"]["y"]), int(layout["product_image"]["x"]) + int(layout["product_image"]["width"]), int(layout["product_image"]["y"]) + int(layout["product_image"]["height"])],
    }
    for name, box in boxes.items():
        if not box_inside(box, canvas_box):
            errors.append({"type": "outside_canvas", "element": name, "bbox": box})
    for name in ("headline", "subtitle", "cta"):
        if not box_inside(boxes[name], text_area):
            errors.append({"type": "outside_safe_area", "element": name, "bbox": boxes[name], "safe_area": text_area})
        if not bool(safety.get("collision_rules", {}).get("allow_text_overlap_with_product_image", False)) and boxes_intersect(boxes[name], boxes["product_image"], gap):
            errors.append({"type": "collision", "elements": [name, "product_image"], "gap": gap})
    if not box_inside(boxes["product_image"], product_area):
        errors.append({"type": "outside_safe_area", "element": "product_image", "bbox": boxes["product_image"], "safe_area": product_area})
    for first, second in (("headline", "logo"), ("headline", "subtitle"), ("subtitle", "cta")):
        if boxes_intersect(boxes[first], boxes[second], gap):
            errors.append({"type": "collision", "elements": [first, second], "gap": gap})
    report = {"valid": not errors, "errors": errors, "warnings": list(layout.get("layout_resolution", {}).get("warnings", [])), "boxes": boxes, "safe_areas": {"text": text_area, "product": product_area}}
    layout["validation"] = report
    if errors:
        raise LayoutValidationError("Layout possui overflow ou colisao critica.", report)
    return report


def create_layout_from_template(payload: dict[str, Any], template: dict[str, Any]) -> dict[str, Any]:
    canvas_cfg = template["canvas"]
    headline_cfg = copy.deepcopy(template["headline"])
    headline_cfg["text"] = str(payload["title"])
    subtitle_cfg = {**copy.deepcopy(template["subtitle"]), "text": str(payload.get("subtitle") or "")}
    cta_cfg = {**copy.deepcopy(template["cta"]), "text": str(payload.get("cta") or "")}
    logo_cfg = copy.deepcopy(template["logo"])
    logo_cfg["asset"] = payload.get("logo_path") or logo_cfg["asset"]
    product_cfg = copy.deepcopy(template["product_image"])
    product_cfg["source"] = payload["source_image_path"]
    palette = payload.get("palette") or list(template["palette_roles"].values())
    return {
        "schema_version": "2.1",
        "template_id": template["template_id"],
        "renderer": "local-pillow",
        "content_id": payload["content_id"],
        "version_id": payload["version_id"],
        "version_label": payload["version_label"],
        "canvas": {"width": int(canvas_cfg["width"]), "height": int(canvas_cfg["height"]), "format": "PNG"},
        "background": {"color": template["palette_roles"]["background"]},
        "decorative_elements": copy.deepcopy(template["decorative_elements"]),
        "product_image": product_cfg,
        "headline": headline_cfg,
        "subtitle": subtitle_cfg,
        "cta": cta_cfg,
        "logo": logo_cfg,
        "typography": copy.deepcopy(template["typography"]),
        "safety": copy.deepcopy(template["safety"]),
        "palette": palette,
        "source_assets": {"product_image": product_cfg["source"], "logo": logo_cfg["asset"]},
        "output": {"path": payload["output_path"], "format": "PNG", "width": 1080, "height": 1080},
    }


def validate_layout(layout: dict[str, Any], project_root: Path) -> tuple[Path, Path]:
    required = ["canvas", "background", "decorative_elements", "product_image", "headline", "subtitle", "cta", "logo", "typography", "safety", "palette", "source_assets", "output"]
    missing = [key for key in required if key not in layout]
    if missing:
        raise ValueError("layout_spec incompleto: " + ", ".join(missing))
    canvas = layout["canvas"]
    if (int(canvas["width"]), int(canvas["height"])) != (1080, 1080) or canvas.get("format") != "PNG":
        raise ValueError("Canvas permitido: somente PNG 1080x1080.")
    palette = layout["palette"]
    for color in [layout["background"]["color"], layout["headline"]["color"], layout["subtitle"]["color"], layout["cta"]["background"], layout["cta"]["color"]]:
        if color not in palette:
            raise ValueError(f"Cor fora da paleta cadastrada: {color}")
    product = layout["product_image"]
    if not (1 <= int(product["width"]) <= 1080 and 1 <= int(product["height"]) <= 1080):
        raise ValueError("Dimensoes de produto invalidas.")
    if not (-200 <= int(product["x"]) <= 1080 and -200 <= int(product["y"]) <= 1080):
        raise ValueError("Posicao do produto invalida.")
    if not isinstance(layout.get("safety", {}).get("safe_areas"), dict):
        raise ValueError("layout_spec sem safe_areas configuradas.")
    source = resolve_project_path(project_root, layout["source_assets"]["product_image"])
    logo = resolve_project_path(project_root, layout["source_assets"]["logo"])
    if not source.is_file() or not logo.is_file():
        raise FileNotFoundError("Source image ou logo inexistente.")
    return source, logo


def draw_decorative(draw: ImageDraw.ImageDraw, element: dict[str, Any], layout: dict[str, Any]) -> None:
    kind = element["type"]
    fill = element["fill"]
    if fill not in layout["palette"]:
        raise ValueError(f"Elemento decorativo fora da paleta: {fill}")
    if kind == "anchored_rounded_rectangle":
        if element.get("anchor") != "product_image":
            raise ValueError("Anchor decorativo nao permitido.")
        product = layout["product_image"]
        left, top, right, bottom = (int(v) for v in element["offsets"])
        bounds = (int(product["x"]) + left, int(product["y"]) + top, int(product["x"]) + int(product["width"]) + right, int(product["y"]) + int(product["height"]) + bottom)
        radius = int(product["corner_radius"]) + int(element.get("radius_offset", 0))
        draw.rounded_rectangle(bounds, radius=radius, fill=fill)
    else:
        bounds = tuple(int(v) for v in element["bounds"])
        if kind == "ellipse":
            draw.ellipse(bounds, fill=fill)
        elif kind == "rectangle":
            draw.rectangle(bounds, fill=fill)
        elif kind == "rounded_rectangle":
            draw.rounded_rectangle(bounds, radius=int(element.get("radius", 0)), fill=fill)
        else:
            raise ValueError(f"Elemento decorativo nao permitido: {kind}")


def render_from_layout_spec(layout: dict[str, Any], project_root: Path, output_path: Path) -> dict[str, Any]:
    render_started = time.perf_counter()
    source_path, logo_path = validate_layout(layout, project_root)
    resolve_layout(layout)
    validation = validate_resolved_layout(layout)
    width, height = int(layout["canvas"]["width"]), int(layout["canvas"]["height"])
    canvas = Image.new("RGB", (width, height), layout["background"]["color"])
    draw = ImageDraw.Draw(canvas)
    for element in layout["decorative_elements"]:
        draw_decorative(draw, element, layout)

    product = layout["product_image"]
    px, py, pw, ph = (int(product[key]) for key in ("x", "y", "width", "height"))
    with Image.open(source_path) as source:
        photo = cover(source.convert("RGB"), pw, ph, float(product["focus_x"]), float(product["focus_y"]))
    mask = Image.new("L", (pw, ph), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, pw, ph), radius=int(product["corner_radius"]), fill=255)
    canvas.paste(photo, (px, py), mask)

    logo_cfg = layout["logo"]
    with Image.open(logo_path) as source:
        logo = source.convert("RGBA")
        crop = tuple(int(v) for v in logo_cfg.get("source_crop", [0, 0, logo.width, logo.height]))
        logo = logo.crop(crop).resize((int(logo_cfg["width"]), int(logo_cfg["height"])), Image.Resampling.LANCZOS)
    canvas.paste(logo, (int(logo_cfg["x"]), int(logo_cfg["y"])), logo)

    headline = layout["headline"]
    if not headline.get("text"):
        raise ValueError("Headline vazia.")
    resolved_headline = headline["resolved"]
    headline_face = font(headline["font_family"], int(resolved_headline["font_size"]), True)
    for index, line in enumerate(resolved_headline["lines"]):
        draw.text((int(headline["x"]), int(headline["y"]) + index * int(resolved_headline["line_step"])), line, font=headline_face, fill=headline["color"])

    subtitle = layout["subtitle"]
    if subtitle.get("text"):
        resolved_subtitle = subtitle["resolved"]
        subtitle_face = font(subtitle["font_family"], int(resolved_subtitle["font_size"]))
        for index, line in enumerate(resolved_subtitle["lines"]):
            draw.text((int(subtitle["x"]), int(subtitle["y"]) + index * int(resolved_subtitle["line_step"])), line, font=subtitle_face, fill=subtitle["color"])

    cta = layout["cta"]
    if cta.get("text"):
        resolved_cta = cta["resolved"]
        cx, cy, cw, ch = int(cta["x"]), int(cta["y"]), int(resolved_cta["width"]), int(resolved_cta["height"])
        draw.rounded_rectangle((cx, cy, cx + cw, cy + ch), radius=ch // 2, fill=cta["background"])
        cta_face = font(cta["font_family"], int(resolved_cta["font_size"]), True)
        bbox = draw.textbbox((0, 0), cta["text"], font=cta_face)
        tx = cx + (cw - (bbox[2] - bbox[0])) // 2 - bbox[0]
        ty = cy + (ch - (bbox[3] - bbox[1])) // 2 - bbox[1]
        draw.text((tx, ty), cta["text"], font=cta_face, fill=cta["color"])

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_suffix(".tmp.png")
    canvas.save(temporary, "PNG", optimize=True)
    with Image.open(temporary) as check:
        if check.size != (1080, 1080) or check.format != "PNG":
            temporary.unlink(missing_ok=True)
            raise ValueError("PNG final invalido.")
    os.replace(temporary, output_path)
    return {
        "checksum_sha256": hashlib.sha256(output_path.read_bytes()).hexdigest().upper(),
        "validation": validation,
        "warnings": list(layout.get("layout_resolution", {}).get("warnings", [])),
        "layout_resolution_ms": layout.get("layout_resolution", {}).get("duration_ms", 0),
        "render_ms": round((time.perf_counter() - render_started) * 1000, 3),
    }


def render_local(payload: dict[str, Any], template: dict[str, Any], project_root: Path) -> dict[str, Any]:
    for key in ["content_id", "version_id", "version_label", "client_id", "output_path", "layout_spec_path"]:
        if not payload.get(key):
            raise ValueError(f"Campo obrigatorio ausente: {key}")
    output_path = resolve_project_path(project_root, payload["output_path"])
    spec_path = resolve_project_path(project_root, payload["layout_spec_path"])
    if output_path.exists() or spec_path.exists():
        raise FileExistsError("A saida desta versao ja existe; arquivos anteriores nao sao sobrescritos.")
    mode = payload.get("mode", "initial")
    if mode == "initial":
        for key in ["title", "source_image_path"]:
            if not payload.get(key):
                raise ValueError(f"Campo inicial ausente: {key}")
        layout = create_layout_from_template(payload, template)
    elif mode == "revision":
        layout = copy.deepcopy(payload.get("layout_spec") or {})
        for section in ("headline", "subtitle", "cta", "safety"):
            layout[section] = merge_defaults(layout.get(section) or {}, template[section])
        layout.update({"schema_version": "2.1", "content_id": payload["content_id"], "version_id": payload["version_id"], "version_label": payload["version_label"]})
        layout["output"] = {"path": payload["output_path"], "format": "PNG", "width": 1080, "height": 1080}
    else:
        raise ValueError(f"Modo de renderizacao invalido: {mode}")
    render_result = render_from_layout_spec(layout, project_root, output_path)
    layout["output"].update({"sha256": render_result["checksum_sha256"]})
    spec_path.parent.mkdir(parents=True, exist_ok=True)
    with spec_path.open("x", encoding="utf-8") as handle:
        json.dump(layout, handle, ensure_ascii=False, indent=2)
    return {"width": 1080, "height": 1080, "format": "PNG", "checksum_sha256": render_result["checksum_sha256"], "layout_spec": layout, "mode": mode, "warnings": render_result["warnings"], "validation": render_result["validation"], "layout_resolution_ms": render_result["layout_resolution_ms"], "render_ms": render_result["render_ms"]}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--template-dir", required=True)
    parser.add_argument("--result", required=True)
    args = parser.parse_args()
    payload = load_json(Path(args.input))
    if payload.get("renderer", "local") != "local":
        raise ValueError("Somente ART_RENDERER=local esta implementado.")
    template_id = payload.get("template_id")
    if not template_id or not template_id.replace("-", "").isalnum():
        raise ValueError("template_id invalido.")
    template_path = (Path(args.template_dir) / f"{template_id}.json").resolve()
    if not template_path.is_file():
        raise FileNotFoundError(f"Template inexistente: {template_path}")
    result = render_local(payload, load_json(template_path), Path(args.project_root).resolve())
    with Path(args.result).open("w", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False)


if __name__ == "__main__":
    main()
