"""Local product identity/help responses for InsightFlow.

This module is intentionally deterministic and dataset-independent. It handles
static product/creator/help questions locally so they do not consume Gemini
quota and do not mutate analytical conversation state.
"""

from __future__ import annotations

import re
from typing import Any

PRODUCT_NAME = "InsightFlow"
CREATOR_NAME = "Pritish Mete"
PORTFOLIO_URL = "https://pritish-mete.onrender.com/"
GITHUB_URL = "https://github.com/PritishMete"

PRODUCT_DESCRIPTION = (
    "I’m InsightFlow, a privacy-first data analytics assistant designed to help "
    "you understand, clean, analyze, visualize, and report on Excel and tabular "
    "data using natural-language questions."
)

CREATOR_SUMMARY = (
    "InsightFlow was created by Pritish Mete. He designed it as a privacy-first "
    "analytics assistant that combines data analysis, application development, "
    "and controlled AI-assisted reasoning."
)

CREATOR_PROFILE = {
    "name": CREATOR_NAME,
    "primary_focus": "Data Analytics & Application Development",
    "summary": (
        "Pritish Mete focuses on data analytics and application development. "
        "He works with Python, SQL, Pandas and Power BI for analysis, and also "
        "builds applications with technologies such as Flutter, Android, Firebase "
        "and Python APIs. His portfolio includes InsightFlow, Supply Chain Analysis, "
        "Vendor Performance Analysis, BusPass, GrowCast, Lockr and Charmy Craft "
        "Studio. He currently lists Data Annotator at AnnotiqX AI as his role."
    ),
    "analytics_skills": ["Python", "Pandas", "SQL", "Power BI", "data cleaning", "exploratory analysis", "statistics / KPI analysis", "data visualization"],
    "engineering_skills": ["Flutter", "Dart", "Android", "Python backend development", "REST APIs", "Firebase", "GitHub / development tooling"],
    "current_role": "Data Annotator at AnnotiqX AI",
    "role_summary": "Works with structured video annotation and quality review for AI training data.",
    "projects": ["InsightFlow", "Supply Chain Analysis", "Vendor Performance Analysis", "Charmy Craft Studio", "BusPass", "GrowCast", "Lockr"],
}

CAPABILITY_SECTIONS = [
    {"title": "Data understanding", "items": ["Inspect datasets and identify rows, columns, data types, keys and relationships.", "Detect fact/dimension candidates and suggest star-schema structures."]},
    {"title": "Data quality & preparation", "items": ["Identify duplicates, missing values, invalid dates, inconsistent categories and relationship issues.", "Support cleaning, normalization, categorization, deduplication and guarded transformations."]},
    {"title": "Business & conversational analysis", "items": ["Analyze revenue, profit, margin, orders, customers, products, rankings, filters and time trends.", "Handle follow-ups, context, filter replacement/removal, drill-downs, AND/OR groups and sequential THEN analysis.", "Compare regions, products, categories and periods, with evidence-based explanations."]},
    {"title": "Visuals, insights & reports", "items": ["Create relevant line/bar visualizations, surface prioritized insights and generate executive or detailed PDF reports."]},
    {"title": "Excel experience", "items": ["Run natural-language Excel analysis locally and create result output/sheets where the active Excel workflow supports it."]},
]

CAPABILITY_SUMMARY = (
    "I can help you understand and clean data, analyze business performance, "
    "compare regions/products/categories, answer follow-up questions, handle "
    "AND/OR/THEN conditions, create charts, surface important insights, and "
    "generate PDF reports."
)

EXAMPLE_QUERIES = [
    "Understand these datasets.",
    "What are the data-quality issues?",
    "Which region is most profitable?",
    "Show revenue and profit month by month.",
    "Compare North and South in 2025.",
    "Generate a detailed report.",
]

TECH_STACK = [
    "Frontend: Flutter / Dart",
    "Backend: Python / FastAPI",
    "Analytics: Pandas and OpenPyXL where Excel operations require it",
    "Excel integration: Office.js / Excel integration where applicable",
    "AI/reasoning: controlled structured planning with optional privacy-safe reasoning",
]

PRIVACY_SUMMARY = (
    "InsightFlow is designed to process workbook and dataset contents locally in "
    "its privacy-preserving workflow. Raw rows, workbook values and business "
    "identifiers do not need to be sent to a remote AI service for analytical execution. "
    "Some optional or legacy paths can make external requests, so this statement applies "
    "to the secure InsightFlow / Vibe Analysis workflow."
)

_DETAIL_USAGE = "Upload your dataset files, let InsightFlow inspect their structure, then ask questions naturally."
_EXCEL_USAGE = "Open or use your workbook with InsightFlow and ask for analysis, filtering, cleaning, categorization, summaries, charts or result output using natural language."
_SECRET_PATTERNS = ("api key", "apikey", "system prompt", "hidden prompt", "environment variable", "env var", "secret key", "password")


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9+&/.'?-]+", " ", text.casefold())).strip()


def _tokens(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]+", text.casefold()))


def _response(intent: str, title: str, summary: str, *, sections: list[dict[str, Any]] | None = None, examples: list[str] | None = None, links: list[dict[str, str]] | None = None) -> dict[str, Any]:
    return {
        "success": True,
        "response_type": "assistant_meta",
        "intent": intent,
        "title": title,
        "summary": summary,
        "sections": sections or [],
        "examples": examples or [],
        "links": links or [],
        "local_only": True,
        "external_ai_used": False,
        "mutates_analytical_context": False,
    }


