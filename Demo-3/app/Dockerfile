FROM python:3.11-alpine
LABEL demo3.tier="app"

WORKDIR /app

RUN apk add --no-cache gcc musl-dev postgresql-dev curl

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 3001

HEALTHCHECK --interval=2s --timeout=3s --retries=5 \
    CMD curl -f http://localhost:3001/health || exit 1

CMD ["python", "app.py"]
