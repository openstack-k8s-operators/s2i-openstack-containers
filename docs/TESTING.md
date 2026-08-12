# Testing

Run the stdlib unittest suite through any supported alias:

```console
tox -e unit
tox -e test
tox -e py3
```

The suite exercises source update and lock-generation behavior with local
temporary Git repositories.

Run repository lint checks with:

```console
tox -e linters
```

The linter environment checks tracked Containerfiles and shell content through
pre-commit. Use the narrowest applicable command first, then run both
environments before proposing changes to build or source-maintenance behavior.

Regenerate dependency locks from committed source pins with Python 3.12:

```console
uvx --python 3.12 tox -e update-lockfiles
```

The environment rejects other Python minor versions because environment
markers can resolve a different package set. A clean regeneration must leave no
tracked diff under `containers/`. Inspect the corresponding
`.tmp/source-maintenance/frozen-source-refs.<stream>.tsv` manifest to confirm
that pinned regeneration used `committed-pin` authority throughout.

Additional change-specific validation is described in the
[developer guide](developer-guide.md#ci-path-filtering).
