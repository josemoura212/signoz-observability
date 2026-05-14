"""Notification bridge SigNoz -> Telegram + Slack com dedup e agregacao.

Dois endpoints separados, cada um corresponde a UM canal de notificacao
configurado no SigNoz UI -> Settings -> Notification Channels (tipo "webhook"):

  POST /webhook/telegram   <- canal "Telegram" do SigNoz
  POST /webhook/slack      <- canal "SlackWebhook" do SigNoz

Comportamento:
1. P3 (info) e descartado em ambos endpoints — fica apenas no SigNoz UI.
2. Multi-threshold dedup por host: se o mesmo host cruza P2 e P1
   simultaneamente, envia apenas o tier mais alto (P1).
3. Agregacao por (alertname, tier): consolida varios hosts no mesmo alerta
   numa unica mensagem com lista. Reduz drasticamente o spam quando uma
   metrica de infra dispara em multiplos hosts ao mesmo tempo.

Tiers visuais:
  P3 info      🟢 / #2eb886 (verde)       -> nao enviado
  P2 warning   🟡 / #ecb22e (amarelo)
  P1 critical  🔴 / #e01e5a (vermelho)
  resolved     ✅ / #36a64f (verde claro)
"""
import os
import re

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

INTERNAL_LABELS = {
    "alertname", "severity", "threshold.name", "threshold_name",
    "priority", "tier_name", "ruleId", "ruleSource",
}

TIER_PRIORITY = {"critical": 3, "warning": 2, "info": 1}

# Regex para extrair valor numerico do description (ex: "Valor: 27.3%")
VALUE_REGEX = re.compile(r"Valor:\s*([0-9.]+\s*\S*)", re.IGNORECASE)


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
    if status == "resolved":
        return RESOLVED_EMOJI, RESOLVED_LABEL, RESOLVED_COLOR
    fmt = TIER_FORMAT.get(threshold_name)
    if fmt:
        return fmt["emoji"], fmt["label"], fmt["color"]
    return UNKNOWN_EMOJI, "UNKNOWN", "#808080"


def extract_value(description: str) -> str:
    """Extrai trecho 'X%' ou 'X ms' do description. Retorna '' se nao achar."""
    if not description:
        return ""
    m = VALUE_REGEX.search(description)
    return m.group(1).strip() if m else ""


def extract_common_labels(items: list[dict]) -> dict:
    """Retorna apenas labels presentes em TODOS items com o mesmo valor.
    Ignora chaves internas e host.name (que varia por item)."""
    if not items:
        return {}
    skip = INTERNAL_LABELS | {"host.name"}
    first = {
        k: v
        for k, v in (items[0].get("labels") or {}).items()
        if k not in skip
    }
    for it in items[1:]:
        labels = it.get("labels") or {}
        for k in list(first.keys()):
            if labels.get(k) != first[k]:
                first.pop(k)
    return first


# ============================================================
# Senders (recebem lista de items agregados)
# ============================================================
def send_telegram(alert_name: str, status: str, threshold_name: str,
                  items: list[dict]) -> None:
    if not (TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_IDS):
        return

    emoji, tier_label, _ = tier_visuals(status, threshold_name)
    header = f"{emoji} *{tier_label}* — {alert_name}"

    lines = [header, f"Status: *{status}*"]

    # Lista de hosts afetados
    if len(items) == 1:
        it = items[0]
        host = (it.get("labels") or {}).get("host.name") or "?"
        value = extract_value(it.get("description", ""))
        suffix = f" — {value}" if value else ""
        lines.append(f"\nHost: *{host}*{suffix}")
        if it.get("description"):
            lines.append(f"\n{it['description']}")
    else:
        lines.append(f"\n{len(items)} hosts afetados:")
        for it in items:
            host = (it.get("labels") or {}).get("host.name") or "?"
            value = extract_value(it.get("description", ""))
            suffix = f" — {value}" if value else ""
            lines.append(f"  • {host}{suffix}")

    common = extract_common_labels(items)
    if common:
        lines.append("")
        for k, v in sorted(common.items()):
            lines.append(f"  {k}: {v}")

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


