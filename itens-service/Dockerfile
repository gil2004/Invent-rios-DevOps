FROM python:3.12-slim

# Por defeito instala só o necessário para PRD; em DEV usa-se requirements-dev.txt
ARG REQUIREMENTS=requirements-prd.txt

WORKDIR /app

COPY requirements-*.txt ./
RUN pip install --no-cache-dir -r ${REQUIREMENTS}

COPY itens-service/app.py .

RUN useradd -m appuser && mkdir /data && chown appuser /data
USER appuser

EXPOSE 5002
CMD ["gunicorn", "-b", "0.0.0.0:5002", "app:app"]