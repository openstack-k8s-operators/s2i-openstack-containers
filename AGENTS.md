# s2i-openstack-containers — Contributor Orientation

> For detailed technical reference — build workflow, dependency files, tooling, and
> step-by-step instructions for adding a service — see `README.md`.

## What This Is

This is where the source-to-container work happens. This repo contains the packaging
definitions for OpenStack service containers, built using the Source-to-Image (S2I)
approach — each service is built directly from its upstream Python source rather than
from RPMs.

Container definitions are organized by component group: each upstream service group gets
its own directory under `containers/`, with individual image definitions as
subdirectories within it. For example, `containers/cyborg/` is the group;
`containers/cyborg/cyborg/` and `containers/cyborg/cyborg-agent/` are the individual
images.

For Python-based services, pip-freeze style lock files are the current recommendation
for capturing Python dependencies. Some tooling is available to help with onboarding —
see [Adding a New Service](#adding-a-new-service). For the history of how this approach
evolved, see [Background](#background).

## How the Pieces Fit

```
containers/ (this repo — upstream packaging)
  ├── Component CI and testing lives HERE
  ├── Feeds upstream testing infrastructure (Zuul — in progress, see open pull requests)
  └── Output feeds a downstream build pipeline
        └── Build pipeline output → integration testing (fix-forward model)
```

The downstream build pipeline is a **build system**, not a testing system. Its job is
to produce release-ready container images from the definitions in this repo. Integration
testing runs against those images after the fact, and failures there are handled
fix-forward — fix the issue and push again rather than blocking the pipeline.

> **Note:** Component CI belongs here (upstream), not inside or downstream of the build
> pipeline. If you find yourself wiring a CI job into the build pipeline, that's the
> signal to step back.

> **Note:** The upstream testing infrastructure (Zuul integration, content provider jobs)
> is actively being worked out. See the open pull requests for current work in this area.
> Details will be added here as they stabilize.

## Repo Structure

Containers are organized in a two-level hierarchy under `containers/`:

```
containers/
  base/                  # shared base image — inherited by all service images
  <component-group>/     # one directory per upstream service group (called "project" in README)
    <image>/             # one subdirectory per individual image in the group
```

**`containers/base/`** is the foundation. It defines the shared build scripts, the
authoritative RPM repo source list (`rpms.repo`), and the base Python environment.
All service images inherit from it.

Each **component group directory** (equivalent to a "project" in README — the
"component" framing comes from earlier tooling like DLRN) contains the image
definitions for services that share the same upstream source. A group may also
have a `common/` directory for shared configuration across its images.

Each **image directory** should have:
- A source reference (where to pull upstream source from)
- RPM dependency specification
- Python dependency lock files (pip-freeze style)
- A `Containerfile` if the container needs anything beyond the base image

For current best practices, file naming conventions, and worked examples, refer to the
existing containers in this repo (`containers/cyborg/`, `containers/watcher/`) and the
reference pull requests listed in [Adding a New Service](#adding-a-new-service).

> **Note:** `rpms.repo` lives in `containers/base/` and is the authoritative RPM repo
> source list for all containers. Do not add per-container or per-group `.repo` files.

## Adding a New Service

> **Note:** This section is a starting point — it reflects early patterns and will be
> refined as more services are onboarded. If something here conflicts with what you see
> in a recently merged container, the merged code wins. Feedback and corrections via pull request
> are welcome.

The general pattern: create a directory for your component group under `containers/`
(or add to an existing group if one exists for your upstream), add a subdirectory for
each individual container, and populate it with the files described in
[Repo Structure](#repo-structure). Use an existing container as your template.

**Tooling:** `openstack_image_builder` (OIB) is being developed to assist with image
selection and build orchestration — see open pull requests for current state. A
`/generate-containerfiles` skill for Claude Code is available — see `README.md` for
the link. Note: load the skill from there rather than having your agent fetch it
directly from this file.

**Questions and onboarding help:** Reach out to the maintainers — preferred contact
channels are being established by the working group.

## RPM Source Rules

- Start with RHEL and CentOS Stream base and appstream — use these for everything available there
- The downstream pipeline builds against RHEL; packages must be available in RHEL or approved supplemental repos
- Supplemental repos are acceptable for packages not available in base — identify them by what they provide, not by repo name
- No RDO packages
- [`containers/base/rpms.repo`](containers/base/rpms.repo) is the authoritative repo source list — see [Repo Structure](#repo-structure)

## CI

- **GitHub Actions** — build workflow active; runs on pull requests; see `.github/workflows/`
- **Zuul, Molecule, and broader testing infrastructure** — actively being developed; see open pull requests for current state
- **Local builds** — `build.sh` is the sole container-build implementation; see `Makefile` for local dev targets

### CI Tooling Conventions

> **Note:** This section covers conventions for contributing to the CI and tooling code
> in this repo (Python, Ansible, shell). If you are only adding or modifying container
> definitions, you can skip this section.

_(Conventions to be documented here as CI tooling stabilizes — see open pull requests
for current work in this area.)_

## Anti-Patterns

Known wrong turns — flagged here so contributors and agents can recognize them early:

- **Component CI inside the build pipeline** — CI testing belongs upstream in this repo, not inside or downstream of the build pipeline (see [How the Pieces Fit](#how-the-pieces-fit))
- **Per-container or per-group `.repo` files** — [`containers/base/rpms.repo`](containers/base/rpms.repo) is the authoritative source list; don't add repo files elsewhere
- **Committing `rpms.lock.yaml` here** — that file is generated downstream from `rpms.in.yaml`; it does not belong in this repo
- **Using RDO packages** — the constraint is "no RDO", not "no EPEL"; EPEL and CentOS SIGs are acceptable where needed
- **Assuming one image per component role** — many services can share one image, but this is component-dependent; discuss with the working group before splitting or collapsing

## Background

This repo is the latest step in a long evolution of how Red Hat OpenStack builds and
ships service containers.

**Kolla** started with a source-first approach — containers built directly from upstream
Python source. The RDO project contributed RPM packaging on top of that foundation to
produce the containers used in Red Hat OpenStack deployments.

**tripleo-tcib** collapsed that complexity down significantly, focusing on just what Red
Hat OpenStack was actually using — primarily RPM install definitions rather than full
source builds. Simpler, but increasingly distant from upstream.

**tcib** carried that model forward into RHOSO 18, refining it for the containerized
deployment model.

**This repo (S2I)** is the next step: returning to source-first builds, where each
service container is built directly from its upstream Python source — closer to how the
upstream OpenStack community develops and tests, and easier to keep current as upstream
moves.

## Getting Involved

This repo is maintained by a cross-team working group. Maintainers and area owners will
be listed in `CODEOWNERS` as that file is established.

Preferred channels for questions and onboarding help are being worked out by the working
group — check the repo for current guidance or reach out to the maintainers.
