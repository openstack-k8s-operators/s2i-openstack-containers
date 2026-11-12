# CI, Validation, and Publication

This document covers continuous integration, validation, and
publication for this repository.

Every pull request is validated by **GitHub Actions** (fast checks)
and **Zuul** (image build, smoke tests, and OpenStack deployment,
including the per-service **component jobs**). Beyond PR validation,
two automation workflows keep sources and published images current:

- **update-sources** — daily job that proposes pull requests bumping
the pinned upstream hashes used to build the containers;
- **build-and-push** — post-merge Zuul job (defined in the
rdoproject.org config repository) that builds and publishes the
updated images to Quay.

For image design principles see [`design.md`](design.md). For build,
source-maintenance, and local workflows see the
[developer guide](developer-guide.md). For wiring consumer jobs on
openstack operators repositories see
[`operator-onboarding.md`](operator-onboarding.md).

## Overview

Validation and automation jobs are split across two systems — GitHub
Actions and Zuul — in layers ordered by cost:

| Layer | System | What it validates | When it runs |
|-------|--------|-------------------|--------------|
| Fast checks | GitHub Actions | Lint, unit tests, lockfile reproducibility, OWNERS files | Every PR and push |
| Image build + basic deployment | Zuul (`github-check`) | Builds all images from the PR's pins, smoke-tests them, deploys a live OpenStack and runs tempest | Every PR (non-docs changes) |
| Per-service specific deployment | Zuul component jobs (`github-check`) | Deploys the service under test with the PR's images and runs its tempest suite | PRs touching `containers/<service>/` or `containers/base/` |
| Publication | Zuul (`github-post`) | Builds and pushes all images to `quay.io/openstack-s2i-containers/` | Every merge to `main` |
| Services sources and dependencies | GitHub Actions (`update-sources`) | Opens a PR bumping pinned hashes to latest upstream | Daily |

