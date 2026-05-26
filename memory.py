# memory.py
# ─────────────────────────────────────────────────────────────────────────────
# Centralized memory: stores every command + result in SQLite.
# Also tracks column aliases so the AI learns your column naming over time.
# ─────────────────────────────────────────────────────────────────────────────

import sqlite3
import json
from datetime import datetime

DB_PATH = "ai_memory.db"


# ─── Schema Init ─────────────────────────────────────────────────────────────

def init_db():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()

    # Every command the user ran + whether it succeeded
    c.execute("""
        CREATE TABLE IF NOT EXISTS command_log (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp   TEXT    NOT NULL,
            raw_text    TEXT    NOT NULL,
            intent      TEXT    NOT NULL,
            slots       TEXT    NOT NULL,
            result      TEXT,
            success     INTEGER NOT NULL DEFAULT 0,
            confidence  REAL
        )
    """)

    # Learned aliases: "profit col" → "profit_margin"
    c.execute("""
        CREATE TABLE IF NOT EXISTS column_aliases (
            alias       TEXT PRIMARY KEY,
            real_name   TEXT NOT NULL,
            created_at  TEXT
        )
    """)

    # User corrections: when the AI guessed wrong and the user fixed it
    c.execute("""
        CREATE TABLE IF NOT EXISTS corrections (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp       TEXT    NOT NULL,
            original_text   TEXT    NOT NULL,
            wrong_intent    TEXT    NOT NULL,
            correct_intent  TEXT    NOT NULL,
            slots           TEXT
        )
    """)

    conn.commit()
    conn.close()


# ─── Command Logging ─────────────────────────────────────────────────────────

def log_command(raw_text: str, intent: str, slots: dict,
                result: dict, success: bool, confidence: float = 0.0):
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        """INSERT INTO command_log
           (timestamp, raw_text, intent, slots, result, success, confidence)
           VALUES (?, ?, ?, ?, ?, ?, ?)""",
        (
            datetime.utcnow().isoformat(),
            raw_text,
            intent,
            json.dumps(slots),
            json.dumps(result),
            int(success),
            confidence,
        )
    )
    conn.commit()
    conn.close()


def get_recent_commands(limit: int = 30) -> list:
    conn = sqlite3.connect(DB_PATH)
    rows = conn.execute(
        """SELECT timestamp, raw_text, intent, slots, success, confidence
           FROM command_log
           ORDER BY id DESC
           LIMIT ?""",
        (limit,)
    ).fetchall()
    conn.close()
    return [
        {
            "time":       r[0],
            "text":       r[1],
            "intent":     r[2],
            "slots":      json.loads(r[3]),
            "success":    bool(r[4]),
            "confidence": r[5],
        }
        for r in rows
    ]


def get_command_stats() -> dict:
    """Returns counts by intent and overall success rate."""
    conn = sqlite3.connect(DB_PATH)

    total = conn.execute("SELECT COUNT(*) FROM command_log").fetchone()[0]
    success = conn.execute(
        "SELECT COUNT(*) FROM command_log WHERE success=1"
    ).fetchone()[0]

    by_intent = conn.execute(
        "SELECT intent, COUNT(*) as cnt FROM command_log GROUP BY intent ORDER BY cnt DESC"
    ).fetchall()

    conn.close()
    return {
        "total_commands": total,
        "successful":     success,
        "success_rate":   round(success / total * 100, 1) if total else 0,
        "by_intent":      [{"intent": r[0], "count": r[1]} for r in by_intent],
    }


# ─── Column Aliases ──────────────────────────────────────────────────────────

def save_alias(alias: str, real_name: str):
    """Teach the AI that 'alias' means 'real_name' column."""
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        "INSERT OR REPLACE INTO column_aliases (alias, real_name, created_at) VALUES (?,?,?)",
        (alias.lower().strip(), real_name.strip(), datetime.utcnow().isoformat())
    )
    conn.commit()
    conn.close()


def resolve_alias(name: str) -> str:
    """Look up if 'name' is a known alias; return real column name if so."""
    conn = sqlite3.connect(DB_PATH)
    row = conn.execute(
        "SELECT real_name FROM column_aliases WHERE alias=?",
        (name.lower().strip(),)
    ).fetchone()
    conn.close()
    return row[0] if row else name


def get_all_aliases() -> list:
    conn = sqlite3.connect(DB_PATH)
    rows = conn.execute(
        "SELECT alias, real_name, created_at FROM column_aliases"
    ).fetchall()
    conn.close()
    return [{"alias": r[0], "real_name": r[1], "created_at": r[2]} for r in rows]


# ─── Corrections ─────────────────────────────────────────────────────────────

def log_correction(original_text: str, wrong_intent: str,
                   correct_intent: str, slots: dict = None):
    """Record when the user corrects a wrong classification."""
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        """INSERT INTO corrections
           (timestamp, original_text, wrong_intent, correct_intent, slots)
           VALUES (?,?,?,?,?)""",
        (
            datetime.utcnow().isoformat(),
            original_text,
            wrong_intent,
            correct_intent,
            json.dumps(slots or {}),
        )
    )
    conn.commit()
    conn.close()


# ─── Auto-init on import ──────────────────────────────────────────────────────
init_db()