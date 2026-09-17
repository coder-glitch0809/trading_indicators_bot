FROM python:3.11-slim
WORKDIR /app
COPY server/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY server ./server
WORKDIR /app/server
EXPOSE 8080
CMD ["python", "server.py"]