The Zuul jobs run on the public Zuul instance
([https://gateway-cloud-softwarefactory.apps.ocp.cloud.ci.centos.org](https://gateway-cloud-softwarefactory.apps.ocp.cloud.ci.centos.org/zuul/t/rdoproject.org/status)). The
pipelines themselves (`github-check`, `github-post`, ...) are defined in
the [rdoproject.org config repository](https://review.rdoproject.org/r/q/project:config)
(`zuul.d/github.yaml`); the jobs that this repository schedules on
`github-check` are defined in this repository under `zuul.d/`.

The life of a change:

```
PR opened
  ├─ GitHub Actions: Linters, Tests, Tests (source reproducibility),
  │                  Validate OWNERS (path-filtered)
  └─ Zuul github-check
       ├─ s2i-openstack-containers-molecule
       └─ s2i-openstack-container-content-provider   (builds all images; pauses)
             ├─ s2i-openstack-container-consumer-smoke
             │      └─ s2i-openstack-deploy-validation   (CRC/EDPM + tempest)
             └─ <service>-s2i-test-*   (component jobs for the touched services)
merge to main
  └─ Zuul github-post: s2i-openstack-container-build-push
       → quay.io/openstack-s2i-containers/<image>:master-latest

daily (05:17 UTC)
  └─ GitHub Actions: update-sources → "Update sources" PR
       → full validation → review/merge → publish
```

## Validating changes in this repository

### GitHub Actions workflows

Workflows use GitHub's native `on.<event>.paths` filters so unrelated
jobs are skipped entirely. Skipped workflows count as passing for
required branch protection when the workflow file exists on the default
branch. Every workflow can also be run manually with
`workflow_dispatch`.

All workflows live in `.github/workflows/` in this repository and share
two composite actions:

- `.github/actions/setup-tox` — sets up Python 3.12 and installs `tox`.
- `.github/actions/detect-changed-services` — on pull requests, derives
the list of changed service directories under `containers/` from the
PR diff (used to limit lockfile regeneration to affected services).

| Workflow | Purpose | Triggered on | Definition |
|----------|---------|--------------|------------|
| Linters | Pre-commit lint of Containerfiles, shell, YAML, JSON, secrets | Every PR and push (except `OWNERS`-only changes) | `.github/workflows/linter.yml` |
| Tests | Unit tests for `build.sh` behavior | PRs/pushes touching `build.sh`, `tox.ini`, `tests/`, `hack/` | `.github/workflows/test.yml` |
| Tests (source reproducibility) | Lockfiles must regenerate cleanly from committed pins | PRs/pushes touching `build.sh`, `tox.ini`, the tox action, `containers/**/sources.txt`, `containers/**/*deps.txt`, `containers/**/excluded-requirements.txt` | `.github/workflows/test-update-sources.yml` |
| Validate OWNERS | Syntax and required keys of OWNERS files | PRs/pushes touching `**/OWNERS`, `**/OWNERS_ALIASES` | `.github/workflows/owners.yml` |

**Linters**

Runs `tox -e linters`, which executes `pre-commit run -a` over the
repository

**Tests**

Runs `tox -e test`, which executes the shell/Python unit test suites
under `tests/`.

**Tests (source reproducibility)**

Regenerates lockfiles from the committed source pins with
`tox -e update-lockfiles` — restricted to the services changed in the
PR — and then requires a clean tree: any modified or untracked file
under `containers/` fails the job with instructions to run
`tox -e update-lockfiles` locally. This catches PRs that edit
`sources.txt` or dependency files without committing the regenerated
`requirements.lock.<stream>`, `buildrequirements.lock.<stream>`,
`upper-constraints.txt.<stream>`, and `rpms.in.yaml`.

**Validate OWNERS**

Lints every `OWNERS` and `OWNERS_ALIASES` file with `yamllint` and
checks the required keys (`approvers`/`reviewers` in `OWNERS`,
`aliases` in `OWNERS_ALIASES`). Triggered only when those files change.

### Zuul check pipeline

Pull requests are also validated by Zuul's `github-check` pipeline on
the public SoftwareFactory Zuul instance. The pipeline triggers on PR
opened/synchronize/reopened events and on `recheck`, `check-rdo`, or
`/test all` comments, and reports statuses back to the GitHub PR. The
pipeline definition lives in the rdoproject.org config repository
(`zuul.d/github.yaml`); the job definitions and this repository's
project stanza live under `zuul.d/` here.

All Zuul `github-check` jobs skip docs-only changes via
`irrelevant-files` (`^.github/.*`, `^docs/.*`, `^.*\.md$`,
`^LICENSE.*$`).

| Job                                        | Purpose                                                                                                                         | Depends on                              | Definition                                                                                                                               |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `s2i-openstack-containers-molecule`        | Exercise the content provider's registry and cleanup contracts                                                                  | —                                       | `zuul.d/jobs.yaml` (this repo), scenario in `molecule/provider-contract/`                                                                |
| `s2i-openstack-container-content-provider` | Build **all** the s2i maintained images from the PR and publish them to a temporary registry running locally for dependent jobs | —                                       | `zuul.d/jobs.yaml` (this repo), playbooks in `playbooks/container-ci/`                                                                   |
| `s2i-openstack-container-consumer-smoke`   | Pull, inspect, and performs basic validation on every published image on a fresh consumer node                                  | content provider                        | `zuul.d/jobs.yaml` (this repo)                                                                                                           |
| `s2i-openstack-deploy-validation`          | Deploy a live OpenStack (CRC + EDPM + Ceph) with the s2i images and run a tempest smoke suite                                   | content provider **and** consumer-smoke | `zuul.d/jobs.yaml` (this repo)                                                                                                           |
| `<service>-s2i-test-*` (component jobs)    | Per-service deployment validation from the content provider images. The jobs are contributed by operator repositories           | content provider and consumer-smoke     | operator repositories, applied via `zuul.d/projects.yaml` here — see [Component jobs](#component-jobs-per-service-deployment-validation) |

**s2i-openstack-container-content-provider**

Builds every maintained image from the exact `sources.txt` pins of the
PR (default `s2i_ci_images: all`) and publishes them to a local registry
that jobs can pull from. The job pauses (keeps the  registry up) while
its dependent jobs run.
When the provider runs, **all** images are built together so every
container for a change is built from the same pins with consistent OS
packages; post-merge, the publish job additionally tags every image
with the same tags.
It runs on the  `s2i-openstack-containers-image-builder` nodeset (a larger
flavor than the default `-small` nodeset defined on the job). Playbooks:
`playbooks/container-ci/zuul/ {pre,run,post}.yaml` plus shared tasks under
`playbooks/container-ci/shared/`. See
[The Zuul content provider in depth](#the-zuul-content-provider-in-depth).

**s2i-openstack-containers-molecule**

Runs the Molecule `provider-contract` scenario through
`tox -e molecule`. The scenario (in `molecule/provider-contract/`) drives the
content provider playbooks against a fake local registry and asserts
the error contracts: malformed mapping values, duplicate metadata,
unknown or unbuilt image targets, and cleanup behavior. It runs on the
`s2i-openstack-containers-image-builder` nodeset (CentOS Stream 10).

**s2i-openstack-container-consumer-smoke**

A cheap contract check on a fresh CentOS Stream 10 consumer node: pull
every image the provider published from the buildset registry, inspect
it, and validate that the deployment key mappings resolve. It exists so
that a broken registry, an unpullable image, or a bad mapping fails in
minutes instead of starting the expensive CRC/EDPM deployment. Playbooks:
`playbooks/container-ci/zuul/consumer-smoke-pre.yaml` and
`consumer-smoke.yaml`.

**s2i-openstack-deploy-validation**

The full deployment gate: deploys OpenStack on OpenShift CRC with EDPM
computes and HCI Ceph via ci-framework, injects the s2i-built images
into `OpenStackVersion` during `edpm_prepare`, then runs a tempest
smoke suite covering compute, identity, image, network, object storage,
volume, scenario, heat, and ironic. It enables services that are not in
the default control plane (heat, ironic, swift, manila) so their s2i
images are actually exercised. This job gates PRs — especially
`update-sources` bumps — on real deployment validation.

**Base deploy+test jobs**

`zuul.d/jobs.yaml` also defines three **base** jobs that are never
scheduled directly. They are the parents used by the deploy+test
consumers described in [`operator-onboarding.md`](operator-onboarding.md)
and by this repository's `s2i-openstack-deploy-validation`:

- `s2i-test-base` — EDPM deployment (CRC + 2 computes, CentOS 10);
- `s2i-test-base-ceph` — HCI deployment with Ceph (CRC + 1 compute);
- `s2i-test-base-ceph-2comp` — HCI deployment with Ceph (CRC + 2 computes).

They apply the s2i image map to `OpenStackVersion` during
`edpm_prepare`, trust the s2i registry in CRC, and carry the
cinder-volume / manila-share backend-map plumbing.

### Component jobs: per-service deployment validation

The four `github-check` jobs above validate the repository as a whole.
On top of them, each openstack-k8s-operators **operator repository**
contributes *component jobs* that validate the deployment of the
specific service it operates, using the images built from the s2i PR.

**What they validate**

A component job deploys a live OpenStack on OpenShift CRC with EDPM
computes via ci-framework, applies the s2i-built service images to
`OpenStackVersion` during `edpm_prepare`, and runs the operator's
tempest/test-operator suite against the deployment. For example,
`cinder-s2i-test-ceph` deploys HCI Ceph with the s2i cinder images and
runs the cinder tempest tests; `test-operator-s2i-test` runs tempest
from the s2i tempest image.

**How the wiring works**

The wiring is deliberately split across two repositories:

1. **The operator repository**

   (`openstack-k8s-operators/<service>-operator`) defines, in its own
      Zuul configuration (`zuul.d/` or `.zuul.yaml`, depending on the
      repository layout):
   - the `<service>-s2i-test-<foo>` deploy+test jobs, parented on one of
    this repo's base `s2i-test-base[-ceph]` jobs;
   - a project-template named
     `<service>-operator-s2i-component-jobs` that schedules the test
     jobs **on this repository's** `github-check` pipeline:
     ```yaml
     # In openstack-k8s-operators/<service>-operator
     - project-template:
         name: <service>-operator-s2i-component-jobs
         github-check:
           jobs:
             - <service>-s2i-test-<foo>:
                 vars:
                   # s2i is the sole content provider in this repo's
                   # pipeline, so point CRC at its registry.
                   content_provider_registry_ip: "{{ s2i_content_provider_registry_ip }}"
                 files:
                   - ^containers/base/
                   - ^containers/<service>/
                 dependencies:
                   - s2i-openstack-container-content-provider
                   - s2i-openstack-container-consumer-smoke
     ```
2. **This repository** applies the template in

   [`zuul.d/projects.yaml`](../zuul.d/projects.yaml):

The RDO Zuul tenant loads the operator repositories' configuration, so
the templates they define are referenceable from this repository's
project stanza.

Key properties of the template:

- **Trigger.** The test jobs run on s2i PRs whose diff matches the
template's `files:` patterns — typically `^containers/base/` (every
service inherits the base image) and the directories of the images
the operator consumes. The patterns are tailored per operator: for
example `nova-operator-s2i-component-jobs`matches `^containers/nova/`
and `^containers/placement/`. Individual jobs in a template may be
marked `voting: false` while they stabilize.
- **Dependencies.** The jobs depend on this repo's content provider
(which builds **all** images, including the service under test) and
on the consumer smoke job, so the CRC/EDPM deployment only starts
after the images are built and proven pullable. The operator's own
`<service>-s2i-content-provider` is *not* scheduled here — this
repo's provider already builds everything.

**Adding a new component job**

Component jobs are added in two steps, in this order:

1. In the operator repository, define the jobs and the

   `<service>-operator-s2i-component-jobs` template following
      [`operator-onboarding.md`](operator-onboarding.md) (Phase 1 covers
      the job definitions; the template mirrors the example above). The
      template must be reviewed and merged in the operator repo first,
      otherwise this repository's project stanza references an undefined
      template and tenant configuration fails to load.
2. In this repository, add the template to the `templates:` list in

   `zuul.d/projects.yaml` (one line, keeping the list alphabetically
      sorted).

## Daily automation: the update-sources workflow

Merged upstream code in OpenDev does not reach the published images until the
pins in `sources.txt` are advanced. That is automated by the
**Update sources** GitHub Actions workflow
(`.github/workflows/update-sources.yml`):

1. **Trigger.** A cron schedule (`17 5 `* * *, daily at 05:17 UTC) or a

   manual `workflow_dispatch`.
2. **Update.** Runs `STREAM=master tox -e update-sources`, which for

   every project resolves the tracked branch tips with `git ls-remote`,
      advances the pinned hashes in `sources.txt`, and regenerates
      `requirements.lock.<stream>`, `buildrequirements.lock.<stream>`,
      `upper-constraints.txt.<stream>`, and `rpms.in.yaml`.
3. **Propose.** If anything under `containers/` changed, the workflow

   force-pushes the `auto/update-sources` branch and opens (or reuses)
      a pull request titled **"Update sources"** authored by
      `github-actions[bot]`.

The workflow **never merges the PR itself**. The PR goes through the
same validation as any other change — and it is exactly the kind of
change the heavy jobs are for: the lockfile reproducibility check
regenerates the locks, the content provider builds **all** images from
the new pins, `s2i-openstack-deploy-validation` gates the bump on a
live deployment, and the component jobs validate the services whose
pins moved. Maintainers review and merge the PR; `main` only moves when
that PR merges. Once merged, the post-merge build-and-push job
publishes the new pins to Quay (see below).

## Publication: the post-merge build-and-push job

### Job definition and wiring

Image publication is a Zuul job named
`s2i-openstack-container-build-push`, defined in the
[rdoproject.org config repository](https://review.rdoproject.org/r/q/project:config):

- job definition: `zuul.d/s2i-openstack-build-push.yaml`
- playbooks: `playbooks/s2i/` (`prepare-host.yaml`, `build-images.yaml`,
`push-images.yaml`, `post.yaml`, and Quay housekeeping tasks)
- wiring to this repository: `zuul.d/projects.yaml` in the config repo
adds the job to
`github.com/openstack-k8s-operators/s2i-openstack-containers` on the
`github-post` pipeline, branch `main`.

The job lives in the config repo — instead of this repository — because
it must use the Quay robot secret
(`quay_io_openstack_s2i_containers_robot`), which can only be attached
to a job defined in a trusted config project. The job builds on the
`s2i-openstack-containers-image-builder` nodeset defined in this
repository's `zuul.d/nodesets.yaml`.

### Trigger

The `github-post` pipeline runs after every merge (push) to `main`. The
job deliberately sets **no** `files:` **filter**: the last-known-good
baseline images on Quay must be republished for every push, including
`zuul.d`-only or docs-only merges that a path filter would skip.

The job **must never** be added to `github-check`, `github-manual`, or
any other PR pipeline: those pipelines run on unreviewed PR code and
would expose the push secret.

### Build and push phases

With `s2i_ci_images: all` and `s2i_ci_stream: master`, the job:

- builds every image with `build.sh build-parallel`, tagged
`master-<zuul.newrev>` and `master-latest`;
- resolves the intended refs with `build.sh refs` and validates them;
- ensures each Quay repository exists and is public (Quay API
`createRepo`; HTTP 201/400 both treated as success) and grants the
robot write permission;
- pushes each ref with `buildah push --digestfile`, recording digests;
- copies each `master-<sha>` tag to an additional
`sha256-<manifest-digest>` tag with `skopeo` (digest-verified);
- logs out and writes the `content-set.yaml` digest catalog next to the
build logs (`zuul-output/logs/container-build/`).

### Published tags, labels, and digest catalog

Images are published to `quay.io/openstack-s2i-containers/` with three
tags per image:

- `<stream>-latest` — rolling tag, always pointing to the last
successfully built and validated containers for that stream.
- `<stream>-<sha>` — immutable tag tied to the specific commit in
this repository that produced the build.
- `sha256-<manifest-digest>` — content-addressed tag for the pushed
manifest. It preserves the manifest and its layers when the rolling
tag moves to a later build.

For example, for the `master` stream an image is tagged as
`master-latest`, `master-<commit-sha>`, and `sha256-<manifest-digest>`.
No publication tag is assigned a Quay expiration.

The post-merge push writes a digest catalog (`content-set.yaml`) next
to the build logs, built from the recorded digests and
`containers/image-mappings.yaml`, so consumers can pin by digest
instead of racing `:master-latest`.

## The Zuul content provider in depth

The `s2i-openstack-container-content-provider` job runs on the
CentOS Stream 10 nodeset host named `builder`. All host preparation,
registry validation, builds, publication, result generation, and
cleanup target that host explicitly. The Zuul executor controls Ansible
but does not perform those mutations.

The job applies caching for Python packages and RPM downloads to
reduce duplicate network transfers during the build.

The provider copies the RDO base job's `/etc/pip.conf` into a job-local file
and mounts it into Buildah so Python downloads use the provider mirror. It also
can run an ephemeral Squid container directly with Podman. Squid caches direct
upstream HTTP traffic or can sit in front of the provider's CentOS mirror. The
cache is published on the disposable builder and Buildah RUN steps reach it through
`host.containers.internal`. Proxy values are passed as build arguments so
host-side base-image pulls are not routed through the package cache. The cache
intentionally listens without authentication on all interfaces of the
disposable CI builder. Plain-HTTP CentOS Stream requests can be remapped to the
provider's CentOS mirror. Otherwise, Squid rewrites plain-HTTP CentOS requests
to the upstream HTTPS origin before fetching them, without intercepting client
TLS. The job does not consume host RPM repository files or require
`podman-compose`. Post-run cleanup
removes the cache container, its volumes, and generated configuration.
Persistent source caching is explicitly disabled
because Zuul already stages speculative source trees and the builder is
disposable.

`s2i_ci_use_provider_pip_mirror` controls whether the parent-provided
`pip.conf` is mounted, `s2i_ci_enable_rpm_cache` controls the RPM proxy, and
`s2i_ci_rpm_cache_use_provider_mirror` controls its optional CentOS Stream
backend remap. Disabling Squid leaves RPM repository access unchanged;
the provider mirror still applies to Python downloads when its pip option is
enabled. The content-provider currently disables the RPM backend remap because
the Vexxhost mirror does not carry the CentOS Stream 10 SIG repositories used
by these images. Squid therefore caches their original repository URLs.
Collapsed forwarding combines concurrent requests for the same object, and
`repomd.xml` remains fresh for the two-hour job despite DNF cache-bypass
headers. Squid access and error logs are staged under
`zuul-output/logs/squid/` for troubleshooting.

### Image selection and child jobs

In this repository the provider defaults to `all`, so every maintained
image is built from its exact `sources.txt` pins. A child job can set
`s2i_ci_images` to an explicit list of image targets; the provider
resolves the selection through `build.sh` and publishes only that set.
The caller is responsible for including `base` in the list if service
images depend on it.

To compose the provider in an operator repository, define
`<service>-s2i-content-provider` that parents this job, add the
container repository to `required-projects`, and override `s2i_ci_images`
with that service's image targets. The matching deploy job is
`<service>-s2i-test-<foo>` (see
[`operator-onboarding.md`](operator-onboarding.md)). Zuul places those
projects in the shared buildset workspace. Speculative source staging
is described in [Speculative builds of OpenDev changes](#speculative-builds-of-opendev-changes).

### Image deployment metadata

The repository-level `containers/image-mappings.yaml` associates exact
build targets with OpenStackVersion custom-image fields. Unlisted
targets have no deployment mapping but are still built and returned.
The consolidated `watcher/watcher-base` image declares:

```yaml
openstack_version:
  custom_container_images:
    watcher/watcher-base:
      - watcherAPIImage
      - watcherApplierImage
      - watcherDecisionEngineImage
```

All three keys resolve to the same exact `openstack-watcher-base`
reference.

Unlisted targets are still built. They are absent from the central mapping
on purpose:

- `base` is not a service image.
- `cyborg/*` is not wired into the default control plane yet.
- `tempest` and `ansible-test` are test images, not control-plane services.
- `cinder/cinder-volume` and `manila/manila-share` must be set as
  `cinderVolumeImages` / `manilaShareImages` backend maps, which this
  scalar mapping format cannot express.
- s2i does not build `nova-compute`, `nova-conductor`, `nova-scheduler`,
  `nova-novncproxy`, or placement. Those OpenStackVersion fields stay on
  operator defaults.

A child job may provide `s2i_ci_image_mappings` as a mapping from a
selected image target to a replacement list of keys. Replacement is per
image rather than additive. The provider records whether each effective
list came from tracked or inventory metadata and rejects malformed
values, unknown or unbuilt image targets, empty key strings, duplicate
keys, and a key assigned to more than one image.

### Registry and returned data

The provider starts or inherits a Zuul buildset registry, validates push and
pull with a dedicated UBI tag, builds and pushes the selected image set, and
pulls every exact result back. Credentials and certificate data remain in
Zuul secret data. Returned public diagnostics use the buildset registry's
reachable host or IP and port, never the builder-local registry alias.

`s2i_ci_content.images` contains every exact successful reference, including
base and other unmapped images. The partial
`s2i_content_provider_os_custom_container_images` map contains only effective
keys joined to exact successful references. The legacy global OS registry URL
remains the neutral `null` sentinel, while its namespace/tag and gating-repo
fields remain empty or false because this selective provider does not publish a
complete OpenStack image namespace. `s2i_cifmw_build_images_output`
remains an empty mapping and is not repurposed for service images.

All returned variables use the `s2i_content_provider_` or `s2i_cifmw_` prefix
to avoid colliding with the standard `openstack-k8s-operators-content-provider`
when both run as parents of the same consumer job.

Intended references are written before build mutation. Post-run cleanup
removes only those exact Podman pullback and Buildah build tags, verifies exact
absence, and removes a buildset registry only when its ownership marker is
valid.
Per-image parallel logs and registry/result manifests are retained under
`zuul-output/logs/container-build/`.

The provider pauses while dependent jobs run. In this repository,
`s2i-openstack-container-consumer-smoke` is the cheap contract check
(pull, inspect, deployment-key resolution on a fresh node) and
`s2i-openstack-deploy-validation` is the live CRC/EDPM consumer. Both
must remain **direct** dependents of the provider, together with the
component jobs so the registry stays paused until they finish.

## Consuming S2I containers in OpenStack Operators

Changes in openstack operators repos main or 19.0 branches are expected
to deploy S2I container images in their validation jobs. While, the
`openstack-operator` defaults to latest pushed containers via `:master-latest`
tag, what should be enough for jobs to use S2I images.

However, operators can also add their own s2i content provider job to build
only the specific images relevant for the operator. This allows that a PR can
use `Depends-On` to pull in unmerged changes from this repository and/or from
the related upstream OpenStack project. For example, a change in
`watcher-operator` can exercise an open PR here and/or an open change
in `openstack/watcher`.

To compose the provider in an operator repository, define
`<service>-s2i-content-provider` that parents this job, add the
container repository to `required-projects`, and override `s2i_ci_images`
with that service's image targets.

How to wire those jobs is documented in the
[`operator-onboarding.md`](operator-onboarding.md).

## Speculative builds of OpenDev changes

When a patch is submitted against an upstream OpenStack project (e.g.,
`openstack/tempest`), the CI pipeline can automatically build fresh
container images incorporating that patch. This is called a
**speculative build**. That new build can also be used in a nested
deployment job to validate the ongoing patch using operators deployment.

### Auto-detection

The content provider job accepts `s2i_ci_images: auto` to automatically
determine which images need rebuilding based on the triggering project:

```yaml
# In a Zuul job definition
vars:
  s2i_ci_images: auto
```

Under the hood, auto-detection:

1. Inspects `zuul['items']` to find the projects in the speculative

   change queue.
2. Runs `build.sh auto-detect` with each change's Zuul `project.name`

   (e.g. `openstack/tempest`). Auto-detect also accepts a full git URL
      or a Zuul canonical name (`opendev.org/openstack/tempest`).
3. Replaces `s2i_ci_images` with the de-duplicated list of affected

   image targets.

You can test auto-detection locally:

```bash
# Which images would be rebuilt for a tempest patch?
PARALLEL=1 ./build.sh auto-detect openstack/tempest master

# Full URL form also works
PARALLEL=1 ./build.sh auto-detect https://opendev.org/openstack/neutron.git

# Zuul canonical names match the same images
PARALLEL=1 ./build.sh auto-detect opendev.org/openstack/tempest master
```

### Source staging

After auto-detection resolves the image list, the pipeline stages Zuul's
source checkouts into the container build contexts. This replaces the
pinned source with the patched version so the built image includes the
speculative change.

The staging playbook (`shared/stage-zuul-sources.yaml`) delegates all
`sources.txt` parsing to `build.sh list-sources`, keeping build.sh as
the single source of truth for the source manifest format.

`list-sources` emits project paths as they appear in `sources.txt`
(`openstack/tempest`). Zuul's `zuul.projects` is keyed by canonical
names (`opendev.org/openstack/tempest`). The staging playbook maps both
forms so speculative checkouts are copied into `src/` instead of
building from the pinned git hash.

Staging alone is not enough: committed `requirements.lock.<stream>`
still pins the last `update-sources` run. After any sources are staged,
the content provider runs `tox -e sync-locks` for those projects. That
command:

- Refreshes `upper-constraints.txt.<stream>` from the stream branch tip,
or from a Zuul `openstack/requirements` checkout when one is in the
buildset (`REQUIREMENTS_SRC`, for example a `Depends-On` constraints
bump).
- Leaves staged `src/` trees in place and clones any missing sibling
repos at the **committed pin**, not the branch tip.
- Regenerates `requirements.lock.<stream>` and
`buildrequirements.lock.<stream>` from the current `src/*/requirements.txt`
trees plus `pythondeps.txt`.
- Does **not** rewrite hashes in `sources.txt` and does **not**
regenerate `rpms.in.yaml`.

Do not use `update-sources` here. It would advance unstaged sibling pins
to branch tip and rewrite `sources.txt`.

### Querying source dependencies

`build.sh list-sources` prints pipe-delimited records for all source
dependencies of an image target:

```bash
PARALLEL=1 ./build.sh list-sources tempest/tempest master
# Output: name|canonical_project|url|dest_dir
# tempest|openstack/tempest|https://opendev.org/openstack/tempest.git|/.../containers/tempest/src/tempest
# barbican-tempest-plugin|openstack/barbican-tempest-plugin|https://...
```

This is used by the Ansible playbooks but is also useful for debugging
which upstream repos feed into a given image.

### Adding speculative deploy+test validation for a service

Once the content provider can build images for a service, wire a live
deploy+test job on the operator repository. Follow
[`operator-onboarding.md`](operator-onboarding.md).

## Related documentation

- [`TESTING.md`](TESTING.md) — concise local testing entry point.
- [`developer-guide.md`](developer-guide.md) — build, sources, lockfiles,
and maintenance workflows.
- [`operator-onboarding.md`](operator-onboarding.md) — wiring a
speculative deploy+test job on an operator repository (the consumer
side of the content provider).
- [`testing-opendev-patches.md`](testing-opendev-patches.md) — building
an image that includes an unmerged OpenDev change, by hand.
- [`design.md`](design.md) — container image design principles.
