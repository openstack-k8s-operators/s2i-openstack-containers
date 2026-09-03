# Onboarding an operator for s2i speculative deploy

Step-by-step playbook to add a Zuul job that builds s2i OpenStack service
images and deploys them through `OpenStackVersion` on an operator
repository's `github-check` pipeline.

Do not copy the existing test jobs from the operator repositories blindly.
Some of them (for example test-operator and at the moment watcher-operator)
are special cases.

For how the content provider job works in this repository, see the
[developer guide](developer-guide.md#zuul-content-provider).
This document covers the **consumer** side: wiring a live deploy+test
job in an operator repo. Do not copy this repository's own
github-check graph (`content-provider` → `consumer-smoke` →
`deploy-validation`); that wiring is documented under
[This repository's github-check pipeline](developer-guide.md#this-repositorys-github-check-pipeline).

## Goal

On an operator GitHub PR, Zuul must:

1. Build operator images with `openstack-k8s-operators-content-provider`.
2. Build that service's containers with `<service>-s2i-content-provider`
   (child of `s2i-openstack-container-content-provider`).
3. Deploy OpenStack with the s2i service images applied to
   `OpenStackVersion` **during** `edpm_prepare` (before the control
   plane comes up).
4. Run the operator's existing test-operator (or equivalent) against that
   deployment via a test job. The naming convention for such jobs is:
   `<service>-s2i-test[-<foo>]`, where the optional `<foo>` suffix is
   used to distinguish the various testing jobs for the same component.

Keep the existing kuttl and test-operator jobs unchanged, which can be used
to test the newer operators with the old content. The s2i jobs are
**new** siblings, not replacements. Once they are stable they should
be turned to voting.

Job names in the operator repo:

| Job | Parents | Purpose |
|-----|---------|---------|
| `<service>-s2i-content-provider` | `s2i-openstack-container-content-provider` | Build this service's s2i images |
| `<service>-s2i-test` | The operator's existing deploy+test job | Deploy those images and run test-operator tests |

Example: `cinder-s2i-content-provider`, `cinder-s2i-test-ceph`.

```
Operator PR (github-check)
        |
        +-- openstack-k8s-operators-content-provider
        |     (operator catalog; owns content_provider_registry_ip)
        |
        +-- <service>-s2i-content-provider
        |     (service images; s2i_content_provider_registry_ip:5001)
        |
        v
<service>-s2i-test-foo
  parents the operator's existing deploy+test job
  trusts both registries
  applies cifmw_set_containers_images during edpm_prepare
  runs the parent's test-operator tests
```

## Classify the operator

Use one of the two component base jobs defined in this repository as parent
for the deploy+test job:

- `s2i-test-base`
- `s2i-test-base-ceph` (a variant of `s2i-test-base` which deploys a minimal
  ceph and configures a few services with it).

Do **not** parent `s2i-openstack-deploy-validation` (defined in this
repo) on operator github-check. That job is special in the way s2i is
the **sole** content provider. It sets `content_provider_registry_ip`
to the s2i registry, which steals the operator catalog.

Do **not** copy this repository's own `github-check` job graph onto an
operator pipeline either. Here the image jobs are
`s2i-openstack-container-content-provider` →
`s2i-openstack-container-consumer-smoke` →
`s2i-openstack-deploy-validation`. That last job depends on **both** the
content provider (paused registry and artifacts) and consumer-smoke (skip
CRC/EDPM when pull/inspect/mapping fails). Operator pipelines still use
`<service>-s2i-test-<foo>` with dual-registry trust as shown below. Smoke is
optional on the operator side; see
[Optional fail-fast](#optional-fail-fast-consumer-smoke).

## Phase 0: inventory

Before writing Zuul YAML, collect these facts from the operator repo
and from this repository.

### Images s2i can build

Under `containers/<service>/`. Example for cinder: `cinder-api`,
`cinder-backup`, `cinder-scheduler`, `cinder-volume`. The content
provider always builds `base` as a dependency when you list service
images.

### OpenStackVersion mappings

Read [`containers/image-mappings.yaml`](../containers/image-mappings.yaml).

- **Scalar fields** (for example `cinderAPIImage`) are returned in
  `s2i_content_provider_os_custom_container_images` and can be passed
  straight to `cifmw_set_containers_images`.
- **Unmapped on purpose:**
  - `base` — not a service image
  - `tempest`, `ansible-test` — test images
  - `cinder/cinder-volume`, `manila/manila-share` — backend **maps**,
    not scalars
  - nova-compute / nova-conductor / nova-scheduler / nova-novncproxy /
    placement — s2i does not build them; they stay on operator defaults
- **Mapped but omitted by this repo's deploy-validation job:**
  `neutronAPIImage`, `edpmNeutronMetadataAgentImage`,
  and `mariadbImage`.
  `s2i-openstack-deploy-validation` filters them with
  `s2i_ci_skip_os_custom_images` until those images can be consumed
  by the control plane, so `preserve_unlisted` keeps payload
  defaults. The content provider still returns every mapped key.
  Operator consumer jobs must inject them: leave the skip list unset
  or empty. Do not replace the mappings with `quay.io` `master-latest`
  pins. When operators are ready, remove the keys from the skip list
  rather than deleting the mappings.

If a scalar service image is missing from the mapping, add it in this
repo first. Do not invent OpenStackVersion field names; they must match
`spec.customContainerImages` on
`core.openstack.org/v1beta1 OpenStackVersion`.

### Backend map names (cinder / manila only)

`cinderVolumeImages` and `manilaShareImages` are maps keyed by the
**CinderVolume / ManilaShare resource name**, not the driver name.

HCI Ceph in ci-framework uses CinderVolume `volume1` (the Ceph driver
is configured inside that CR). openstack-operator looks up
`CinderVolumeImages[<name>]` and otherwise falls back to `"default"`.
The `"default"` key is **always reset** to the operator
`RELATED_IMAGE`; setting `backends: [default]` does not change the
running volume pod.

Find the name of all backends from the parent job's kustomize
(for a simple HCI job: `cinderVolumes/volume1`).

## Phase 1: github-check (required)

This is the only phase needed to prove the job. Do it first.

### Dual registry

github-check already runs `openstack-k8s-operators-content-provider`.
CRC trusts that registry via `content_provider_registry_ip`. The s2i
provider publishes to a **second** plain registry.

Do **not** set:

```yaml
content_provider_registry_ip: "{{ s2i_content_provider_registry_ip }}"
```

That overwrites the operator catalog host. Append s2i instead:

```yaml
cifmw_crc_additional_insecure_registries:
  - "{{ s2i_content_provider_registry_ip }}:5001"
cifmw_crc_additional_allowed_registries:
  - "{{ s2i_content_provider_registry_ip }}:5001"
```

### Image injection

ci-framework `edpm_prepare` calls `cifmw.general.set_containers` when
`cifmw_set_containers_images` is non-empty. That is early enough.
A `pre_tests` `oc patch` is too late.

The two parents jobs take care of this, so do not overload
`cifmw_set_containers_images`.

```yaml
cifmw_set_containers_preserve_unlisted: true
cifmw_set_containers_images: >-
  {{
    s2i_content_provider_os_custom_container_images | dict2items |
    json_query('[].{name: key, full_registry: value}')
  }}
```

`preserve_unlisted: true` keeps images not in the s2i map from the
current OpenStackVersion CR.

`s2i-speculative-deploy-test-base` (this repository only) optionally
filters that map through `s2i_ci_skip_os_custom_images`, which is empty
by default. Only `s2i-openstack-deploy-validation` sets a skip list
today (`neutronAPIImage`, `edpmNeutronMetadataAgentImage`,
`mariadbImage`). Do **not** copy that skip list into
`<service>-s2i-test-<foo>`. Operator jobs should pass the full
`s2i_content_provider_os_custom_container_images` map as shown above.

### Backend maps

Only for jobs testing cinder and manila, append the discovered
cinder and manila backends as a list to respectively:

- `s2i_cinder_volume_backends`
- `s2i_manila_share_backends`

`s2i-test-base` emits `cinderVolumeImages` / `manilaShareImages` from
the provider tag only when `cinder/cinder-volume` or
`manila/manila-share` is in `s2i_ci_content.selected_images`. Include
those targets in the child provider's `s2i_ci_images` list if the job
should run s2i volume/share images. Otherwise volume and share pods
keep payload defaults.

### Job skeleton

Place both jobs in the operator's `zuul.d/jobs.yaml` (or `.zuul.yaml` if
that is how the repo is laid out). Do not add the generic
`s2i-openstack-container-content-provider` to the project pipeline;
inherit it under the operator's own name.

```yaml
- job:
    name: <service>-s2i-content-provider
    parent: s2i-openstack-container-content-provider
    description: |
      Build s2i <service> images for <service>-s2i-test-<foo>.
    required-projects:
      - name: openstack-k8s-operators/s2i-openstack-containers
        override-checkout: main
    vars:
      s2i_ci_images:
        - <service>/<image-a>
        - <service>/<image-b>

- job:
    name: <service>-s2i-test-<foo>
    parent: s2i-test-base[-ceph]
    description: |
      Validate speculatively-built s2i <service> images against a live
      OpenStack deployment. s2i-built images from the content provider
      are applied to OpenStackVersion during edpm_prepare via
      ci-framework set_containers before the control plane is deployed.
    vars:
      cifmw_test_operator_tempest_include_list: |
         ...
```

Do not copy `s2i_ci_skip_os_custom_images` from
`s2i-openstack-deploy-validation` into operator consumer jobs.

Use an explicit `s2i_ci_images` list on github-check. `auto` is for
OpenDev patches, where the triggering project is `openstack/<service>`.
On an operator PR, auto-detect looks at operator sources and finds no
`sources.txt` match.

### Project pipeline

In `zuul.d/projects.yaml` (or the project stanza in `.zuul.yaml`):

```yaml
- project:
    name: openstack-k8s-operators/<service>-operator
    github-check:
      jobs:
        - openstack-k8s-operators-content-provider:
            vars:
              cifmw_install_yamls_sdk_version: v1.41.1
        # existing kuttl / test-operator unchanged
        - <service>-s2i-content-provider:
            voting: false
        - <service>-s2i-test-<foo>:
            voting: false
            dependencies:
              - openstack-k8s-operators-content-provider
              - <service>-s2i-content-provider
```

Keep both content providers as **direct** dependencies for the test job.
It is what keeps each paused registry up until CRC finishes. Do not replace
those lines with a dependency on smoke alone.

### Optional fail-fast (consumer smoke)

This repository gates `s2i-openstack-deploy-validation` on
`s2i-openstack-container-consumer-smoke`. Operators can do the same
before `<service>-s2i-test-<foo>`: smoke pulls and inspects the published
images on a cheap CentOS node so a broken registry or mapping does not
start CRC.

Depend on `<service>-s2i-content-provider` (the job name in **this**
pipeline), not `s2i-openstack-container-content-provider`. That parent
job is not scheduled on the operator pipeline. Keep both content
providers as direct dependencies for the test job so each paused registry
stays up.

```yaml
        - s2i-openstack-container-consumer-smoke:
            voting: false
            dependencies:
              - <service>-s2i-content-provider
        - <service>-s2i-test-<foo>:
            voting: false
            dependencies:
              - openstack-k8s-operators-content-provider
              - <service>-s2i-content-provider
              - s2i-openstack-container-consumer-smoke
```

This is optional. Phase 1 is complete without it.

### Watcher-only extras

watcher-operator also:

- Switched github-check from the **meta** content provider to
  `openstack-k8s-operators-content-provider` (operator images only;
  service images come from s2i).
- Folded s2i jobs into the existing `opendev-watcher-edpm-pipeline`
  template because RDO config already applies that template to
  `openstack/watcher`, `python-watcherclient`, and
  `watcher-tempest-plugin`.
- Limited OpenDev s2i jobs with `files: [^watcher/]` so client and
  tempest-plugin changes do not rebuild containers.

Most operators already use the non-meta operator content provider and
have **no** OpenDev EDPM template. Skip those extras unless the same
facts are true for the operator you are onboarding.

## Phase 2: OpenDev Gerrit (optional)

Do this only after github-check has applied s2i images and the test job
has run.

Two wiring options:

1. **Existing `opendev-<service>-edpm-pipeline` in the operator repo,
   already applied by the config repo** (watcher): add the s2i provider
   and consumer to that template in place. Use `s2i_ci_images: auto`,
   `files:` on the service source tree, and `override-checkout: main`.
2. **No such template** (cinder and most others): add a project stanza
   in
   [`openstack-k8s-operators/config`](https://github.com/openstack-k8s-operators/config)
   `zuul.d/s2i-openstack-speculative-builds.yaml` using the
   `s2i-speculative-build` template, plus the consumer job with
   dependencies on both content providers.

Do not invent a new `opendev-<service>-edpm-pipeline` inside the
operator just to copy watcher. That template exists because RDO already
pointed Gerrit watcher projects at it.

End-to-end OpenDev proof needs a DNM patch on
`opendev.org/openstack/<service>` with `Depends-On:` pointing at the
operator PR.

Projects that only need build validation (no deployment) can use the
template alone:

```yaml
- project:
    name: opendev.org/openstack/<service>
    templates:
      - s2i-speculative-build
```

The `s2i-speculative-build` template still schedules the generic
`s2i-openstack-container-content-provider` with `s2i_ci_images: auto`.
Depend on that job, not `<service>-s2i-content-provider` (that child
exists only on the operator github-check pipeline).

A deploy+test OpenDev stanza looks like:

```yaml
- project:
    name: opendev.org/openstack/<service>
    templates:
      - s2i-speculative-build
    check:
      jobs:
        - openstack-k8s-operators-content-provider:
            vars:
              cifmw_install_yamls_sdk_version: v1.41.1
        - <service>-s2i-test-<foo>:
            voting: false
            dependencies:
              - openstack-k8s-operators-content-provider
              - s2i-openstack-container-content-provider
```

## Prove it worked

From the consumer job logs / must-gather, `OpenStackVersion`
`spec.customContainerImages` must show s2i registry URLs, for example:

```yaml
cinderAPIImage: <s2i-ip>:5001/openstack/openstack-cinder-api:<tag>
cinderBackupImage: <s2i-ip>:5001/openstack/openstack-cinder-backup:<tag>
cinderSchedulerImage: <s2i-ip>:5001/openstack/openstack-cinder-scheduler:<tag>
cinderVolumeImages:
  volume1: <s2i-ip>:5001/openstack/openstack-cinder-volume:<tag>
```

Pods for those services must pull from the s2i registry, not only
quay.io operator defaults. Tempest failures after a correct
OpenStackVersion are a test-filter problem, not an injection problem.

## Checklist

- [ ] Classified the operator (test image vs custom EDPM vs typical)
- [ ] Confirmed s2i image targets and `image-mappings.yaml` scalars
- [ ] For cinder/manila: identified backend map key (HCI: `volume1`)
- [ ] Jobs named `<service>-s2i-content-provider` and
      `<service>-s2i-test-<foo>`
- [ ] Content provider child parents
      `s2i-openstack-container-content-provider` (do not add the
      generic job to the operator pipeline)
- [ ] Consumer job parents one of the two base jobs
- [ ] Do not copy this repo's `s2i-openstack-deploy-validation`
      dependency list; keep both content providers as direct
      dependencies for the test job.
      Optional: add `s2i-openstack-container-consumer-smoke`
      as an extra test job dependency (depend on
      `<service>-s2i-content-provider`, not the generic parent job)
- [ ] Do not copy `s2i_ci_skip_os_custom_images` from
      `s2i-openstack-deploy-validation`
- [ ] Dual registry: additional insecure **and** allowed; operator CP
      keeps `content_provider_registry_ip`
- [ ] `cifmw_set_containers_preserve_unlisted: true`
- [ ] No Zuul vars starting with `_`
- [ ] Existing kuttl/test-operator jobs unchanged
- [ ] New jobs `voting: false` until they are stable
- [ ] Explicit `s2i_ci_images` list on github-check
- [ ] OpenStackVersion in a live run shows s2i URLs (including backend
      maps if applicable)

## Common failures

| Symptom | Likely cause |
|---------|--------------|
| Zuul: `Invalid Ansible variable name '_...'` | Job `vars` must not start with `_` |
| Operator catalog / CRC cannot pull operator images | `content_provider_registry_ip` was pointed at s2i |
| CRC cannot pull s2i service images | Missing `cifmw_crc_additional_*` registries |
| API/scheduler s2i, volume pod still quay | Missing `cinderVolumeImages.<CinderVolume name>` |
| Volume map set on `default` but pod unchanged | Operator always overwrites the `default` key |
| `s2i_ci_images: auto` on an operator PR builds nothing useful | Auto-detect matches OpenDev `sources.txt` projects, not operator git |
| Images appear only after test job starts | Injection used `pre_tests` instead of `edpm_prepare` / `set_containers` |
| CRC/EDPM skipped after a short consumer-smoke failure | Expected if smoke is a test job dependency: pull, inspect, or deployment-key resolution failed. Fix the s2i provider return, then test-operator will run. |
| Smoke job: `Job s2i-openstack-container-content-provider not defined` | Smoke depends on a job name that is not in this pipeline. On an operator repo depend on `<service>-s2i-content-provider`. |
| Registry gone while the test job is still pulling | Test job lost its **direct** dependency on the s2i content provider (depended only on smoke). Keep the provider listed on the test job. |
| Neutron/MariaDB/Glance image stays on payload defaults in an operator job | Copied `s2i_ci_skip_os_custom_images` from `s2i-openstack-deploy-validation`; that skip list is only for this repo's gate |
