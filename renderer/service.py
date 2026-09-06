#!/usr/bin/env python3
"""Internal HTTP service for safe layout changes and deterministic rendering."""

from __future__ import annotations

import logging
import os
import time
from pathlib import Path
from typing import Any

from fastapi import FastAPI
from pydantic import BaseModel, ConfigDict, Field
from PIL import Image

from apply_changes import apply_changes
from render_content import LayoutValidationError, load_json, render_local, resolve_project_path


logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("renderer-service")
PROJECT_ROOT = Path(os.environ.get("PROJECT_ROOT", "/app")).resolve()
TEMPLATE_DIR = Path(os.environ.get("TEMPLATE_DIR", "/app/templates")).resolve()
GENERATED_ROOT = (PROJECT_ROOT / "assets/generated").resolve()
ALLOWED_SOURCE_ROOTS = [(PROJECT_ROOT / "assets/generated").resolve(), (PROJECT_ROOT / "assets/brands").resolve()]


class ApplyRenderRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    content_id: str = Field(pattern=r"^CONTENT-\d{4}-\d{5}$")
    source_version_id: str
    version_id: str
    version_label: str = Field(pattern=r"^CONTENT-\d{4}-\d{5}-v\d+$")
    change_request_id: str
    client_id: str = Field(pattern=r"^[a-zA-Z0-9_-]+$")
    template_id: str = Field(pattern=r"^[a-zA-Z0-9_-]+$")
    renderer: str = "local"
    layout_spec: dict[str, Any]
    changes: list[dict[str, Any]] = Field(min_length=1, max_length=8)
    output_path: str
    layout_spec_path: str


class InitialRenderRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    content_id: str = Field(pattern=r"^CONTENT-\d{4}-\d{5}$")
    version_id: str
    version_label: str = Field(pattern=r"^CONTENT-\d{4}-\d{5}-v1$")
    client_id: str = Field(pattern=r"^[a-zA-Z0-9_-]+$")
    template_id: str = Field(pattern=r"^[a-zA-Z0-9_-]+$")
    renderer: str = "local"
    title: str = Field(min_length=1, max_length=240)
    subtitle: str = Field(default="", max_length=300)
    cta: str = Field(default="", max_length=120)
    source_image_path: str
    logo_path: str
    palette: list[str] = Field(min_length=1, max_length=20)
    output_path: str
    layout_spec_path: str


class ImageValidationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    content_id: str = Field(pattern=r"^CONTENT-\d{4}-\d{5}$")
    version_id: str
    source_image_path: str
    expected_width: int = Field(ge=1, le=4096)
    expected_height: int = Field(ge=1, le=4096)


def require_under(path_value: str, root: Path) -> Path:
    path = resolve_project_path(PROJECT_ROOT, path_value)
    if root != path and root not in path.parents:
        raise ValueError(f"Path fora do diretorio autorizado: {path_value}")
    return path


def validate_paths(request: ApplyRenderRequest) -> None:
    require_under(request.output_path, GENERATED_ROOT)
    require_under(request.layout_spec_path, GENERATED_ROOT)
    source_assets = request.layout_spec.get("source_assets") or {}
    for key in ("product_image", "logo"):
        value = source_assets.get(key)
        if not isinstance(value, str):
            raise ValueError(f"Source asset ausente: {key}")
        path = resolve_project_path(PROJECT_ROOT, value)
        if not any(root == path or root in path.parents for root in ALLOWED_SOURCE_ROOTS):
            raise ValueError(f"Source asset fora dos diretorios autorizados: {key}")


def validate_initial_paths(request: InitialRenderRequest) -> None:
    require_under(request.output_path, GENERATED_ROOT)
    require_under(request.layout_spec_path, GENERATED_ROOT)
    for key, value in (("product_image", request.source_image_path), ("logo", request.logo_path)):
        path = resolve_project_path(PROJECT_ROOT, value)
        if not any(root == path or root in path.parents for root in ALLOWED_SOURCE_ROOTS):
            raise ValueError(f"Source asset fora dos diretorios autorizados: {key}")
        if not path.is_file():
            raise FileNotFoundError(f"Source asset inexistente: {key}")


app = FastAPI(title="Social Media Renderer", docs_url=None, redoc_url=None, openapi_url=None)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/validate-image")
def validate_image(request: ImageValidationRequest) -> dict[str, Any]:
    try:
        source = require_under(request.source_image_path, GENERATED_ROOT)
        if not source.is_file() or source.stat().st_size == 0:
            raise FileNotFoundError("Imagem fonte ausente ou vazia.")
        with Image.open(source) as image:
            image.verify()
        with Image.open(source) as image:
            width, height, image_format = image.width, image.height, image.format
        if image_format != "PNG":
            raise ValueError("Formato de imagem invalido; esperado PNG.")
        if (width, height) != (request.expected_width, request.expected_height):
            raise ValueError(f"Dimensoes invalidas: {width}x{height}.")
        return {"status": "success", "content_id": request.content_id, "version_id": request.version_id, "source_image_path": request.source_image_path, "width": width, "height": height, "format": image_format}
    except Exception as exc:
        logger.exception("image validation failed content_id=%s version_id=%s", request.content_id, request.version_id)
        return {"status": "error", "content_id": request.content_id, "version_id": request.version_id, "source_image_path": request.source_image_path, "error": str(exc)}


