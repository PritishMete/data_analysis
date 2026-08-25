"""Small, dependency-free currency detection/conversion helper for InsightFlow."""
from __future__ import annotations

import json
import re
import time
import urllib.parse
import urllib.request
from typing import Any

CURRENCY_ALIASES = {
    "usd": "USD", "us dollar": "USD", "us dollars": "USD", "us$": "USD", "$": "USD",
    "inr": "INR", "rs": "INR", "rs.": "INR", "rupee": "INR", "rupees": "INR", "₹": "INR",
    "rub": "RUB", "ruble": "RUB", "rubles": "RUB", "rubel": "RUB", "rubels": "RUB", "rouble": "RUB", "roubles": "RUB", "₽": "RUB",
    "bdt": "BDT", "taka": "BDT", "৳": "BDT",
    "eur": "EUR", "euro": "EUR", "euros": "EUR", "€": "EUR",
    "gbp": "GBP", "pound": "GBP", "pounds": "GBP", "£": "GBP",
    "aed": "AED", "dirham": "AED", "dirhams": "AED", "د.إ": "AED",
    "sgd": "SGD", "singapore dollar": "SGD", "singapore dollars": "SGD", "s$": "SGD",
    "jpy": "JPY", "yen": "JPY", "¥": "JPY",
    "cny": "CNY", "yuan": "CNY", "renminbi": "CNY", "元": "CNY",
    "cad": "CAD", "canadian dollar": "CAD", "canadian dollars": "CAD", "c$": "CAD",
    "aud": "AUD", "australian dollar": "AUD", "australian dollars": "AUD", "a$": "AUD",
    "hkd": "HKD", "hong kong dollar": "HKD", "hong kong dollars": "HKD", "hk$": "HKD",
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
    m = re.search(r"\b(usd|inr|rub|bdt|eur|gbp|aed|sgd|jpy|cny|cad|aud|c\$|s\$)\b", s)
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


def has_currency_conversion_intent(text: str) -> bool:
    """Return True only when the user explicitly asks for conversion.

    Simply mentioning a target currency code should not be treated as a
    conversion request; the request must include a conversion verb/phrase.
    """
    text = str(text or "")
    return bool(re.search(
        r"\b(?:convert|change|exchange|transform|express|denominate)\b.*\bcurrenc(?:y|ies)\b|"
        r"\bcurrenc(?:y|ies)\b.*\b(?:convert|change|exchange|transform|express|denominate)\b|"
        r"\bconvert\b.*\b(?:to|into)\b",
        text,
        re.I,
    ))


def detect_currency_from_value(value: Any) -> str | None:
    if value is None:
        return None
    s = str(value).strip()
    low = s.lower()
    ordered_patterns: list[tuple[str, str, bool]] = [
        (r"us\$", "USD", True),
        (r"\bus dollar(?:s)?\b", "USD", True),
        (r"\busd\b", "USD", True),
        (r"s\$", "SGD", True),
        (r"\bsingapore dollar(?:s)?\b", "SGD", True),
        (r"\bsgd\b", "SGD", True),
        (r"c\$", "CAD", True),
        (r"\bcanadian dollar(?:s)?\b", "CAD", True),
        (r"\bcad\b", "CAD", True),
        (r"a\$", "AUD", True),
        (r"\baustralian dollar(?:s)?\b", "AUD", True),
        (r"\baud\b", "AUD", True),
        (r"hk\$", "HKD", True),
        (r"\bhong kong dollar(?:s)?\b", "HKD", True),
        (r"\bhkd\b", "HKD", True),
        (re.escape("د.إ"), "AED", True),
        (r"\baed\b", "AED", True),
        (r"\bdirham(?:s)?\b", "AED", True),
        (r"₹", "INR", False),
        (r"\binr\b", "INR", True),
        (r"\brs\.?\b", "INR", True),
        (r"\brupee(?:s)?\b", "INR", True),
        (r"৳", "BDT", False),
        (r"\bbdt\b", "BDT", True),
        (r"\btaka\b", "BDT", True),
        (r"₽", "RUB", False),
        (r"\brub(?:le|les)?\b", "RUB", True),
        (r"\brubel(?:s)?\b", "RUB", True),
        (r"\brouble(?:s)?\b", "RUB", True),
        (r"€", "EUR", False),
        (r"\beur\b", "EUR", True),
        (r"\beuro(?:s)?\b", "EUR", True),
        (r"£", "GBP", False),
        (r"\bgbp\b", "GBP", True),
        (r"\bpound(?:s)?\b", "GBP", True),
        (r"¥", "JPY", False),
        (r"\bjpy\b", "JPY", True),
        (r"\byen\b", "JPY", True),
        (r"\bcny\b", "CNY", True),
        (r"\byuan\b", "CNY", True),
        (r"\brenminbi\b", "CNY", True),
        (r"元", "CNY", False),
        (r"\$", "USD", True),
    ]
    for pattern, code, is_regex in ordered_patterns:
        if is_regex:
            if re.search(pattern, low):
                return code
        elif pattern in s:
            return code
    return None


def standardize_currency_value(value: Any) -> str | Any:
    """Canonicalize a currency-like value without converting its amount.

    Examples:
      "$1250" -> "USD 1250.00"
      "Aed 150" -> "AED 150.00"
      "Rubel 2500" -> "RUB 2500.00"
    """
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        # A bare number has no detectable source currency, so leave it alone.
        return value
    source = detect_currency_from_value(value)
    amount = parse_amount(value)
    if source is None and amount is None:
        return value
    if source is None:
        # Preserve ambiguous values instead of inventing a currency code.
        return value
    if amount is None:
        return source
    return f"{source} {amount:.2f}"


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
