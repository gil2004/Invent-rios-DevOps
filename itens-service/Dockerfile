FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY itens-service/app.py .

RUN useradd -m appuser && mkdir /data && chown appuser /data
USER appuser

EXPOSE 5002
CMD ["gunicorn", "-b", "0.0.0.0:5002", "app:app"]