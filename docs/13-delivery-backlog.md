# Delivery Backlog — Agent-ready Epics and Tasks

## 0. Working rules
IDs are stable; each task has owner, dependency, demo and tests. **Do not** parallelize modules before contracts: cross-cutting command/session/sync protocol should be frozen after POC, then other agents can proceed.

## Milestone M0 — Feasibility & contracts (blocker)
| Task | Owner | Dependencies | Output / DoD |
|---|---|---|---|
| PO-001 | Integrator | none | review PRD & freeze MVP assumptions, ADR decisions |
| POC-001 | iOS | PO-001 | real iPhone Live Activity countdown + auth test, screenshots/logs |
| POC-002 | iOS/QA | POC-001 | shared DB/AppIntent transactional action; kill/offline test |
| CON-001 | Integrator/BE/iOS | PO-001 | OpenAPI reviewed, entity naming/time enums consistent |
| CON-002 | Integrator | CON-001, POC-002 | Workout reducer transition contract & event schema approved |

## Milestone M1 — Local-first usable workout
| Task | Owner | Depends | Output / DoD |
|---|---|---|---|
| IOS-001 | iOS | CON-002 | project scaffolding, GRDB migrations, clean build |
| IOS-002 | iOS | IOS-001 | pure reducer / fake clock / command dedupe unit tests |
| IOS-003 | iOS | IOS-002 | planner + local catalog seed, validation |
| UX-001 | Design | PO-001 | token system, 13 screen specs, clickable journey |
| IOS-004 | iOS | IOS-002,UX-001 | Workout Player hold+reps+rest and confirmation flow |
| IOS-005 | iOS | IOS-004,POC-001 | Live Activity/widget + notifications, fallback |
| IOS-006 | iOS | IOS-003,IOS-004 | offline Journal/History/notes + force quit recovery |
| IOS-009 | iOS | IOS-003 | personal catalog editor + plan/workout CRUD; local implementation and XCTest cases added; macOS archive and 18 XCTest passed (run 42397716104); real-device validation pending (docs/17-content-editing.md) |
| MED-002 | iOS/QA | IOS-009 | HTTPS + Photos/Files import and playback; local implementation added; device/offline/media QA pending (docs/17-content-editing.md) |
| MED-001 | Design/iOS | UX-001 | approved thumbnails/posters + media cache/AVPlayer |
| QA-001 | QA | IOS-006,IOS-005 | T-01..T-06, T-09..T-12 with real device evidence |

## Milestone M2 — Backend and sync
| Task | Owner | Depends | Output / DoD |
|---|---|---|---|
| BE-001 | BE | CON-001 | .NET modular monolith, auth stubs/prod validation, OpenAPI implementation |
| BE-002 | BE | BE-001 | PostgreSQL migration, seed catalog, per-user isolation tests |
| BE-003 | BE | BE-002 | transactional sync push idempotent + receipts |
| BE-004 | BE | BE-003 | cursor pull/change-log + tombstones |
| IOS-007 | iOS | IOS-001,BE-004 | outbox push/pull/visible status/conflict inbox |
| IOS-008 | iOS/BE | IOS-007 | Sign in with Apple, guest attach workflow |
| QA-002 | QA | IOS-008 | T-07,T-08,T-16 + 2-device E2E + auth stress |

## Milestone M3 — AI Coach and release
| Task | Owner | Depends | Output / DoD |
|---|---|---|---|
| AI-001 | AI | BE-004 | deterministic metrics, conservative safety policy, unit tests |
| AI-002 | AI/BE | AI-001 | durable job queue + schema validated LLM adapter |
| AI-003 | AI/BE | AI-002 | analysis request/result + recommendation decision/plan revision |
| IOS-009 | iOS | AI-003 | AI review UI pending/completed/rejected + apply flow |
| QA-003 | QA | IOS-009 | T-13..T-15, prompt injection, no silent plan mutation |
| OPS-001 | Integrator | BE-004 | CI/CD, metrics, secrets, backup+restore, privacy baseline |
| REL-001 | Integrator/QA | QA-001,QA-002,QA-003,OPS-001 | pilot release checklist, testflight, rollback playbook |

## Ready-to-start vertical slice order
1. Local plan fixture → Player with timer and confirmation → Journal saved transactionally.
2. Add Lock Screen POC and media preview on existing state.
3. API push one finished session → repeat push → pull analysis placeholder.
4. Enable real AI worker with safe fallback.

## Issue template for agents
```text
ID / Title:
Owner:
Preconditions/dependencies:
User flow and business rule:
API / local entities touched:
Implementation checklist:
Tests (unit/integration/device):
Definition of done:
Evidence: screenshots / test logs / command outputs:
New ADR required? (yes/no):
```
