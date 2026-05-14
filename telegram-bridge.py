"""Notification bridge SigNoz -> Telegram + Slack.

Dois endpoints separados, cada um corresponde a UM canal de notificacao
configurado no SigNoz UI -> Settings -> Notification Channels (tipo "webhook"):

  POST /webhook/telegram   <- canal "Telegram" do SigNoz
  POST /webhook/slack      <- canal "Slack" do SigNoz

Cada rule no SigNoz escolhe quais canais quer disparar — o bridge so
formata e roteia para o provider correto.

Convencao visual:
  Tier         Telegram emoji   Slack color
  P3 info      🟢                #2eb886 (verde)
  P2 warning   🟡                #ecb22e (amarelo)
  P1 critical  🔴                #e01e5a (vermelho)
  resolved     ✅                #36a64f (verde claro)

P3 (info) e descartado em ambos endpoints — fica apenas registrado no SigNoz UI.
"""
import os

import requests
from flask import Flask, request

app = Flask(__name__)

# ============================================================
# Telegram
# ============================================================
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_IDS = [
    cid.strip()
    for cid in os.environ.get("TELEGRAM_CHAT_IDS", "").split(",")
    if cid.strip()
]
TELEGRAM_API = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"

# ============================================================
# Slack
# ============================================================
SLACK_BOT_TOKEN = os.environ.get("SLACK_BOT_TOKEN", "")
SLACK_CHANNEL = os.environ.get("SLACK_CHANNEL", "")
SLACK_API = "https://slack.com/api/chat.postMessage"

# ============================================================
# Visual
# ============================================================
TIER_FORMAT = {
    "critical": {"emoji": "🔴", "label": "P1 CRITICAL", "color": "#e01e5a"},
    "warning":  {"emoji": "🟡", "label": "P2 WARN",     "color": "#ecb22e"},
    "info":     {"emoji": "🟢", "label": "P3 OBSERVE",  "color": "#2eb886"},
}
RESOLVED_EMOJI = "✅"
RESOLVED_COLOR = "#36a64f"
RESOLVED_LABEL = "RESOLVED"
UNKNOWN_EMOJI = "⚪"

# Labels que viram ruido na mensagem final (chaves internas do SigNoz)
INTERNAL_LABELS = {
    "alertname", "severity", "threshold.name", "threshold_name",
    "priority", "tier_name", "ruleId", "ruleSource",
}


# ============================================================
# Helpers
# ============================================================
def get_threshold_name(labels: dict) -> str:
    """Le threshold.name (chave com dot literal) com fallback para severity."""
    return (
        labels.get("threshold.name")
        or labels.get("threshold_name")
        or labels.get("severity")
        or ""
    ).lower()


def tier_visuals(status: str, threshold_name: str) -> tuple[str, str, str]:
    """Retorna (emoji, label, color) baseado em status + threshold tier."""
    if status == "resolved":
        return RESOLVED_EMOJI, RESOLVED_LABEL, RESOLVED_COLOR
    fmt = TIER_FORMAT.get(threshold_name)
    if fmt:
        return fmt["emoji"], fmt["label"], fmt["color"]
    return UNKNOWN_EMOJI, "UNKNOWN", "#808080"


def extract_extra_labels(labels: dict) -> dict:
    return {k: v for k, v in labels.items() if k not in INTERNAL_LABELS}


# ============================================================
# Telegram sender
# ============================================================
def send_telegram(name: str, status: str, threshold_name: str,
                  summary: str, description: str, labels: dict) -> None:
    if not (TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_IDS):
        return

    emoji, tier_label, _ = tier_visuals(status, threshold_name)

    header = f"{emoji} *{tier_label}* — {name}"
    lines = [header, f"Status: *{status}*"]

    if summary:
        lines.append(f"\n{summary}")
    if description:
        lines.append(f"\n{description}")

    extra = extract_extra_labels(labels)
    if extra:
        label_lines = "\n".join(f"  {k}: {v}" for k, v in sorted(extra.items()))
        lines.append(f"\n{label_lines}")

    text = "\n".join(lines)
    for chat_id in TELEGRAM_CHAT_IDS:
        try:
            requests.post(
                TELEGRAM_API,
                json={"chat_id": chat_id, "text": text, "parse_mode": "Markdown"},
                timeout=10,
            )
        except Exception as e:
            print(f"telegram error: {e}", flush=True)


