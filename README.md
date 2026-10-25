# Lean + Mathlib prebuilt bundle

Publishes a prebuilt [Lean 4](https://github.com/leanprover/lean4) toolchain together
with a matching [Mathlib](https://github.com/leanprover-community/mathlib4) olean set
as GitHub Actions artifacts.

## Why this exists

An agent working through the ChatGPT GitHub connector has no general internet access
in its workspace. It cannot run `elan`, `lake exe cache get`, or clone anything — but
it *can* download GitHub Actions artifacts. A working Lean environment is roughly
2.8 GB of toolchain plus a Mathlib olean set, which is far past what that connector
will fetch in one piece.

This repository is public **on purpose**: Actions minutes and artifact storage are
free for public repositories, and everything published here is upstream Apache-2.0
software. No private material is involved. The only inputs are `lean-toolchain` and
`lake-manifest.json`, which contain nothing but upstream revision pins.

## Version pinning is not optional

Oleans are loadable only by the exact toolchain and package revisions that produced
them. This bundle is built from:

| | |
| --- | --- |
| toolchain | `leanprover/lean4:v4.32.1` |
| mathlib | `520045ab14e26149ee970e2e617ca04b09bde5d6` |

`lake-manifest.json` is copied verbatim from the consuming project, so every
transitive package resolves to the same revision. **A bundle built from "latest"
Mathlib is useless to a project pinned to an older revision.** When the consuming
project bumps its pins, update `lean-toolchain` and `lake-manifest.json` here and
re-run the workflow.

## Using it

1. Run the **Build Lean + Mathlib bundle** workflow (or take the newest scheduled run).
2. Download `bundle-manifest` first — it lists the part count, byte sizes and SHA-256
   of every part and of the whole.
3. Take **either** delivery shape — the bytes are identical:

   - **`bundle-full`** — one artifact holding the whole `bundle.tar.zst` (~3 GB)
     plus `MANIFEST.txt`. Simplest, if your client can manage a download that size.
   - **`bundle-part-0` … `bundle-part-N`** — ~200 MB each, for a client that cannot.

4. Then extract.

   From `bundle-full`, no reassembly is needed:

   ```sh
   sha256sum -c <(awk -F': ' '/^bundle_sha256/{print $2"  bundle.tar.zst"}' MANIFEST.txt)
   mkdir -p ~/lean-bundle && zstd -d -c bundle.tar.zst | tar -x -C ~/lean-bundle
   ```

   From the parts, put every `bundle.tar.zst.partNN` in one directory alongside
   `MANIFEST.txt` and run the helper, which verifies each part and the whole:

   ```sh
   bash reassemble.sh ~/lean-bundle
   ```

   Either way:

   ```sh
   export PATH="$HOME/lean-bundle/.elan/bin:$PATH"
   lean --version
   ```

The extracted `.lake` directory holds the prebuilt Mathlib packages; point your Lean
project at it (copy or symlink) so `lake` resolves without a network fetch.

Artifacts expire after 90 days. The workflow reruns monthly to keep a fresh set.

## Verification

The build fails unless Mathlib actually imports and elaborates:

```lean
import Mathlib
example : 2 + 2 = 4 := by norm_num
```

so a published bundle is known to work, not merely known to have been packed.

## Licensing and attribution

This repository contains no upstream source of its own. The artifacts it produces
redistribute unmodified builds of:

- **Lean 4** — Apache License 2.0, © Microsoft Corporation and Lean 4 contributors —
  <https://github.com/leanprover/lean4>
- **Mathlib4** — Apache License 2.0, © Mathlib contributors —
  <https://github.com/leanprover-community/mathlib4>
- their transitive dependencies as pinned in `lake-manifest.json` (Batteries, Aesop,
  Qq, ProofWidgets4, ImportGraph, Plausible, LeanSearchClient, Cli), each Apache-2.0

Apache-2.0 permits redistribution provided the license and notices are retained;
they are included inside the packaged toolchain and package directories. Nothing here
is modified, and no warranty is offered by this repository.