def send_slack(alert_name: str, status: str, threshold_name: str,
               items: list[dict]) -> None:
    if not (SLACK_BOT_TOKEN and SLACK_CHANNEL):
        return

    emoji, tier_label, color = tier_visuals(status, threshold_name)
    main_text = f"{emoji} *{tier_label}* — {alert_name}"

    body_lines = [f"*Status:* {status}"]

    if len(items) == 1:
        it = items[0]
        host = (it.get("labels") or {}).get("host.name") or "?"
        value = extract_value(it.get("description", ""))
        suffix = f" — {value}" if value else ""
        body_lines.append(f"*Host:* `{host}`{suffix}")
        if it.get("description"):
            body_lines.append(it["description"])
    else:
        body_lines.append(f"*{len(items)} hosts afetados:*")
        for it in items:
            host = (it.get("labels") or {}).get("host.name") or "?"
            value = extract_value(it.get("description", ""))
            suffix = f" — {value}" if value else ""
            body_lines.append(f"• `{host}`{suffix}")

    common = extract_common_labels(items)
    if common:
        body_lines.append("")
        body_lines.append("*Labels:*")
        for k, v in sorted(common.items()):
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
# Dispatch: dedup por host + agrega por (alertname, tier)
# ============================================================
def _dispatch(alerts: list, status: str, sender) -> None:
    # Passo 1: dedup por (alertname, host) — mantem so o tier mais alto
    by_host: dict[tuple[str, str], dict] = {}
    for alert in alerts:
        labels = alert.get("labels", {}) or {}
        annotations = alert.get("annotations", {}) or {}
        threshold_name = get_threshold_name(labels)
        if threshold_name == "info":
            continue  # P3 nunca notifica fora do SigNoz UI

        alertname = labels.get("alertname", "Unknown")
        host = labels.get("host.name", "")
        key = (alertname, host)
        prio = TIER_PRIORITY.get(threshold_name, 0)

        current = by_host.get(key)
        if not current or prio > current["_prio"]:
            by_host[key] = {
                "_prio": prio,
                "threshold_name": threshold_name,
                "labels": labels,
                "description": annotations.get("description", ""),
                "summary": annotations.get("summary", ""),
            }

    # Passo 2: agrupa por (alertname, tier) com a lista de hosts afetados
    by_group: dict[tuple[str, str], list[dict]] = {}
    for (alertname, _host), entry in by_host.items():
        group_key = (alertname, entry["threshold_name"])
        by_group.setdefault(group_key, []).append(entry)

    # Passo 3: envia uma mensagem por grupo
    for (alertname, threshold_name), items in by_group.items():
        # ordena por host pra mensagem ficar consistente
        items.sort(key=lambda x: (x.get("labels") or {}).get("host.name", ""))
        sender(alertname, status, threshold_name, items)


# ============================================================
# Endpoints (1 por canal SigNoz)
# ============================================================
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
    """Envia um alerta sintetico com 3 hosts agrupados (P1 critical).

    Uso:
        curl -X POST http://bridge:5001/test/telegram
        curl -X POST http://bridge:5001/test/slack
    """
    fake_items = [
        {
            "labels": {"alertname": "TEST - Bridge", "category": "infrastructure",
                       "metric": "cpu", "host.name": h, "threshold.name": "critical"},
            "description": f"CPU em {h} no nivel critical. Valor: {v}",
            "summary": "",
        }
        for h, v in [
            ("unnichat-docker-01", "96.4%"),
            ("unnichat-docker-03", "98.1%"),
            ("unnichat-db-01", "94.7%"),
        ]
    ]
    sender = {"telegram": send_telegram, "slack": send_slack}.get(channel)
    if not sender:
        return {"error": f"unknown channel: {channel}"}, 400
    sender("TEST - Bridge", "firing", "critical", fake_items)
    return {"sent": channel, "items": len(fake_items)}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
