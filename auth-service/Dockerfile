FROM python:3.12-alpine

# Por defeito instala só o necessário para PRD; em DEV usa-se requirements-dev.txt
ARG REQUIREMENTS=requirements-prd.txt

WORKDIR /app

# Correções de segurança do sistema
RUN apk upgrade --no-cache

# Instala as bibliotecas e remove o pip (só serve para instalar; a app não precisa dele para correr)
COPY requirements-*.txt ./
RUN pip install --no-cache-dir -r ${REQUIREMENTS} && pip uninstall -y pip

COPY auth-service/app.py .

RUN adduser -D appuser
USER appuser

EXPOSE 5001
CMD ["gunicorn", "-b", "0.0.0.0:5001", "app:app"]