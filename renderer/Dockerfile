FROM python:3.12.11-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PROJECT_ROOT=/app \
    TEMPLATE_DIR=/app/templates

RUN apt-get update \
    && apt-get install -y --no-install-recommends fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/renderer
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY apply_changes.py render_content.py service.py test_phase63.py ./

EXPOSE 8000
CMD ["uvicorn", "service:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
