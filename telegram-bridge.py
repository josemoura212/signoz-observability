"""Webhook bridge SigNoz -> Telegram com diferenciacao por prioridade.

Mapeia o threshold_name (info/warning/critical) que vem do SigNoz para
3 tiers visuais distintos:

  🟢 P3 OBSERVE   info       -> tendencia, sem urgencia, baixa frequencia
  🟡 P2 WARN      warning    -> investigar quando der
  🔴 P1 CRITICAL  critical   -> acao imediata

O webhook tambem recebe alertas de resolucao (status=resolved) - eles
chegam com checkmark independente do tier.
"""
import json
import os

import requests
from flask import Flask, request

app = Flask(__name__)

BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
CHAT_IDS = [cid.strip() for cid in os.environ["TELEGRAM_CHAT_IDS"].split(",") if cid.strip()]
TELEGRAM_API = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"


TIER_FORMAT = {
    "critical": {"emoji": "🔴", "label": "P1 CRITICAL"},
    "warning":  {"emoji": "🟡", "label": "P2 WARN"},
    "info":     {"emoji": "🟢", "label": "P3 OBSERVE"},
}
RESOLVED_EMOJI = "✅"
UNKNOWN_EMOJI = "⚪"


def resolve_tier(labels: dict) -> tuple[str, str]:
    """Identifica o tier do alerta retornando (emoji, label).

    SigNoz envia o threshold tier em `threshold.name` (com dot, nao underscore).
    Severity da rule e sempre o tier mais alto (geralmente critical), por isso
    threshold.name e mais confiavel para diferenciar P3/P2/P1 individualmente.
    """
    # SigNoz envia chaves com dot literal (threshold.name, host.name, etc).
    threshold_name = (labels.get("threshold.name") or labels.get("threshold_name") or "").lower()
    severity = (labels.get("severity") or "").lower()

    # Preferencia: threshold.name (tier do alerta que disparou) > severity (highest da rule)
    if threshold_name in TIER_FORMAT:
        return _format_for(threshold_name)
    if severity in TIER_FORMAT:
        return _format_for(severity)
    return UNKNOWN_EMOJI, "UNKNOWN"


def _format_for(severity: str) -> tuple[str, str]:
    fmt = TIER_FORMAT[severity]
    return fmt["emoji"], fmt["label"]


@app.route("/webhook", methods=["POST"])
def webhook():
    data = request.json or {}
    status = data.get("status", "unknown")
    alerts = data.get("alerts", [])

    for alert in alerts:
        labels = alert.get("labels", {}) or {}
        annotations = alert.get("annotations", {}) or {}

        name = labels.get("alertname", "Unknown")
        summary = annotations.get("summary", "")
        description = annotations.get("description", "")

        if status == "resolved":
            emoji, tier_label = RESOLVED_EMOJI, "RESOLVED"
        else:
            emoji, tier_label = resolve_tier(labels)

        header = f"{emoji} *{tier_label}* — {name}"
        lines = [header, f"Status: *{status}*"]

        if summary:
            lines.append(f"\n{summary}")
        if description:
            lines.append(f"\n{description}")

        # Labels relevantes: deixa o que ajuda no diagnostico, esconde ruido interno.
        skip = {
            "alertname", "severity", "threshold.name", "threshold_name",
            "priority", "tier_name", "ruleId", "ruleSource",
        }
        extra = {k: v for k, v in labels.items() if k not in skip}
        if extra:
            # Formata como key: value uma por linha (mais legivel que JSON denso)
            label_lines = "\n".join(f"  {k}: {v}" for k, v in sorted(extra.items()))
            lines.append(f"\n{label_lines}")

        text = "\n".join(lines)
        for chat_id in CHAT_IDS:
            requests.post(
                TELEGRAM_API,
                json={"chat_id": chat_id, "text": text, "parse_mode": "Markdown"},
                timeout=10,
            )

    return "ok", 200


@app.route("/health", methods=["GET"])
def health():
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
