#!/bin/bash
# --workers 1: the SSE transport keeps per-session state in-process, so
# multiple worker processes would split client sessions unpredictably across
# them. Scale the App Service Plan (instance count/SKU) instead of workers.
gunicorn main:app --worker-class uvicorn.workers.UvicornWorker --workers 1 --bind 0.0.0.0:${PORT:-8001} --timeout 600

