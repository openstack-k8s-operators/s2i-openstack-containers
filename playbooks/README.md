# Ansible CI helpers (Zuul)

Thin orchestration around `build.sh` for Zuul jobs.

| Path | Purpose |
| --- | --- |
| `roles/s2i_build/` | Map job vars → env → `build.sh` (build/push only) |
| `playbooks/pre.yaml` | Stage Zuul checkouts into `containers/.../src/...` |
| `playbooks/run.yaml` | Resolve repo dir + invoke `s2i_build` |
| `zuul.d/jobs.yaml` | Job definitions (parent: `cifmw-base-minimal` / `tox`) |
| `zuul.d/jobs-layout.yaml` | `github-check` project layout |

## Contracts

### `playbooks/pre.yaml`

* No-op if `s2i_build_sources` is empty/unset.
* Each entry needs `project` (key in `zuul.projects`) and `dest` under
  `containers/` (no `..`, no trailing `/`).
* Fails if the project is missing from `zuul.projects` or the checkout is
  not on disk.
* Uses `rsync -a --delete` so the destination matches the Zuul tree.

### `playbooks/run.yaml` + `roles/s2i_build`

* Resolves `s2i_build_repo_dir` from the var or `zuul.project.src_dir`.
* Invokes the role; see `roles/s2i_build/README.md` for the build/push
  contract.

## Local dry-run

```bash
# Role contract tests (fake build.sh, no containers)
./tests/test_s2i_build_role.sh

# Real build (requires buildah/podman)
ansible-playbook -i localhost, -c local \
  -e ansible_python_interpreter=auto_silent \
  playbooks/run.yaml \
  -e s2i_build_repo_dir=$PWD \
  -e '{"s2i_build_targets":["watcher"]}' \
  -e s2i_build_stream=master
```

## Testing on Zuul (RDO `github-check`)

Same pattern as
[data-plane-adoption](https://github.com/openstack-k8s-operators/data-plane-adoption/tree/main/zuul.d):
jobs live in this repo; the RDO tenant must list the project.

### 1. Onboard the repo (one-time)

Two places (same pattern as lightspeed-tests):

1. **RDO config** (`review.rdoproject.org/config`) — add to
   `zuul.d/projects.yaml`:

```yaml
- project:
    name: github.com/openstack-k8s-operators/s2i-openstack-containers
    default-branch: main
    templates:
      - system-required
```

2. **SF tenant config**
   ([softwarefactory-project/config](https://gitlab.com/softwarefactory-project/config))
   — add the GitHub project to the rdoproject.org tenant (see recent
   lightspeed MRs for the exact stanza). The RDO change usually
   `Depends-On` that SF MR.

### 2. Open a PR against this repo

Once the tenant change is merged, a PR that touches the role/playbooks will
run:

* `s2i-openstack-containers-tox` (voting) — mock role contract via `tox -e test`
* `s2i-openstack-containers-build-watcher` (non-voting) — real build +
  `openstack/watcher` overlay through `pre.yaml`

Comment `recheck` on the PR to re-run.

### 3. Optional: drive a job from testproject

Same idea as
[deploy_va.md](https://ci-framework.readthedocs.io/) testproject flow: define a
child job in `ci-framework-testproject` that parents
`s2i-openstack-containers-build-watcher` (or the base), and put
`Depends-On: <this-PR-URL>` in the MR body. The s2i repo must already be in the
tenant for Depends-On / required-projects to resolve.
