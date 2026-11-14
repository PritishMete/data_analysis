# 📊 InsightFlow — Privacy-First Excel Analytics Assistant

> A Flutter + Python analytics product that turns natural-language questions into controlled Excel analysis while keeping workbook data local by default.

## Overview

InsightFlow was built around a practical analytics problem: business users often have the data they need inside Excel, but getting from a workbook to a reliable answer still requires manual filtering, formulas, cleanup, charting, or analyst support.

The product aims to make that workflow more direct:

**upload or open data → understand the schema → ask a question → validate the requested operation → execute locally → return a usable result**

The current architecture uses a **Flutter frontend** and a **Python/FastAPI analytics backend**, with privacy controls designed so workbook values and business identifiers do not need to leave the local execution environment.

## Product Goals

- Let users work with Excel data through natural-language requests.
- Keep raw workbook content local by default.
- Convert user intent into controlled, inspectable operations.
- Detect semantic roles and data relationships before analysis.
- Support filtering, grouping, aggregation, cleaning, categorization and reporting.
- Help users understand multi-table data through Detail Analysis and star-schema candidates.
- Prevent arbitrary model-generated Python from being executed against user data.

## Privacy-First Architecture

The secure Excel path follows this flow:

```text
Excel workbook
      │
      ▼
Local workbook scan
      │
      ├── schema detection
      ├── semantic-role inference
      └── local column aliases (c1, c2, c3...)
      │
      ▼
Natural-language request
      │
      ▼
Structured query / plan
      │
      ▼
Validation
      │
      ▼
Local execution on Pandas DataFrame
      │
      ▼
Result / report / workbook output
```

By default, the secure workflow does not require raw workbook content to be sent to a remote LLM.

## What Stays Local

The secure path is designed to keep these values on the user's machine:

- cell and row values
- original column names
- filenames
- sheet names
- customer or business names
- addresses
- email addresses
- phone numbers
- URLs
- IDs and other business identifiers

The original Pandas DataFrame remains inside the backend session used for local execution.

## Controlled Query Planning

Natural-language requests are translated into a constrained structure containing fields such as:

- `operation`
- `conditions`
- `sort`
- `group_by`
- `aggregates`
- `limit`
- `search`
- `report`

Example:

```json
{
  "operation": "filter",
  "conditions": [
    { "column_id": "c3", "operator": "equals", "value": "Kolkata" },
    { "column_id": "c6", "operator": "equals", "value": true }
  ]
}
```

The backend validates the plan, maps internal column IDs back to the local DataFrame and executes predefined operations. It does **not** treat arbitrary AI-generated Python as an execution path.

## Schema Intelligence

InsightFlow performs local schema inspection and semantic-role detection using:

- column-name hints
- data types
- value-shape heuristics
- uniqueness patterns

Supported roles include identifiers, entity names, geography, dates, ratings, numeric and currency measures, booleans, categories, emails, phones, URLs, status fields and free text.

## Detail Analysis

Detail Analysis is designed for workbook and multi-table understanding rather than only single-table profiling.

It can inspect multiple worksheets or uploaded tables and surface:

- candidate keys
- fact-table candidates
- dimension-table candidates
- relationship candidates
- observed value overlap
- star-schema suggestions
- data-quality observations

These are analytical/modeling candidates and should still be validated against the real business grain.

## Core Capabilities

### Query & Analysis
- filtering and multi-condition filtering
- sorting
- grouping and aggregation
- entity/value discovery
- statistics
- reports and charts
- sheet creation and result writing

### Data Preparation
- missing-value handling
- duplicate handling
- outlier-related workflows
- categorization and normalization
- semantic role detection
- guarded range binning

### Modeling
- multi-table profiling
- relationship discovery
- fact/dimension suggestions
- star-schema visualization

## Technology Stack

### Frontend
- Flutter
- Dart
- Flutter Web
- Office.js integration for Excel-hosted workbook operations

### Backend & Analytics
- Python
- FastAPI
- Pandas
- OpenPyXL
- local session-based execution

### AI / Reasoning Layer
- controlled structured planning
- optional remote reasoning only when explicitly enabled
- privacy guardrails around outbound payloads

