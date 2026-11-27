FROM python:3.12-slim
# torch (CPU build, ~210MB). If the download keeps timing out inside Docker, run `make guard-wheel` once:
# it fetches the wheel on the host with a resumable curl, and pip below picks it up from /wheels.
COPY wheels/ /wheels/
RUN pip install --no-cache-dir --retries 10 --timeout 120 --find-links /wheels \
    --extra-index-url https://download.pytorch.org/whl/cpu "torch==2.15.0"
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --retries 10 --timeout 120 -r /tmp/requirements.txt
RUN useradd -u 10001 -m app
WORKDIR /srv
COPY app.py .
ENV HF_HOME=/tmp/hf HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 MODEL_DIR=/model
USER 10001
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