def resolve_assistant_meta(text: str, *, surface: str = "generic") -> dict[str, Any] | None:
    if not isinstance(text, str) or not text.strip():
        return None
    normalized = _normalize(text)
    tokens = _tokens(text)

    if any(marker in normalized for marker in _SECRET_PATTERNS):
        return _response("security", "Protected information", "I can explain how InsightFlow works, but I can’t expose API keys, secrets, environment variables, hidden prompts, or private configuration.")

    if (("google" in tokens or "openai" in tokens or "gemini" in tokens) and tokens & {"made", "created", "creator", "built", "developed"}):
        provider = "Google" if "google" in tokens else "OpenAI" if "openai" in tokens else "Gemini"
        return _response("creator", "Creator", f"No. {PRODUCT_NAME} was created by {CREATOR_NAME}. Some configurations may use external AI services for limited reasoning, but {provider} is not the creator of InsightFlow.", links=[{"label": "Portfolio", "url": PORTFOLIO_URL}, {"label": "GitHub", "url": GITHUB_URL}])

    if "how many years" in normalized and "pritish" in normalized:
        return _response("creator_profile", "About Pritish Mete", "I don’t have a verified experience-duration figure in my product profile, so I won’t invent one.")

    if (tokens & {"portfolio", "github", "work"}) and (tokens & {"where", "show", "creator", "pritish", "see"}):
        return _response("creator_profile", "Pritish Mete’s work", "You can see Pritish Mete’s work through his portfolio and GitHub profile.", links=[{"label": "Portfolio", "url": PORTFOLIO_URL}, {"label": "GitHub", "url": GITHUB_URL}])

    if "pritish mete" in normalized or ("pritish" in tokens and tokens & {"who", "about", "does"}) or ("your creator" in normalized and tokens & {"about", "does", "who"}):
        return _response("creator_profile", "About Pritish Mete", CREATOR_PROFILE["summary"], sections=[{"title": "Focus", "items": [CREATOR_PROFILE["primary_focus"]]}, {"title": "Analytics", "items": CREATOR_PROFILE["analytics_skills"]}, {"title": "Application development", "items": CREATOR_PROFILE["engineering_skills"]}, {"title": "Current role", "items": [CREATOR_PROFILE["current_role"], CREATOR_PROFILE["role_summary"]]}, {"title": "Portfolio projects", "items": CREATOR_PROFILE["projects"]}], links=[{"label": "Portfolio", "url": PORTFOLIO_URL}, {"label": "GitHub", "url": GITHUB_URL}])

    if (tokens & {"made", "created", "creator", "built", "developed", "behind"}) and (tokens & {"you", "this", "insightflow", "software", "application", "project", "app"}):
        return _response("creator", "Creator", CREATOR_SUMMARY, links=[{"label": "Portfolio", "url": PORTFOLIO_URL}, {"label": "GitHub", "url": GITHUB_URL}])

    if "what can you do" in normalized or "how can you help" in normalized or tokens & {"capability", "capabilities"} or "what can i ask" in normalized or "what kinds of analysis" in normalized or ("can" in tokens and tokens & {"analyze", "analyse", "clean", "chart", "charts", "report", "reports", "compare", "insights"}):
        return _response("capabilities", "What I can do", CAPABILITY_SUMMARY, sections=CAPABILITY_SECTIONS, examples=EXAMPLE_QUERIES)

    if ((tokens & {"private", "privacy", "protected", "protection", "upload", "uploads", "send", "sent", "gemini", "remote"}) and (tokens & {"data", "dataset", "excel", "workbook", "analysis", "private", "privacy"})) or "where is the analysis performed" in normalized:
        return _response("privacy", "Privacy", PRIVACY_SUMMARY, sections=[{"title": "Secure analytical workflow", "items": ["Workbook/dataset values stay local for analytical execution.", "Static identity/help questions are answered locally and use no external AI call.", "Optional or legacy integrations may make external requests, so privacy claims are scoped to the secure InsightFlow / Vibe Analysis workflow."]}])

    if "tech stack" in normalized or "built with" in normalized or ((tokens & {"technologies", "technology"}) and (tokens & {"use", "uses", "built"})):
        return _response("tech_stack", "Technology stack", "InsightFlow combines a Flutter/Dart frontend with a Python/FastAPI analytics backend and local data-processing tools.", sections=[{"title": "Stack", "items": TECH_STACK}])

    if "how do i use" in normalized or "how should i start" in normalized or "how to use" in normalized:
        return _response("usage", "How to use InsightFlow", _EXCEL_USAGE if surface.casefold() == "excel" else _DETAIL_USAGE, examples=EXAMPLE_QUERIES)

    if "example questions" in normalized or "some example questions" in normalized or ((tokens & {"examples", "example"}) and (tokens & {"questions", "queries", "ask"})):
        return _response("examples", "Example questions", "Here are a few useful ways to start:", examples=EXAMPLE_QUERIES)

    if ((tokens & {"who", "what"}) and (tokens & {"you", "yourself"}) and not (tokens & {"made", "created", "creator", "built", "developed"})) or "tell me about yourself" in normalized or ("insightflow" in tokens and tokens & {"what", "about"}):
        return _response("identity", PRODUCT_NAME, PRODUCT_DESCRIPTION, links=[{"label": "Creator portfolio", "url": PORTFOLIO_URL}, {"label": "GitHub", "url": GITHUB_URL}])

    return None


def assistant_meta_or_not_handled(text: str, *, surface: str = "generic") -> dict[str, Any]:
    result = resolve_assistant_meta(text, surface=surface)
    if result is None:
        return {"success": True, "handled": False, "response_type": "not_handled"}
    return {**result, "handled": True}