## Repository Layout

The repository is a monorepo. Application source code belongs on `main`; `gh-pages` is reserved for the generated Flutter Web publication output.

```text
data_analysis/
├── apps/
│   └── flutter_app/       # Flutter application: Android, Windows and Web
├── common/                # Shared Python analytics and domain modules
├── core/                  # Backend core infrastructure
├── datasets/              # Dataset domain and persistence
├── docs/                  # Architecture and developer documentation
├── frontend/              # Existing browser-facing frontend assets
├── ingestion/              # Backend ingestion modules
├── memory_engine/         # Backend memory subsystem
├── plan_cache/            # Backend query-plan cache
├── query_history/          # Backend query history
├── schema_intelligence/   # Schema discovery and relationships
├── secure_excel/           # Backend Excel query and privacy services
├── sql_cache/              # Backend SQL cache
├── tests/                  # Python test suite
├── tools/                  # Developer utilities
├── .github/workflows/      # CI and deployment workflows
├── main.py                 # FastAPI application entry point
├── requirements.txt        # Python dependencies
└── render.yaml             # Render service configuration
```

The Python backend currently remains at the repository root because the Render start command and Python module imports use that layout. Keep backend changes compatible with `uvicorn main:app` until a dedicated backend relocation is planned and its import/deployment paths are updated together.

### Open the Flutter project

Open `apps/flutter_app/` in Android Studio. It is one Flutter project with platform targets under the same directory; do not create separate copies for Android, Windows and Web.

```bash
cd apps/flutter_app
flutter pub get
```

### Run the backend locally

From the repository root:

```bash
pip install -r requirements.txt
python -m uvicorn main:app --host 127.0.0.1 --port 8000
```

### Branch conventions

- `main` is the source of truth for maintained application code.
- `gh-pages` contains generated static website output only. Do not edit application source there.
- Use short-lived `feature/*`, `fix/*` or `chore/*` branches for active work, then merge completed work into `main`.
- Do not create `backup/*` branches. Keep history in Git commits and pull requests instead.
- Delete a development branch only after its changes are merged or explicitly discarded.

## Development Workflow

InsightFlow is developed from explicit product requirements, analytical rules, privacy constraints and acceptance criteria.

**Codex is used as an engineering accelerator** for implementation, debugging, refactoring and test-driven iteration. Product behavior, architecture, privacy boundaries and validation rules are defined deliberately rather than delegated to an unconstrained code-generation process.

## Run the Backend

```bash
python -m uvicorn main:app --host 127.0.0.1 --port 8000
```

Useful endpoints include:

```text
GET  /health
GET  /privacy
GET  /excel/ping
POST /excel/session
POST /excel/query
POST /excel/interpret
POST /excel/detail-analysis
POST /v2/detail-analysis
POST /v2/detail-analysis/path
POST /powerbi/detail-analysis
```

## Privacy Configuration

For the privacy-preserving deployment mode:

```text
INSIGHTFLOW_PRIVACY_MODE=local_only
SECURE_EXCEL_REMOTE_AI=false
```

`local_only` is the intended safe production configuration for deployments that must not process workbook data remotely.

## Local Folder Analysis

Local folder-path analysis should only be enabled on a trusted local backend:

```powershell
$env:DETAIL_ANALYSIS_PATHS_ENABLED = "true"
$env:DETAIL_ANALYSIS_ALLOWED_ROOTS = "C:\datasets"
```

A hosted browser cannot directly grant a remote server access to arbitrary local filesystem paths; use the local backend or supported file-selection workflow instead.

## Security Principles

- Keep workbook contents local unless remote processing is intentionally enabled.
- Do not send raw business data to external models by default.
- Validate all structured operations before execution.
- Do not execute arbitrary generated Python against workbook data.
- Do not log sensitive workbook contents or business identifiers.
- Keep API credentials and private configuration outside source control.

## Portfolio Case Study

https://pritish-mete.onrender.com/projects/showcase/project.html?id=6

## Repository

https://github.com/PritishMete/data_analysis

## Author

**Pritish Mete**

GitHub: https://github.com/PritishMete
