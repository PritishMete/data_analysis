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

## Background token clarification

`kAppBackgroundColor` (`#22D3EE`) is a standalone exported color used by the scan-button/legacy surface path; it is not the dark application background. Dark screens use `TechColors.bgBlack` (`#0F111A`), `panelBg`, and the ambient background implementation in `tech_background.dart`. Do not replace either path without tracing its consumers and updating its contract tests.

## Typography and layout

Typography follows Flutter Material/theme definitions in `lib/theme/`. Reusable glass containers, fields, buttons, chips, cards, bars, dialogs, sheets, and navigation components live under `lib/widgets/` and `lib/features/`. Prefer those existing components over one-off styling.

## Spacing, shape, shadow, and breakpoints

`lib/constants/glass_defaults.dart` defines shared spacing (`4`, `8`, `16`, `24`), card/panel padding, and radii (`8`, `16`, `20`). Existing screens also use deliberate radii around `7–22`; reuse the shared constants where a component has them. `lib/constants/glass_shadow.dart` owns standard shadow behavior. Responsive code primarily uses `LayoutBuilder` and `MediaQuery`; a verified reference breakpoint is `520` in `analytics_reference_workspace.dart`, while other screens use constraint-based layouts. Do not invent a universal breakpoint.

## Ownership rule

Use `TechColors`, `GlowDesignSystem`, `GlassTheme`, `GlassDefaults`, and the shared `lib/widgets/` components before adding local colors, spacing, glass settings, shadows, or radii. New styling requires a source-backed reason and responsive/accessibility tests.

## Interaction states

Screens and widgets should expose loading, empty, success, error, disabled, validation, and retry states. Existing examples include progress indicators, toast/dialog surfaces, quality reports, runtime logs, and backend heartbeat status.

## Data visualization

Charts and analysis widgets include `lib/widgets/analyst_chart.dart`, `features/analysis/widgets/`, and report/pipeline screens. Visualizations must show scope, units, filters, and meaningful empty/error states; inferred relationships must be labeled as candidates.

## Responsive and task-pane constraints

Excel task panes are narrow. Avoid unbounded horizontal rows, ensure text wraps or collapses, and run the narrow-pane/auth UI tests before changing shared surfaces. The Flutter Web base path is `/data_analysis/` for GitHub Pages.

## Accessibility

Respect reduced-motion settings, keyboard/focus behavior, readable contrast, semantics, and non-color status cues. Existing accessibility helpers and motion scopes are under `lib/utils/` and `lib/widgets/shared/`.