@app.post("/render-initial")
def render_initial(request: InitialRenderRequest) -> dict[str, Any]:
    started = time.perf_counter()
    try:
        validate_initial_paths(request)
        template_path = (TEMPLATE_DIR / f"{request.template_id}.json").resolve()
        if TEMPLATE_DIR not in template_path.parents or not template_path.is_file():
            raise ValueError("Template nao autorizado ou inexistente.")
        payload = {
            "mode": "initial",
            "renderer": request.renderer,
            "template_id": request.template_id,
            "content_id": request.content_id,
            "version_id": request.version_id,
            "version_label": request.version_label,
            "client_id": request.client_id,
            "title": request.title,
            "subtitle": request.subtitle,
            "cta": request.cta,
            "source_image_path": request.source_image_path,
            "logo_path": request.logo_path,
            "palette": request.palette,
            "output_path": request.output_path,
            "layout_spec_path": request.layout_spec_path,
        }
        result = render_local(payload, load_json(template_path), PROJECT_ROOT)
        duration_ms = round((time.perf_counter() - started) * 1000)
        logger.info("initial render success content_id=%s version_id=%s duration_ms=%s", request.content_id, request.version_id, duration_ms)
        return {
            "status": "success",
            "content_id": request.content_id,
            "version_id": request.version_id,
            "version_label": request.version_label,
            "template_id": request.template_id,
            "renderer": request.renderer,
            "source_image_path": request.source_image_path,
            "output_path": request.output_path,
            "layout_spec_path": request.layout_spec_path,
            "width": result["width"],
            "height": result["height"],
            "format": result["format"],
            "checksum_sha256": result["checksum_sha256"],
            "layout_spec": result["layout_spec"],
            "warnings": result["warnings"],
            "validation": result["validation"],
            "layout_resolution_ms": result["layout_resolution_ms"],
            "render_ms": result["render_ms"],
            "duration_ms": duration_ms,
        }
    except Exception as exc:
        duration_ms = round((time.perf_counter() - started) * 1000)
        logger.exception("initial render failed content_id=%s version_id=%s duration_ms=%s", request.content_id, request.version_id, duration_ms)
        return {"status": "error", "error_code": getattr(exc, "error_code", "ART_RENDER_FAILED"), "content_id": request.content_id, "version_id": request.version_id, "error": str(exc), "validation": getattr(exc, "report", None), "duration_ms": duration_ms}


@app.post("/apply-and-render")
def apply_and_render(request: ApplyRenderRequest) -> dict[str, Any]:
    started = time.perf_counter()
    try:
        validate_paths(request)
        apply_payload = request.model_dump()
        applied = apply_changes(apply_payload)
        render_payload = {
            "mode": "revision",
            "renderer": request.renderer,
            "template_id": request.template_id,
            "content_id": request.content_id,
            "version_id": request.version_id,
            "version_label": request.version_label,
            "client_id": request.client_id,
            "output_path": request.output_path,
            "layout_spec_path": request.layout_spec_path,
            "layout_spec": applied["layout_spec"],
        }
        template_path = (TEMPLATE_DIR / f"{request.template_id}.json").resolve()
        if TEMPLATE_DIR not in template_path.parents or not template_path.is_file():
            raise ValueError("Template nao autorizado ou inexistente.")
        result = render_local(render_payload, load_json(template_path), PROJECT_ROOT)
        duration_ms = round((time.perf_counter() - started) * 1000)
        logger.info("render success content_id=%s version_id=%s duration_ms=%s", request.content_id, request.version_id, duration_ms)
        return {
            "status": "success",
            "content_id": request.content_id,
            "source_version_id": request.source_version_id,
            "version_id": request.version_id,
            "version_label": request.version_label,
            "change_request_id": request.change_request_id,
            "output_path": request.output_path,
            "layout_spec_path": request.layout_spec_path,
            "width": result["width"],
            "height": result["height"],
            "format": result["format"],
            "checksum_sha256": result["checksum_sha256"],
            "layout_spec": result["layout_spec"],
            "applied_changes": applied["applied_changes"],
            "warnings": result["warnings"],
            "validation": result["validation"],
            "layout_resolution_ms": result["layout_resolution_ms"],
            "render_ms": result["render_ms"],
            "duration_ms": duration_ms,
        }
    except Exception as exc:  # controlled response lets n8n persist compensation
        duration_ms = round((time.perf_counter() - started) * 1000)
        logger.exception("render failed content_id=%s version_id=%s duration_ms=%s", request.content_id, request.version_id, duration_ms)
        return {
            "status": "error",
            "content_id": request.content_id,
            "version_id": request.version_id,
            "change_request_id": request.change_request_id,
            "error_code": getattr(exc, "error_code", "ART_RENDER_FAILED"),
            "error": str(exc),
            "validation": getattr(exc, "report", None),
            "duration_ms": duration_ms,
        }
