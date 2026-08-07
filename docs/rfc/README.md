# RFCs

Design proposals for s2i-openstack-containers that need community discussion
before (or while) implementing.

## Process

1. Copy `0000-template.md` to `NNNN-short-title.md` (next free number).
2. Fill in the proposal. Mark open questions clearly.
3. Open a PR titled `RFC: <short title>`.
4. Discuss on the PR (line comments preferred).
5. When consensus is reached, update the RFC status and merge.
6. Implementation may land in follow-up PRs that reference the RFC.

## Status values

| Status | Meaning |
| --- | --- |
| `provisional` | Under discussion; nothing is decided |
| `accepted` | Direction agreed; implementation may proceed |
| `rejected` | Not going forward (keep for history) |
| `superseded` | Replaced by a later RFC |

## Index

| RFC | Title | Status |
| --- | --- | --- |
| [0001](0001-component-pipeline.md) | Zuul component pipeline for s2i containers | provisional |
