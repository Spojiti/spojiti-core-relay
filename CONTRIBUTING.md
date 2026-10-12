# Contributing

This repository is **assembled**, not edited: the shared files are copied byte
for byte from the Spojiti product by `tools/core-extract.py`, and the
Core's own files come from the product's `tools/core/`. A change made only
here would be overwritten by the next publish. So:

* **A bug or a question:** open an issue. Say which file and line.
* **A fix:** a pull request is welcome as a way to show the change; it is
  carried into the product, and arrives back here with the next publish.
* **A security problem:** never an issue. See SECURITY.md.

To run it: Elixir and a local PostgreSQL, then `mix deps.get` and `mix test`.
The suite is the claim: every promise in README.md points at a test.
