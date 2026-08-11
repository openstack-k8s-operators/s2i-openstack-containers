# s2i_build

Thin Ansible role that invokes `build.sh` from this repository.

## Contract (what this role promises)

1. Requires `s2i_build_repo_dir` pointing at a tree that contains `build.sh`.
2. Runs `./build.sh <action> <targets…>` with `STREAM`, `REGISTRY`,
   `NAMESPACE`, `TAG`, and `IMAGE_PREFIX` in the environment.
3. If `s2i_build_include_base` is true, targets are not only `all`/`base`, and
   `s2i_build_base_image` is empty → runs an extra `./build.sh <action> base`
   **before** the requested targets.
4. If `s2i_build_base_image` is set → passes `BASE_IMAGE` through and does
   **not** run the extra base build.
5. If `s2i_build_push` is true → runs `./build.sh push <targets…>` after a
   successful build.
6. Does **not** stage Zuul checkouts into `src/` (see `playbooks/pre.yaml`).
7. Does **not** start registries, call `zuul_return`, or map openstackversion
   keys — those belong in higher-level provider jobs.

See also: [ANVIL-205](https://redhat.atlassian.net/browse/ANVIL-205),
[ANVIL-204](https://redhat.atlassian.net/browse/ANVIL-204), and
RFC 0001 ([PR #9](https://github.com/openstack-k8s-operators/s2i-openstack-containers/pull/9)).

Zuul wiring lives in `zuul.d/` (adoption-style jobs + `github-check` layout);
details in `playbooks/README.md`.

## Parameters

| Variable | Default | Description |
| --- | --- | --- |
| `s2i_build_repo_dir` | _(required)_ | Path to this repository |
| `s2i_build_stream` | `master` | `STREAM` for `build.sh` |
| `s2i_build_targets` | `['all']` | List (or string) of targets: `all`, `<project>`, or `<project>/<image>` |
| `s2i_build_registry` | `localhost` | Container registry |
| `s2i_build_namespace` | `openstack` | Registry namespace |
| `s2i_build_tag` | `<stream>-latest` | Image tag(s), comma-separated |
| `s2i_build_image_prefix` | `openstack` | Image name prefix |
| `s2i_build_base_image` | `""` | Optional `BASE_IMAGE` override |
| `s2i_build_push` | `false` | Push after a successful build |
| `s2i_build_include_base` | `true` | Build `base` before project targets when no `BASE_IMAGE` |
| `s2i_build_action` | `build` | `build` or `build-parallel` |

## Local check (mock build.sh)

```bash
# requires ansible-playbook on PATH
./tests/test_s2i_build_role.sh
```