# ============================================================
# Slack sender
# ============================================================
def send_slack(name: str, status: str, threshold_name: str,
               summary: str, description: str, labels: dict) -> None:
    if not (SLACK_BOT_TOKEN and SLACK_CHANNEL):
        return

    emoji, tier_label, color = tier_visuals(status, threshold_name)
    main_text = f"{emoji} *{tier_label}* — {name}"

    body_lines = [f"*Status:* {status}"]
    if summary:
        body_lines.append(summary)
    if description:
        body_lines.append(description)

    extra = extract_extra_labels(labels)
    if extra:
        body_lines.append("")
        body_lines.append("*Labels:*")
        for k, v in sorted(extra.items()):
            body_lines.append(f"• `{k}`: {v}")

    payload = {
        "channel": SLACK_CHANNEL,
        "text": main_text,
        "attachments": [{
            "color": color,
            "text": "\n".join(body_lines),
            "mrkdwn_in": ["text"],
        }],
    }
    try:
        r = requests.post(
            SLACK_API,
            headers={
                "Authorization": f"Bearer {SLACK_BOT_TOKEN}",
                "Content-Type": "application/json; charset=utf-8",
            },
            json=payload,
            timeout=10,
        )
        body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
        if not body.get("ok"):
            print(f"slack error: status={r.status_code} body={r.text}", flush=True)
    except Exception as e:
        print(f"slack exception: {e}", flush=True)


# ============================================================
# Endpoints (1 por canal SigNoz)
# ============================================================
def _dispatch(alerts: list, status: str, sender) -> None:
    for alert in alerts:
        labels = alert.get("labels", {}) or {}
        annotations = alert.get("annotations", {}) or {}

        threshold_name = get_threshold_name(labels)
        if threshold_name == "info":
            continue  # P3 nao notifica em nenhum canal externo

        name = labels.get("alertname", "Unknown")
        summary = annotations.get("summary", "")
        description = annotations.get("description", "")

        sender(name, status, threshold_name, summary, description, labels)


@app.route("/webhook", methods=["POST"])
@app.route("/webhook/telegram", methods=["POST"])
def webhook_telegram():
    data = request.json or {}
    _dispatch(data.get("alerts", []), data.get("status", "unknown"), send_telegram)
    return "ok", 200


@app.route("/webhook/slack", methods=["POST"])
def webhook_slack():
    data = request.json or {}
    _dispatch(data.get("alerts", []), data.get("status", "unknown"), send_slack)
    return "ok", 200


@app.route("/health", methods=["GET"])
def health():
    return {
        "status": "ok",
        "telegram_enabled": bool(TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_IDS),
        "slack_enabled": bool(SLACK_BOT_TOKEN and SLACK_CHANNEL),
    }, 200


@app.route("/test/<channel>", methods=["POST"])
def test_channel(channel: str):
    """Envia um alerta sintetico de teste no canal escolhido.

    Uso:
        curl -X POST http://bridge:5001/test/telegram
        curl -X POST http://bridge:5001/test/slack
    """
    fake_labels = {
        "alertname": "TEST - Bridge",
        "severity": "critical",
        "threshold.name": "critical",
        "category": "infrastructure",
        "metric": "cpu",
        "host.name": "unnichat-docker-01",
    }
    sender = {"telegram": send_telegram, "slack": send_slack}.get(channel)
    if not sender:
        return {"error": f"unknown channel: {channel}"}, 400
    sender(
        "TEST - Bridge",
        "firing",
        "critical",
        "Teste do bridge",
        f"Mensagem de teste enviada via /test/{channel}",
        fake_labels,
    )
    return {"sent": channel}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
