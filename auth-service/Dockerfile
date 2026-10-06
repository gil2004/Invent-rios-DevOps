FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY auth-service/app.py .

RUN useradd -m appuser
USER appuser

EXPOSE 5001
CMD ["gunicorn", "-b", "0.0.0.0:5001", "app:app"]