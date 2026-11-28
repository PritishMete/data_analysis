# Power BI / Detail Analysis local-first decision

Status: fail closed pending product approval and a supported authenticated local processor.

## Scope and data-flow trace

The Flutter Detail Analysis page selects CSV, TSV, XLSX, XLSM, XLS, or JSON files with `withData: true`. The selected `PlatformFile.bytes` are passed to `PowerBiDetailAnalysisService`. Each service method previously constructed an HTTP multipart request and put every non-empty file into the `files` part:

| Operation | Client operation | Data-derived bytes | Destination in the audited commit | Decision |
| --- | --- | --- | --- | --- |
| Detail Analysis | `analyze` | Full selected files | `/powerbi/detail-analysis` at `insightFlowBackendOrigin` | Block |
| Customer cleaning | `cleanCustomer` | Full selected files | `/powerbi/customer-clean` | Block |
| Product cleaning | `cleanProduct` | Full selected files | `/powerbi/product-clean` | Block |
| Order cleaning | `cleanOrders` | Full selected files | `/powerbi/order-clean` | Block |
| Date dimension | `buildDateDimension` | Full selected files | `/powerbi/date-dimension` | Block |
| Business analysis | `analyzeBusinessModel` | Full selected files plus query/filter/context fields | `/powerbi/business-analysis` | Block |
| Dashboard | `buildDashboard` | Full selected files plus filter fields | `/powerbi/dashboard` | Block |

The default backend origin is the Cloudflare gateway backed by Oracle. Therefore, the old behavior could transmit raw datasets to Oracle without a product-level consent step. The service also had no local authenticated processing implementation to substitute for these requests.

## Supported local paths

The message router is local and deterministic: it classifies text without reading dataset values or calling a remote model. UI state, file selection, chat text, and report rendering are also local operations. These paths do not constitute dataset analysis.

The audited commit contains no supported authenticated local Power BI/Detail Analysis processor. The existing `secure local` implementations are for other Excel/query workflows and are not an implementation of these Power BI endpoints. This change does not infer, invent, or weaken authentication for a new local processor.

## Enforcement

All seven Power BI dataset-processing methods now reject non-empty files before constructing a request. The error explicitly states that processing is local-only and that no dataset was uploaded. Empty-file validation remains unchanged. No consent UI or upload enablement is added.

## Exact UI consent points

There are currently no valid consent points for these operations. The dataset picker is a file-selection point, not consent to transmit data. The chat composer and dashboard filter controls are also not consent points. Any future remote-processing enablement requires a product-approved, explicit confirmation immediately before the first transmission, identifying the destination, data scope, and authenticated processing path. This branch intentionally does not implement that flow.

