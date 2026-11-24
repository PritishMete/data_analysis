# InsightFlow Design System

## Evidence

The documented values below are extracted from `apps/flutter_app/lib/app_colors.dart`, `lib/theme/glow_design_system.dart`, `lib/theme/`, `lib/widgets/`, and `lib/tech_background.dart`. This document describes existing implementation; it does not authorize a UI redesign.

## Color tokens

| Token | Value | Source |
|---|---|---|
| App background | `#22D3EE` | `lib/app_colors.dart:kAppBackgroundColor` |
| Brand dark blue | `#123A8C` | `TechColors.brandDarkBlue` |
| Brand blue | `#2E6FF2` | `TechColors.brandBlue` |
| Graphite | `#6E6E76` | `TechColors.brandGraphite` |
| Background black | `#0F111A` | `TechColors.bgBlack` |
| Panel background | `#141824` | `TechColors.panelBg` |
| Muted border | `#22293A` | `TechColors.borderMuted` |
| Primary text | `#E3E6ED` | `TechColors.textPrimary` |
| Muted text | `#67738C` | `TechColors.textMuted` |
| Success | `#00FF66` | `TechColors.statusGreen` |
| Warning | `#FFB300` | `TechColors.statusAmber` |
| Error | `#FF3366` | `TechColors.statusRed` |
| Info | `#3399FF` | `TechColors.statusBlue` |

The code also defines liquid-glass presets for panel, section, and input surfaces, plus glow geometry with blur `32`, active spread `8`, active opacity `0.6`, and ambient opacity `0.12`.

## Typography and layout

Typography follows Flutter Material/theme definitions in `lib/theme/`. Reusable glass containers, fields, buttons, chips, cards, bars, dialogs, sheets, and navigation components live under `lib/widgets/` and `lib/features/`. Prefer those existing components over one-off styling.

## Interaction states

Screens and widgets should expose loading, empty, success, error, disabled, validation, and retry states. Existing examples include progress indicators, toast/dialog surfaces, quality reports, runtime logs, and backend heartbeat status.

## Data visualization

Charts and analysis widgets include `lib/widgets/analyst_chart.dart`, `features/analysis/widgets/`, and report/pipeline screens. Visualizations must show scope, units, filters, and meaningful empty/error states; inferred relationships must be labeled as candidates.

## Responsive and task-pane constraints

Excel task panes are narrow. Avoid unbounded horizontal rows, ensure text wraps or collapses, and run the narrow-pane/auth UI tests before changing shared surfaces. The Flutter Web base path is `/data_analysis/` for GitHub Pages.

## Accessibility

Respect reduced-motion settings, keyboard/focus behavior, readable contrast, semantics, and non-color status cues. Existing accessibility helpers and motion scopes are under `lib/utils/` and `lib/widgets/shared/`.
