# RFC 0001: Zuul component pipeline for s2i containers

- **Status:** provisional
- **Author(s):** Roberto Alfieri (@rebtoor), with input from Alfredo Moralejo
- **Created:** 2026-08-07
- **Discussion:** open a PR against this file; related spike [ANVIL-204](https://redhat.atlassian.net/browse/ANVIL-204)

## Summary

Add a **Zuul-based component pipeline** on top of this repository’s existing
`build.sh` / tox tooling. GitHub Actions remain the fast gate for the s2i
repo itself. Zuul jobs build images **with the change under test**, optionally
publish them to a registry, and hand image references to dependent jobs.

Build logic stays in this repo. Zuul only orchestrates via a **thin Ansible
role** and pre/run playbooks.

## Motivation

- More OpenStack services will land here beyond watcher and cyborg.
- We need CI that builds containers from Zuul checkouts (Depends-On), not only
  from pinned hashes in `sources.txt`.
- `build.sh` already supports that: if `containers/<project>/src/<name>/`
  exists, it is used as-is (no re-clone / no cleanup).
- Repo-local GHA validation (linters, test, build, update-sources) is largely
  in place; the missing piece is the Zuul component / provider path.

## Non-goals (this RFC)

- Full promotion / criteria / DLRN wiring.
- Migrating every service into s2i in one step.
- Replacing or detailing legacy TCIB job implementations (this is a **new**
  path). Image-name mapping for consumers is in scope as a **contract**, not
  as a migration plan for old jobs.

## Proposal

### Layering

| Layer | Responsibility |
| --- | --- |
| This repo (`build.sh`, Containerfiles, lockfiles) | How images are built |
| Thin Ansible role + playbooks | Map job vars → `build.sh`; stage Zuul trees into `src/` |
| Zuul job definitions | When to build, what target, registry, `zuul_return` |
| GitHub Actions | Validate PRs to **this** repo (already present) |

```text
                    ┌─────────────────────────┐
  GHA (this repo)   │ linters / test / build  │  fast gate
                    └─────────────────────────┘

  Zuul provider     pre: stage src/ (optional)
  (this repo)       run: build.sh build all → push → zuul_return
                         │
                         ▼
  Zuul consumers    pull image refs / registry from parent

  Zuul component    pre: stage Depends-On into src/
  (service/op)      run: build.sh build <project> → (optional push / return)
```

### Job shapes

Two shapes share one role; they differ only by vars.

#### A. Provider job (triggered by this repo)

- Target: `all` (or `build-parallel`).
- Build every image with the s2i tree under test.
- Push/expose images on a registry available to child jobs.
- `zuul_return` image references (and pause the parent if children need a
  live registry), similar in spirit to existing content-provider patterns.
- GHA does **not** replace this; GHA does not hand images to Zuul children.

#### B. Per-project / component job (triggered by other repos)

Examples: `openstack/watcher`, `openstack-k8s-operators/watcher-operator`
with Depends-On on watcher.

- Target: a single project, e.g. `build.sh build watcher`.
- Stage relevant Zuul checkouts under `containers/watcher/src/...`.
- Optionally build `openstack-base` first, or set `BASE_IMAGE` to a known
  published base / provider-built base.

### Thin Ansible role (contract)

Proposed variables (names bikeshed-able):

| Variable | Purpose |
| --- | --- |
| `s2i_build_repo_dir` | Checkout of this repository |
| `s2i_build_stream` | `STREAM` (`master`, …) |
| `s2i_build_target` | `all`, `<project>`, or `<project>/<image>` |
| `s2i_build_registry` / `s2i_build_namespace` / `s2i_build_tag` | Image identity |
| `s2i_build_base_image` | Optional `BASE_IMAGE` override |
| `s2i_build_include_base` | Build `base` before a project target when no override |
| `s2i_build_push` | Whether to push after build |
| `s2i_build_sources` | List of `{project, dest}` overlays for `src/` |

**Pre-playbook:** for each entry in `s2i_build_sources`, copy
`zuul.projects[project]` into `s2i_build_repo_dir / dest`.

**Run playbook:** invoke the role.

**Where the role lives (open):** this repo for a first PoC vs long-term in
ci-framework. Job YAML may live in the triggering project’s config and/or
ci-framework-jobs.

### Depends-On → `src/` mapping

`build.sh` expects paths like `containers/watcher/src/watcher/` keyed by the
`sources.txt` **name** field.

**Proposed v1 policy: allowlist (or intersection), not fully open-ended.**

1. Start from projects listed in that service’s `sources.txt` and/or a shared
   allowlist (e.g. common libs such as `python-openstacksdk`).
2. Intersect with projects present in `zuul.projects` for this build
   (change under test + Depends-On + required-projects).
3. Emit `s2i_build_sources` from that intersection (with optional job-level
   overrides).

Fully dynamic “any Depends-On → invent a `src/` path” is deferred: wrong
paths and lockfile skew are too easy.

**Lockfiles (v1):** builds use **committed** `requirements.lock.<stream>`.
Regenerating locks when an overlay changes deps is a follow-up.

### Registry and `zuul_return`

Provider (and optionally component) jobs should return enough data for
children to pull the right images. Exact keys are open; suggested shape:

```yaml
zuul_return:
  data:
    s2i_registry: "<host>"
    s2i_namespace: "openstack-k8s-operators"
    s2i_tag: "<tag>"
    s2i_images:
      openstack-base: "..."
      openstack-watcher-base: "..."
      # ...
```

Also consider exporting **consumer-oriented keys** (see image mapping below),
not only raw image repository names.

Reference: [Zuul return values](https://zuul-ci.org/docs/zuul/latest/job-content.html#return-values).

### Image name mapping (s2i ↔ deploy / openstackversion)

s2i image names are **not** assumed to match legacy TCIB names 1:1. Deploy
jobs that consume s2i images need an explicit map from openstackversion (or
equivalent) container variables → s2i image names.

**Proposal:** maintain a mapping table in one agreed place (this repo under
`docs/` or a vars file in ci-framework). Provider `zuul_return` should expose
stable keys that consumers already understand **or** both s2i name and
consumer key.

Initial images to map (current tree):

| s2i image (prefix `openstack-`) | Notes |
| --- | --- |
| `base` | Shared base |
| `watcher-base` | Watcher |
| `cyborg` / `cyborg-agent` | Cyborg |

Exact openstackversion field names are **TBD** in this RFC (need consumer
input).

### Quay / registry namespace

GHA already tags builds toward `quay.io/openstack-k8s-operators`. Push
credentials and whether Zuul provider uses Quay vs an ephemeral job registry
are still to decide.

## Open questions

1. **Role home:** keep the thin role in this repo, move to ci-framework, or
   both (PoC here → graduate)?
2. **Zuul tenant wiring:** which `parent` job / nodeset (buildah, podman,
   registry)? Upstream vs downstream first?
3. **Provider registry:** ephemeral in-job registry + `zuul.pause`, vs push
   to Quay with temporary tags?
4. **`zuul_return` schema:** final key names; do children consume s2i names,
   openstackversion keys, or both?
5. **Allowlist format:** file in this repo vs job vars only? Who owns adding
   a new Depends-On candidate (e.g. `python-openstacksdk`)?
6. **Lock regen:** when an overlay changes Python deps, is committed-lock
   failure acceptable until a follow-up lands, or must CI regen locks?
7. **Image mapping owners:** where does the s2i ↔ openstackversion table
   live, and who updates it when a new service is added?
8. **Nested images:** e.g. `watcher/watcher-base/watcher-api` vs
   `discover_images` (one-level discovery today) — bug or intentional?

## Alternatives considered

| Alternative | Why not (for now) |
| --- | --- |
| Only GHA, no Zuul | Cannot stage Depends-On / feed child Zuul jobs cleanly |
| Fully dynamic Depends-On → `src/` | Too easy to stage the wrong tree; lockfile issues |
| Always `build all` from every repo | Too slow/costly for service/operator patches |
| Thick Ansible re-implementing build.sh | Duplicates source of truth; harder to maintain |

## Implementation sketch (non-binding)

Ordered follow-ups after this RFC is accepted (or partially accepted):

1. Land thin role + pre/run playbooks (location per Q1).
2. Provider job on this repo: build all → registry → `zuul_return`.
3. Per-project job example (`watcher`) with `s2i_build_sources`.
4. Document allowlist + first image-name mapping table.
5. Wire one consumer job that pulls provider images.

## References

- Repository: https://github.com/openstack-k8s-operators/s2i-openstack-containers
- Spike: https://redhat.atlassian.net/browse/ANVIL-204
- GHA tox/setup work: https://github.com/openstack-k8s-operators/s2i-openstack-containers/pull/7
- `build.sh` source overlay behaviour (existing): if `src/<name>` exists, use as-is
- Zuul `zuul_return`: https://zuul-ci.org/docs/zuul/latest/job-content.html#return-values
