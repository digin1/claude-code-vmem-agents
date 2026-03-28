# ChromaDB Service Setup

Cortex uses ChromaDB as its vector database for semantic memory search. It runs as a systemd user service.

## Service Details

- **Host:** localhost
- **Port:** 8100
- **Data path:** `~/.claude/cortex-db`
- **Binary:** `~/.local/bin/chroma`

## Install ChromaDB

```bash
pip install chromadb
```

## Systemd User Service

Create `~/.config/systemd/user/cortex-chromadb.service`:

```ini
[Unit]
Description=Cortex ChromaDB Server
After=network.target

[Service]
Type=simple
ExecStart=%h/.local/bin/chroma run --path %h/.claude/cortex-db --host localhost --port 8100
Restart=on-failure
RestartSec=3
Environment=ONNXRUNTIME_DISABLE_TELEMETRY=1

[Install]
WantedBy=default.target
```

## Enable and Start

```bash
systemctl --user daemon-reload
systemctl --user enable cortex-chromadb.service
systemctl --user start cortex-chromadb.service
```

## Verify

```bash
systemctl --user status cortex-chromadb.service
curl -s http://localhost:8100/api/v1/heartbeat
```

## Troubleshooting

- **Service won't start:** Check `chroma` is installed: `which chroma` or `pip install chromadb`
- **Port conflict:** Change `--port 8100` to another port and update `lib/chroma_client.py`
- **Data corruption:** Stop service, remove `~/.claude/cortex-db`, restart (memories will be lost)
- **Logs:** `journalctl --user -u cortex-chromadb.service -f`
