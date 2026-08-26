# End-to-End Learning Proof

Validated on 2026-08-26.

## What was exercised

- Teacher-side bridge abstraction and learned-plan reuse.
- Student-side `/v1/experience`, `/v1/plan`, `/v1/skills`, `/v1/metrics`, and canonical training export endpoints.
- Privacy-safe training export, dataset persistence, and manifest creation.

## What passed

- A fallback Gemini-style query was observed first.
- Repeated privacy-safe training examples promoted a learned strategy.
- The learned query reused a local plan without a Gemini fallback.
- Exported training records remained privacy-safe and deduplicated.
- The student runtime persisted the training dataset files locally.
- The teacher repo remained an operational bridge/reporting surface, not a second training corpus.
- The restart check confirmed the learned path still worked after reload.

## Test results

- Teacher focused proof: passed
- Student suite: passed
- Teacher suite: passed
