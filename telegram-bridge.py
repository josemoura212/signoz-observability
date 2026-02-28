import os
import json
import requests
from flask import Flask, request

app = Flask(__name__)

BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
CHAT_ID = os.environ["TELEGRAM_CHAT_ID"]
TELEGRAM_API = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"


@app.route("/webhook", methods=["POST"])
def webhook():
    data = request.json
    status = data.get("status", "unknown")
    alerts = data.get("alerts", [])

    for alert in alerts:
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})

        name = labels.get("alertname", "Unknown")
        severity = labels.get("severity", "info")
        summary = annotations.get("summary", "")
        description = annotations.get("description", "")

        emoji = "\U0001f534" if status == "firing" else "\u2705"
        lines = [f"{emoji} *{name}* [{severity.upper()}]", f"Status: *{status}*"]

        if summary:
            lines.append(f"Summary: {summary}")
        if description:
            lines.append(f"Description: {description}")

        extra = {k: v for k, v in labels.items() if k not in ("alertname", "severity")}
        if extra:
            lines.append(f"\nLabels: `{json.dumps(extra)}`")

        requests.post(
            TELEGRAM_API,
            json={"chat_id": CHAT_ID, "text": "\n".join(lines), "parse_mode": "Markdown"},
        )

    return "ok", 200


@app.route("/health", methods=["GET"])
def health():
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
