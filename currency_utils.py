"""Small, dependency-free currency detection/conversion helper for InsightFlow."""
from __future__ import annotations

import json
import re
import time
import urllib.parse
import urllib.request
from typing import Any

CURRENCY_ALIASES = {
    "usd": "USD", "dollar": "USD", "dollars": "USD", "$": "USD",
    "inr": "INR", "rupee": "INR", "rupees": "INR", "₹": "INR",
    "rub": "RUB", "ruble": "RUB", "rubles": "RUB", "rubel": "RUB", "rubels": "RUB", "rouble": "RUB", "roubles": "RUB", "₽": "RUB",
    "bdt": "BDT", "taka": "BDT", "৳": "BDT",
    "eur": "EUR", "euro": "EUR", "euros": "EUR", "€": "EUR",
    "gbp": "GBP", "pound": "GBP", "pounds": "GBP", "£": "GBP",
    "aed": "AED", "dirham": "AED", "dirhams": "AED", "د.إ": "AED",
    "sgd": "SGD", "singapore dollar": "SGD", "s$": "SGD",
    "jpy": "JPY", "yen": "JPY", "¥": "JPY",
    "cny": "CNY", "yuan": "CNY", "renminbi": "CNY", "元": "CNY",
    "cad": "CAD", "australian dollar": "AUD", "aud": "AUD",
}
SYMBOL_BY_CODE = {
    "USD": "$", "INR": "₹", "RUB": "₽", "BDT": "৳", "EUR": "€", "GBP": "£",
    "AED": "د.إ", "SGD": "S$", "JPY": "¥", "CNY": "¥", "CAD": "C$", "AUD": "A$",
}
FORMAT_BY_CODE = {
    "USD": '$#,##0.00', "INR": '₹#,##0.00', "RUB": '₽#,##0.00', "BDT": '৳#,##0.00',
    "EUR": '€#,##0.00', "GBP": '£#,##0.00', "AED": 'د.إ#,##0.00', "SGD": 'S$#,##0.00',
    "JPY": '¥#,##0', "CNY": '¥#,##0.00', "CAD": 'C$#,##0.00', "AUD": 'A$#,##0.00',
}
_CACHE: dict[str, tuple[float, dict[str, float]]] = {}


def normalize_currency(value: str | None) -> str | None:
    if not value:
        return None
    s = str(value).strip().lower()
    if s in CURRENCY_ALIASES:
        return CURRENCY_ALIASES[s]
    # Prefer explicit 3-letter codes embedded in natural language.
    m = re.search(r"\b(usd|inr|rub|bdt|eur|gbp|aed|sgd|jpy|cny|cad|aud)\b", s)
    return m.group(1).upper() if m else None


def extract_target_currency(text: str) -> str | None:
    text = str(text or "")
    # Explicit target language is deliberately required; merely mentioning
    # "currency" must not trigger conversion.
    m = re.search(r"\b(?:in|to|into|convert(?:ed|ing)?\s+(?:to|into)?)\s+([A-Za-z]{3}|[$€£₹₽৳¥])\b", text, re.I)
    if m:
        return normalize_currency(m.group(1))
    # Common "categorize currency INR" phrasing.
    m = re.search(r"\bcurrency\s+(?:as|in|to|into)\s+([A-Za-z]{3}|[$€£₹₽৳¥])\b", text, re.I)
    return normalize_currency(m.group(1)) if m else None


def detect_currency_from_value(value: Any) -> str | None:
    if value is None:
        return None
    s = str(value).strip()
    low = s.lower()
    # Explicit codes/names first.
    for token, code in sorted(CURRENCY_ALIASES.items(), key=lambda x: len(x[0]), reverse=True):
        if len(token) > 1 and re.search(r"(?<![a-z])" + re.escape(token) + r"(?![a-z])", low):
            return code
    for symbol, code in [("₹", "INR"), ("$", "USD"), ("₽", "RUB"), ("৳", "BDT"), ("€", "EUR"), ("£", "GBP"), ("¥", "JPY")]:
        if symbol in s:
            return code
    return None


def parse_amount(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    s = str(value).strip().replace(',', '')
    m = re.search(r"[-+]?\d+(?:\.\d+)?", s)
    return float(m.group(0)) if m else None


def _fetch_rates(base: str) -> dict[str, float]:
    now = time.time()
    cached = _CACHE.get(base)
    if cached and now - cached[0] < 3600:
        return cached[1]
    url = "https://open.er-api.com/v6/latest/" + urllib.parse.quote(base)
    with urllib.request.urlopen(url, timeout=8) as response:
        payload = json.loads(response.read().decode("utf-8"))
    rates = payload.get("rates") or {}
    if not isinstance(rates, dict):
        raise RuntimeError(f"No exchange rates returned for {base}.")
    rates = {str(k).upper(): float(v) for k, v in rates.items() if isinstance(v, (int, float))}
    _CACHE[base] = (now, rates)
    return rates


def convert_amount(amount: float, source: str, target: str) -> float:
    source = normalize_currency(source) or source.upper()
    target = normalize_currency(target) or target.upper()
    if source == target:
        return amount
    rates = _fetch_rates(source)
    if target not in rates:
        raise RuntimeError(f"Exchange rate {source}->{target} is unavailable.")
    return amount * rates[target]


def currency_format(code: str) -> str:
    return FORMAT_BY_CODE.get(code.upper(), '#,##0.00')
