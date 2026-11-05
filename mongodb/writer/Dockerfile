# ytperf-writer - mongodb/run.sh's writer: one node's increments of its own path of the
# one document, and the document's counters read back (doc.py)
FROM python:3.12-slim
RUN pip install --no-cache-dir pymongo==4.10.1
COPY doc.py /opt/doc.py
ENTRYPOINT ["python3", "/opt/doc.py"]
