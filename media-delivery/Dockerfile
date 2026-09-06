FROM python:3.12.11-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY service.py ./
EXPOSE 8080
CMD ["uvicorn","service:app","--host","0.0.0.0","--port","8080","--no-access-log"]
