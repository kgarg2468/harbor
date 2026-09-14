# Insomnia Repository Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish Insomnia as a standalone public repository with its project history preserved, then remove the nested project from Harbor.

**Architecture:** Split the `insomnia/` subtree from Harbor's current `origin/main` so the project's files become repository-root paths while retaining Insomnia-specific commit metadata. Add only standalone-repository necessities and the existing untracked UX mockup in a follow-up commit, verify the exported repository, publish it, and only then remove `insomnia/` from Harbor on an isolated branch.

**Tech Stack:** Git subtree history rewriting, GitHub CLI, Swift Package Manager, Bash/Markdown repository tooling

## Global Constraints

- Preserve the commit messages, authors, dates, and file history reachable from Harbor's current `main` that affect `insomnia/`.
- Accept rewritten commit hashes because `insomnia/` paths become repository-root paths.
- Publish `kgarg2468/Insomnia` as a public GitHub repository with default branch `main`.
- Include `insomnia/docs/mockups/menubar-ux.html` from the stale local Harbor checkout; exclude its unrelated `.DS_Store` and generated `.build/` output.
- Do not rewrite Harbor's existing history.
- Do not remove Insomnia from Harbor until the standalone repository has passed tests and its remote contents and visibility are verified.

---

### Task 1: Produce the standalone history

**Files:**

- Export: `insomnia/**` from Harbor `origin/main`
- Create repository: `/Users/krishgarg/Documents/products/Insomnia`

**Interfaces:**

- Consumes: Harbor's fetched `origin/main` at `45aa65b`
- Produces: A local `main` branch whose root tree is the former `insomnia/` tree

- [x] **Step 1: Split the subtree history**

  Run `git subtree split --prefix=insomnia -b insomnia-export origin/main` from the isolated Harbor worktree.

- [x] **Step 2: Create the standalone local repository**

  Clone only `insomnia-export` into `/Users/krishgarg/Documents/products/Insomnia`, rename the branch to `main`, and remove the temporary Harbor remote.

- [x] **Step 3: Verify the history shape**

  Confirm the standalone root contains `Package.swift`, `Sources/`, `Tests/`, `Resources/`, `scripts/`, and `docs/`; confirm it does not contain `harbor/`, `fleet/`, `t3-reasoning/`, or a nested `insomnia/`; compare exported commit metadata with the source path history.

### Task 2: Make the exported project self-contained

**Files:**

- Modify: `/Users/krishgarg/Documents/products/Insomnia/README.md`
- Modify: `/Users/krishgarg/Documents/products/Insomnia/docs/spec.md`
- Create: `/Users/krishgarg/Documents/products/Insomnia/LICENSE`
- Create: `/Users/krishgarg/Documents/products/Insomnia/docs/mockups/menubar-ux.html`

**Interfaces:**

- Consumes: The history-preserving standalone repository from Task 1 and the untracked local mockup
- Produces: A public-repository-ready Insomnia tree with no Harbor checkout instructions

- [x] **Step 1: Update standalone paths and clone instructions**

  Replace the Harbor clone-and-subdirectory command with `git clone https://github.com/kgarg2468/Insomnia.git && cd Insomnia`, and update the specification's repository tree/path examples so `Package.swift`, `Sources/`, `Tests/`, `Resources/`, `scripts/`, and `docs/` are shown at repository root.

- [x] **Step 2: Add inherited licensing and the UX mockup**

  Add Harbor's MIT license to the new repository and add only `docs/mockups/menubar-ux.html` from the stale checkout.

- [x] **Step 3: Commit the standalone adjustments**

  Commit the path corrections, license, and mockup as `chore: make Insomnia a standalone repository`.

- [x] **Step 4: Verify the standalone project**

  Run `swift test`, ensure `git status` is clean, scan tracked paths for generated `.build` output and Harbor-relative references, and inspect the root tree and commit history.

### Task 3: Publish and verify the public repository

**Files:**

- Remote repository: `https://github.com/kgarg2468/Insomnia`

**Interfaces:**

- Consumes: The clean, tested local standalone `main`
- Produces: A public GitHub repository whose default branch matches the verified local commit

- [x] **Step 1: Create and push the GitHub repository**

  Run `gh repo create kgarg2468/Insomnia --public --source=. --remote=origin --push` from the standalone checkout.

- [x] **Step 2: Verify publication**

  Query GitHub for visibility, default branch, and remote head; verify the remote tree, history, and latest commit match the local repository.

### Task 4: Remove Insomnia from Harbor

**Files:**

- Delete: `insomnia/**`
- Modify: `.github/workflows/lint.yml`
- Create: `docs/superpowers/plans/2026-09-13-extract-insomnia.md`

**Interfaces:**

- Consumes: Successful Task 3 publication evidence
- Produces: A Harbor branch containing only Harbor-owned project content and no nested Insomnia project

- [x] **Step 1: Delete the tracked Insomnia subtree**

  Remove `insomnia/` from the isolated Harbor branch after confirming the public remote is complete.

- [x] **Step 2: Remove the obsolete CI exception**

  Delete the Insomnia-specific exclusion/comment from `.github/workflows/lint.yml` while preserving Harbor's lint behavior.

- [x] **Step 3: Verify Harbor has no live Insomnia dependency**

  Search tracked Harbor files for `insomnia` references, inspect submodule and workflow configuration, run the affected lint checks and Harbor unit suite, and confirm only historical extraction documentation mentions the old project.

- [x] **Step 4: Commit the Harbor cleanup**

  Commit the removal and migration plan as `chore: extract Insomnia into its own repository`.

### Task 5: Publish the Harbor cleanup

**Files:**

- Harbor branch: `chore/extract-insomnia`
- Harbor pull request: created against `main`

**Interfaces:**

- Consumes: The verified Harbor cleanup commit
- Produces: A reviewable, CI-backed Harbor change removing the nested project

- [ ] **Step 1: Push the Harbor branch and open a pull request**

  Push `chore/extract-insomnia`, open a PR explaining the history-preserving split and standalone repository verification, and link the PR to this T3 thread.

- [ ] **Step 2: Verify CI and merge readiness**

  Confirm required checks pass and report the public Insomnia URL, Harbor PR URL, exact history counts, test results, and any remaining migration limitations.
