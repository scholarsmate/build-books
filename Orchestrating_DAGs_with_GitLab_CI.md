# Build Book: Orchestrating DAGs with GitLab CI

> A practical guide to (ab)using GitLab CI as a deterministic, auditable workflow engine.

---

## Table of Contents

0. [Preface & Philosophy](#0-preface--philosophy)
1. [Objectives & Design Goals](#1-objectives--design-goals)
2. [Who This Is For / Who This Is Not For](#2-who-this-is-for--who-this-is-not-for)
3. [Core Concepts](#3-core-concepts)
4. [Architecture Overview](#4-architecture-overview)
5. [The Bus Pattern: Artifact Ownership & Policy](#5-the-bus-pattern-artifact-ownership--policy)
6. [Service Overlays: Decoupling Without Forking](#6-service-overlays-decoupling-without-forking)
7. [The Orchestrator Pipeline](#7-the-orchestrator-pipeline)
8. [Triggering Pipelines & Minimal UI](#8-triggering-pipelines--minimal-ui)
9. [Data Sharing, Collection, and Bundling](#9-data-sharing-collection-and-bundling)
10. [Security & Trust Model](#10-security--trust-model)
11. [Variations & Extensions](#11-variations--extensions)
12. [Tradeoffs & Limitations](#12-tradeoffs--limitations)
13. [Reference Implementation Walkthrough (End-to-End Example)](#13-reference-implementation-walkthrough-end-to-end-example)
14. [Appendix](#14-appendix)
15. [License](#15-license)

---

## 0. Preface & Philosophy

This document exists because many teams eventually discover the same pattern:

> Much of the infrastructure required for orchestrating complex workflows already exists in CI systems.

GitLab CI is commonly positioned as a build-and-test platform.

This Build Book approaches it differently: as a **deterministic, auditable workflow engine** that can be applied deliberately, using tools organizations already operate and trust.

The philosophy is intentionally opinionated:

* Prefer platforms you already operate
* Make control flow explicit, reviewable, and versioned
* Treat artifacts as first-class, durable outputs
* Optimize for trust, reproducibility, and containment
* Choose boring technology when it scales governance

One deliberate choice in this build book is to use **both YAML and JSON**, but for different roles:

* **YAML** is for *human-authored control plane* definitions: pipeline structure, DAG shape, and policy knobs. It is designed to be reviewed, commented, and maintained as code.
* **JSON** is for *machine-authored run records* and outputs: `manifest.json`, `service_meta.json`, and service result files. It is strict, ubiquitous for tooling, and well-suited to indexing and ingestion.

This maps cleanly to the architecture: YAML expresses intent; JSON preserves evidence.

This is not an attempt to replace specialized workflow engines.

It is a conscious decision to trade dynamism for clarity, and convenience for control.

Architectures without opinions tend to leak complexity everywhere else.

---

## 1. Objectives & Design Goals

The objective of this architecture is simple:

> Use GitLab CI to orchestrate multi-service DAGs while producing a single, durable, auditable run record.

To achieve that, the design prioritizes the following goals.

### Determinism

* The DAG is defined at pipeline creation time
* Execution order is explicit and reviewable
* Inputs, outputs, and versions are pinned

Every run should be explainable after the fact.

### Isolation

* Each service executes in its own project
* Runners, images, secrets, and permissions are scoped
* Failure is contained by default

No service implicitly trusts another.

### Artifact-Centric Design

* Artifacts are the primary output of every stage
* Intermediate results are preserved
* Final bundles are portable and self-describing

The run record should survive the CI system that produced it.

### Minimal Platform Dependencies

* No external workflow engine is required
* No control-plane database is introduced
* GitLab remains the single system of record

If GitLab is already trusted, this architecture inherits that trust.

### Composability Over Reinvention

* Existing tools are wrapped, not rewritten
* Services evolve independently
* The Orchestrator remains stable as the system grows

The goal is to orchestrate tools, not absorb them.

---

### Prerequisites (GitLab Features & Settings)

This build book assumes you have access to the following GitLab capabilities:

* **Multi-project pipeline triggers** (`trigger: project` + `strategy: depend`)
* **Job artifacts** (for service outputs)
* **Generic Package Registry** (for the bus)
* **CI job token scoping / allowlisting** (so only the orchestrator can write to the bus)

Recommended project-level setup checklist:

* **Bus project**
  * Enable the Package Registry.
  * Configure retention / cleanup policy for packages.
  * Allowlist the orchestrator project for `CI_JOB_TOKEN` access.
  * Do not allowlist service projects.
* **Service projects**
  * Allowlist the orchestrator project for read access (artifact download).
  * Export `out/*` as job artifacts (consider `when: always` for debugging).
* **Orchestrator project**
  * Store only the minimum variables needed to target the bus and select service refs.
  * Ensure the runner image contains the tooling required for marshaling (e.g., `curl`, `jq`, `7z`, `unzip`).

UI navigation note (GitLab versions vary):

* **Project Settings -> CI/CD** is typically where you'll find:
  * **Job token allowlisting / Token Access / CI_JOB_TOKEN scope** (inbound/outbound)
  * **Pipeline triggers** and related permissions
* **Project Settings -> Packages & Registries** is typically where you'll enable/configure:
  * **Package Registry** and retention policies

If you can't find the exact label in your instance, search the project settings page for "job token", "token access", "allowlist", or "package registry".

If any of these features are unavailable or restricted in your GitLab environment, this architecture may still work, but the trust model and "bus" mechanics will need adjustments.

---

### What problem we are solving

We want to:

* Orchestrate a **directed acyclic graph (DAG)** of work
* Execute each node in that DAG using:

  * different repositories
  * different runners
  * different containers
  * different trust levels
* Preserve **strict control over artifacts** produced by each step
* End every run with a **single, complete, auditable bundle** of outputs

And we want to do all of that:

* Without introducing a new control plane
* Without centralizing execution into a single mega-pipeline
* Without giving every service write access to shared storage

---

### Core design goals

This architecture is guided by a small number of non-negotiable goals.

#### 1. GitLab is the only platform dependency

If GitLab goes away, this architecture goes away. That is intentional.

There is:

* No external workflow engine
* No custom backend service
* No scheduler daemon

Everything is expressed in:

* `.gitlab-ci.yml`
* Pipelines
* Artifacts
* Triggers
* The GitLab API

This keeps the system:

* Portable
* Auditable
* Familiar to anyone who already understands GitLab CI

---

#### 2. Pipelines are immutable run records

Each pipeline represents a **single, immutable execution**.

* Inputs are explicit
* Outputs are captured
* Failures are visible
* Success is reproducible

There is no concept of "updating" a run. You re-run, or you don't.

This aligns naturally with GitLab's execution model and avoids hidden state.

---

#### 3. Single-writer artifact ownership

Shared storage is a liability.

To control that risk, this architecture enforces a **single-writer rule**:

* Individual services **never** write to shared storage
* Only the orchestrator is allowed to publish final artifacts

This eliminates:

* Cross-service trust assumptions
* Accidental overwrites
* Permission sprawl

And it enables:

* Clear ownership
* Strong audit boundaries
* Clean separation of concerns

---

#### 4. Services are isolated by default

Each service in the DAG:

* Lives in its own repository
* Uses its own CI configuration
* Can have its own runners, images, secrets, and permissions

Services communicate **only via artifacts**, not shared state.

This makes the system easier to reason about and safer to evolve.

---

#### 5. Explicit over clever

This architecture favors:

* Explicit variables
* Explicit triggers
* Explicit artifact collection

Over:

* Dynamic pipeline mutation
* Implicit discovery
* Hidden control flow

The result is more YAML--but YAML that is explicit and easily understood.

---

### What this pattern is good at

This pattern works especially well for:

* Build -> analyze -> validate workflows
* Security and compliance pipelines
* File and artifact processing chains
* Multi-language or multi-tool pipelines
* Environments where **auditability matters more than raw throughput**

---

### What this pattern is *not* trying to be

This is **not**:

* Kubernetes
* Airflow
* Argo
* Temporal
* A general event-driven workflow engine

If you need:

* Millisecond scheduling
* Dynamic DAG generation
* Long-running stateful workflows

This is probably not the right tool.

If you need:

* Deterministic execution
* Strong isolation
* Artifact provenance
* A system you already trust

You're in the right place.

---

## 2. Who This Is For / Who This Is Not For

### This Is For You If

* You already use GitLab CI and want *more* from it
* You need reproducible, reviewable multi-step workflows
* You care about artifact lineage, auditability, and trust boundaries
* You prefer boring infrastructure that already exists
* You want to orchestrate tools, not rewrite them

Typical readers:

* Senior engineers
* Security engineers
* Build/release engineers
* Platform and infrastructure teams

If you've ever thought:

> "Why do we need another workflow engine when CI already does 80% of this?"

You are the target audience.

---

### This Is Probably *Not* For You If

* You need dynamic, data-driven DAGs at runtime
* You require sub-second or event-stream latency
* You want a drag-and-drop workflow designer
* You are allergic to YAML on principle
* You want a centralized monolith that runs everything

This pattern optimizes for **determinism and control**, not magic.

---

## 3. Core Concepts

This architecture relies on a small set of intentionally constrained concepts.

Each concept has a single responsibility.

The power of the system comes from how these concepts compose, not from their individual complexity.

---

### 3.1 Directed Acyclic Graph (DAG)

A DAG defines execution order.

* Nodes represent jobs or pipelines
* Edges represent dependencies
* Cycles are not permitted

In this architecture, the DAG is defined entirely by the Orchestrator pipeline.

It is static, reviewable, and version-controlled.

---

### 3.2 Orchestrator

The **orchestrator** is the pipeline that knows *why* a run exists and *what* the final outcome should look like.

Responsibilities:

* Defines the DAG (what runs, and in what order)
* Generates a unique **Run ID**
* Triggers service pipelines
* Collects service artifacts
* Applies gate logic
* Publishes the final, canonical artifact bundle

Non-responsibilities:

* It does **not** perform heavy work
* It does **not** execute service logic
* It does **not** share its privileges with services

Think of the orchestrator as a **marshal**, not a worker.

---

### 3.3 Service Overlay

A **service overlay** is a thin, purpose-built repository that adapts an existing tool or service into the orchestration system.

Key properties:

* Own GitLab project
* Own CI configuration
* Own runners, images, secrets, and permissions
* Contains a *pinned* upstream repository (usually as a submodule)

The overlay exists so we can:

* Execute known-good versions of tools
* Add orchestration glue without modifying upstream code
* Control upgrades explicitly (via branch or ref selection)

The overlay is not a fork, it is a wrapper.

---

### 3.4 Upstream (Pinned Dependency)

An **upstream** is the actual tool or code being run: a builder, analyzer, scanner, or sandbox.

In this model:

* Upstreams are treated as dependencies
* They are pinned to specific commits or tags
* They are *not* trusted to interact with shared storage

Pinning is not optional. Reproducibility is a non-negotiable objective.

---

### 3.5 Run ID

A **Run ID** uniquely identifies a single execution of the orchestration DAG.

Properties:

* Generated once, at kickoff
* Immutable
* Propagated to every service
* Used as the version key in the artifact bus

Practically, this is usually a UUID.

Conceptually, it is the primary key for everything that follows.

---

### 3.6 Artifacts (and Why They Matter)

Artifacts are the **only** way data moves between services.

Rules:

* Services emit artifacts
* Orchestrator consumes artifacts
* Services never consume each other directly

Artifacts are:

* Versioned
* Auditable
* Bound to a pipeline execution

This eliminates hidden coupling and makes data flow explicit.

---

### 3.7 The Single-Writer Rule

The **single-writer rule** is the most important constraint in the system.

> Only the orchestrator may write to shared storage.

Consequences:

* Services do not need trust in each other
* Storage permissions are simple
* Audit trails are clean

Violating this rule makes everything harder. Don't.

---

### 3.8 The Bus

A **bus** is a GitLab project whose sole purpose is to **own artifacts**.

Characteristics:

* Uses the Generic Package Registry
* Enforces retention and access policy
* Has exactly one writer (the orchestrator)

Buses are organizational boundaries:

* Different teams can own different buses
* Different policies can coexist
* The same orchestrator can target many buses

Think of the bus as the system of record.

---

### 3.9 Marshaling

**Marshaling** is the act of:

* Downloading service job artifacts
* Reassembling them into a canonical structure
* Publishing that structure to the bus

Only the orchestrator performs marshaling.

This is where ephemeral CI output becomes a durable run record.

---

### 3.10 Control Plane vs Data Plane

This architecture separates intent from execution.

* **Control plane:** orchestrator pipeline, DAG, gates
* **Data plane:** service pipelines and their artifacts

GitLab CI provides both, if you're disciplined.

---

### 3.11 A Note on Restraint

If you find yourself wanting:

* Dynamic DAG mutation
* Runtime discovery of services
* Implicit artifact wiring

Pause.

Those are features of workflow engines.

This build book is about disciplined use of GitLab CI--not turning it into something it isn't.

---

## 4. Architecture Overview

This section ties the concepts together with concrete visuals.

The goal is not to overwhelm you with arrows, but to make three things unmistakably clear:

1. **Who controls what**
2. **How data actually flows**
3. **Where trust boundaries live**

If you understand this section, the rest of the build book is implementation.

---

### 4.1 High-Level Block Diagram

At the highest level, the system is composed of four kinds of things:

* A user (or UI)
* An orchestrator pipeline
* A set of service overlay pipelines
* One or more buses (artifact owners)

```text
                    +----------------------------------------------+
                    |                 GitLab Instance              |
                    |                                              |
                    |  +----------------------------------------+  |
User / UI --------->|  |            Orchestrator Project        |  |
(run + variables)   |  |  (DAG, bundle, gates, publish)         |  |
                    |  +---------------+------------------------+  |
                    |                  |                           |
                    |      triggers child pipelines                |
                    |                  |                           |
                    |  +---------------v------------------------+  |
                    |  |        Service Overlay Projects        |  |
                    |  |                                        |  |
                    |  |  - builder                             |  |
                    |  |  - metrics                             |  |
                    |  |  - sandbox                             |  |
                    |  |                                        |  |
                    |  |  (each isolated, emits job artifacts)  |  |
                    |  +---------------+------------------------+  |
                    |                  |                           |
                    |     orchestrator downloads artifacts         |
                    |                  |                           |
                    |  +---------------v------------------------+  |
                    |  |                Buses                   |  |
                    |  |   (artifact ownership & policy)        |  |
                    |  |                                        |  |
                    |  |  - bus-dev                             |  |
                    |  |  - bus-prod                            |  |
                    |  +----------------------------------------+  |
                    +----------------------------------------------+
```

Key observations:

* The orchestrator is the **only component that talks to everyone**
* Services never talk to each other
* Services never write to the bus
* Buses never execute code

This is intentional. Every arrow you *don't* see is a risk you didn't take.

---

### 4.2 Execution Swim-Lane Diagram

The block diagram shows *structure*. The swim-lane shows *time*.

This is what actually happens during a single run.

```text
USER / UI
   |
   |  Run pipeline (variables)
   v

ORCHESTRATOR PIPELINE (P0)
   |
   | [kickoff] generate RUN_ID, bus selection
   |
   | [trigger] builder (strategy: depend)
   |--------------> BUILDER PIPELINE (P1)
   |                - run pinned upstream
   |                - emit out/* as job artifacts
   |<-------------- artifacts available
   |
   | [trigger] metrics (strategy: depend)
   |--------------> METRICS PIPELINE (P2)
   |                - analyze exe
   |                - emit out/* as job artifacts
   |<-------------- artifacts available
   |
   | [trigger] sandbox (strategy: depend)
   |--------------> SANDBOX PIPELINE (P3)
   |                - execute in container
   |                - emit out/* as job artifacts
   |<-------------- artifacts available
   |
   | [collect] download all service artifacts
   | [bundle] assemble run record
   | [gate] apply policy checks
   | [publish] write to bus (success or quarantine)
   v

BUS (artifact owner)
  - final/run-<id>.7z
```

Important details:

* `strategy: depend` makes failures explicit and visible
* Each service pipeline is a **first-class GitLab pipeline**, not a hidden job
* The orchestrator never proceeds blindly; it waits for results

---

### 4.3 Control Plane vs Data Plane

This architecture deliberately separates *intent* from *execution*.

| Plane         | Lives In              | Responsibility                     |
| ------------- | --------------------- | ---------------------------------- |
| Control plane | Orchestrator pipeline | DAG definition, gating, publishing |
| Data plane    | Service pipelines     | Actual computation and analysis    |

GitLab CI provides both planes. Most pipelines just blur them together.

We do not.

---

### 4.4 Trust Boundaries

Trust boundaries are where systems usually fail. Here they are explicit.

* **Between orchestrator and services**

  * Communication: triggers + artifacts
  * No shared credentials

* **Between services**

  * No communication at all

* **Between orchestrator and bus**

  * Narrow, allow-listed CI_JOB_TOKEN permissions

* **Between runs**

  * No shared mutable state

Each boundary is enforced by GitLab itself, not convention.

---

### 4.5 Why This Works

This architecture works because it leans into GitLab's strengths:

* Pipelines are cheap
* Artifacts are first-class
* Permissions are explicit
* Failures are visible

And it avoids fighting GitLab where it is weak:

* No dynamic DAG mutation
* No cross-job shared state
* No magic discovery

The result is not flashy, but it is reliable, auditable, and powerful.

---

## 5. The Bus Pattern: Artifact Ownership & Policy

If there is a single idea in this build book that feels *new*, this is probably it.

The **bus** turns artifact storage from an implementation detail into a **first-class architectural boundary**.

---

### 5.1 What Is a Bus?

A **bus** is a GitLab project whose sole responsibility is to **own artifacts** produced by orchestration runs.

It:

* Does not build code
* Does not run services
* Does not define a DAG

It exists purely to:

* Store artifacts
* Enforce access control
* Enforce retention policy
* Act as the system of record

In practice, a bus is implemented using GitLab's **Generic Package Registry**.

---

### 5.2 Why Not Just Use Job Artifacts?

Job artifacts are ephemeral by design.

They are:

* Scoped to a pipeline
* Subject to CI cleanup
* Owned by the job that produced them

That is exactly what we want *during execution* -- and exactly what we do **not** want once a run is complete.

The bus solves this by providing:

* Durable storage
* Stable URLs
* Explicit ownership

Think of job artifacts as scratch space, and the bus as cold storage.

---

### 5.3 Single-Writer, Many-Readers

Every bus enforces a simple rule:

> The orchestrator is the **only writer**.

Consequences:

* Services never need credentials to shared storage
* A compromised service cannot poison the run record
* Audit trails are clean and centralized

Readers can be:

* Humans
* Downstream pipelines
* External systems

But writers are intentionally boring.

---

### 5.4 Bus Layout (Canonical Run Structure)

Each orchestration run is published to the bus as a versioned package.

Example layout:

```text
<bus-project>
  package: owo-runs
    version: <RUN_ID>
      final/
        run-<RUN_ID>.7z
```

This structure is:

* Predictable
* Scriptable
* Auditable

The bundle contains the full canonical run directory tree (including `manifest.json` and `out/<svc>/*`).

---

### 5.5 The Manifest as the Run Contract

Every run produces a `manifest.json`.

The manifest:

* Identifies the run
* Identifies the orchestrator pipeline
* Records which services ran
* Records upstream SHAs and pipeline URLs

It answers the question:

> "What exactly happened, and why should I trust it?"

If you only keep one file forever, keep the manifest.

---

### 5.6 Multiple Buses, One Orchestrator

Buses scale organizationally.

It is normal -- encouraged, even -- to have:

* `bus-dev`
* `bus-prod`
* `bus-external`
* `bus-customer-X`

Each bus can have:

* Different owners
* Different ACLs
* Different retention policies

The orchestrator does not care.

It targets a bus via variables.

---

### 5.7 Buses as Trust Boundaries

The bus is where trust is *asserted*.

By the time artifacts land on the bus:

* All services have completed
* All gates have passed
* The run is immutable

Downstream consumers never need to trust:

* Individual services
* Individual runners
* Ephemeral CI state

They trust the bus.

---

### 5.8 Why This Is Worth the Trouble

Creating a bus feels like overhead -- until it isn't.

The bus gives you:

* Clear ownership
* Clean separation of concerns
* Multi-tenant orchestration
* Auditable history

Most importantly, it lets different organizations share an orchestrator **without sharing risk**.

That is the real unlock.

---

## 6. Service Overlays: Decoupling Without Forking

Service overlays are the mechanism that lets this architecture scale *without* turning every upstream project into a hostage.

They are subtle, but critical.

---

### 6.1 The Problem With Touching Upstream CI

At first glance, it is tempting to say:

> "Why not just add an include to the upstream project's `.gitlab-ci.yml`?"

That approach fails for several reasons:

* You now depend on upstream CI semantics
* Upstream changes can silently break orchestration
* You force orchestration concerns onto teams who don't want them
* You lose the ability to pin behavior cleanly

Most importantly, you lose **control**.

Service overlays exist specifically to avoid this trap.

---

### 6.2 What a Service Overlay Is

A **service overlay** is a dedicated GitLab project that adapts an existing tool or service into the orchestration system.

It contains:

* A thin orchestration-aware CI pipeline
* A small amount of glue code
* A pinned copy of the upstream project

It does *not* contain:

* Business logic
* Novel algorithms
* Forked upstream history

The overlay's job is translation, not innovation.

---

### 6.3 Pinned Upstreams (Positive Control)

Each overlay includes its upstream as a **pinned dependency**, typically via a submodule:

```text
owo-services/metrics-basic/
  .gitlab-ci.yml
  owo/
    run.sh
  vendor/
    metrics-tool/   (submodule @ exact commit)
```

Pinning gives you:

* Reproducibility
* Explicit upgrade points
* Clear provenance

Nothing runs "latest by accident."

---

### 6.4 prod vs dev Refs

Overlays typically expose at least two long-lived refs:

* `prod` - pinned to known-good upstream commits
* `dev` - used to evaluate upgrades or changes

The orchestrator selects which ref to use **per run**.

This enables:

* Safe experimentation
* Side-by-side comparisons
* Gradual promotion of new versions

Upgrades become a choice, not an event.

---

### 6.5 The Service ABI (`out/*` Contract)

Every service overlay exposes a **stable artifact interface**.

The rule is simple:

> If it matters, it must appear in `out/`.

Common contents:

* `service_meta.json`
* One or more service-specific outputs

Example:

```text
out/
  service_meta.json
  metrics.json
```

The orchestrator does not care *how* the service works -- only that the contract is honored.

---

### 6.6 service_meta.json (Non-Negotiable)

Every service emits a `service_meta.json` file.

At minimum, it should contain:

* Service name
* Overlay repo URL
* Overlay ref
* Upstream repo URL
* Upstream commit SHA
* Service pipeline URL

This file is what makes the final run auditable.

---

### 6.7 Isolation by Default

Each service overlay:

* Can use different runners
* Can use different base images
* Can have different secrets
* Can enforce different resource limits

Nothing is shared unless you *intentionally* make it so.

Isolation is not overhead -- it is insurance.

---

### 6.8 What Overlays Buy You

Service overlays give you:

* Freedom from upstream CI churn
* Reproducible execution
* Explicit upgrade control
* Clean ownership boundaries
* A stable contract for orchestration

They are boring.

That's why they work.

---

## 7. The Orchestrator Pipeline

The orchestrator is the only pipeline that understands the full story:

* *What is this run?*
* *What services must execute?*
* *What is an acceptable outcome?*
* *Where is the durable record stored?*

It is both the **control plane** and the **final publisher**.

The orchestrator should do very little computation.

Its superpower is coordination.

---

### 7.1 Stages (Recommended Baseline)

A practical orchestrator pipeline can be expressed with a small set of stages:

1. `kickoff` - generate Run ID, validate inputs
2. `trigger` - trigger service overlay pipelines
3. `collect` - download, validate and re-home service job artifacts
4. `bundle` - create final bundle + manifest
5. `gate` - evaluate results, apply policy
6. `publish` - write canonical run record to the bus

**Critical Note:** We `bundle` *before* `gate`. This ensures that a complete, inspectable run record exists for the Quarantine bucket if the gates fail.

You can add more stages later.

For reference implementation, keep it boring.

---

### 7.2 Kickoff: Generate the Run

The kickoff job is responsible for creating a consistent run context.

It should:

* Generate `RUN_ID`
* Select the bus (dev/prod)
* Validate required variables
* Emit a dotenv file so downstream jobs get consistent values

Example behavior (conceptual):

```text
RUN_ID=<uuid>
OWO_BUS_PROJECT_ID=<id>
OWO_BUS_PACKAGE=owo-runs
```

This is also a good time to stamp:

* the orchestrator pipeline URL
* optional human-friendly labels (e.g., "release-candidate-1")

---

### 7.3 Trigger Services: The DAG Edges

The orchestrator expresses the DAG by triggering service overlay pipelines.

The important choice here is:

* Use `strategy: depend`

This forces GitLab to treat downstream pipelines as part of the run.

Consequences:

* The orchestrator waits
* Failures propagate
* The run is honest

Each trigger passes variables such as:

* `RUN_ID`
* bus coordinates
* input coordinates (where to fetch the input executable)
* service ref selection (prod/dev)

Services should be able to run with no knowledge of the rest of the DAG.

---

### 7.4 Collect: Marshaling Service Outputs

Once services complete, the orchestrator collects their outputs.

Mechanically, this usually means:

* Downloading each service's job artifacts via the GitLab API
* Validating the service outputs
* Assembling a canonical directory tree in the orchestrator workspace

Conceptually, the orchestrator turns many ephemeral outputs into one durable record.

In practice, the collect stage typically consists of one gatherer job per service overlay, allowing artifact normalization to fan out in parallel.

A typical canonical tree in the orchestrator workspace:

```text
out/
  in/
    # External inputs go here (if any)
  builder/...
  metrics/...
  sandbox/...
```

Note: In the reference implementation, the `builder` service *produces* the binary, so `in/` may be empty. If your workflow accepts external files (e.g., user uploads), place them here.

This directory tree becomes the basis for both gating and publishing.

---

### 7.5 Bundle: Produce the Run Package

Bundling is the step that makes the run convenient to:

* Download
* Archive
* Share
* Review

A good bundle includes:

* `manifest.json`
* the canonical run directory tree
* optional `report.md` or `report.html`

Typical output:

```text
manifest.json
final/
  run-<RUN_ID>.7z
```

The orchestrator is the right place to generate the manifest because it has the full context:

* which services ran
* which refs were used
* where outputs were produced

---

### 7.6 Gate: Policy and Acceptance

Gating is where you encode the definition of "good."

Examples:

* Sandbox exit code is zero
* Output contains expected strings
* Metrics thresholds are met
* Virus scanning results are clean

Gates should be:

* Explicit
* Deterministic
* Recorded

If a gate fails, the pipeline should fail.

This is not just a "no." It is a signal to switch tracks.

* **Success:** Proceed to publish the certified run to the primary package (`owo-runs`).
* **Failure:** Divert the diagnostic artifacts to the quarantine package (`owo-runs-failed`).

The gate is the traffic cop.

---

### 7.7 Publish: Write to the Bus

Publishing is where the run becomes permanent.

The orchestrator uploads artifacts to the bus's Generic Package Registry using a narrow permission set. The destination is determined by the `gate` result.

**Success Path (`when: on_success`):**

* **Package:** `owo-runs`
* **Content:** The full, certified run bundle.

**Failure Path (`when: on_failure`):**

* **Package:** `owo-runs-failed`
* **Content:** The run bundle (which contains diagnostics, partial outputs, and the manifest).

Recommended publish order:

1. `final/run-<RUN_ID>.7z`

If publishing fails, the run is incomplete.

Treat it as a hard failure.

---

### 7.8 Minimal Orchestrator Responsibilities (A Useful Constraint)

To keep the orchestrator maintainable, enforce this constraint:

The orchestrator may:

* Trigger
* Collect
* Gate
* Bundle
* Publish

The orchestrator may not:

* Build complex tools
* Perform deep analysis
* Become the place where "real work" happens

If a job starts to look like a service, make it a service.

---

### 7.9 What You Get For Free

Once the orchestrator is working, GitLab gives you a lot of value for free:

* A live DAG view (pipeline graph)
* Status and failure visibility
* Logs and traceability
* Permissions and audit trails

In other words: you get a workflow engine UX without building a workflow engine.

Which is the entire point.

---

## 8. Triggering Pipelines & Minimal UI

At some point, someone has to press the button.

This section covers **how runs are initiated**, how parameters enter the system, and how to do this *without* turning your orchestrator into a security incident.

---

### 8.1 Triggering Is a Control-Plane Concern

Triggering a run is part of the **control plane**, not the data plane.

That means:

* No services should self-trigger orchestration
* No downstream job should invent new runs
* All runs begin at the orchestrator

This keeps:

* Audit trails intact
* Permissions narrow
* Blame assignable (a deeply underrated feature)

---

### 8.2 Manual Pipeline Runs (Baseline)

The simplest and safest trigger mechanism is GitLab's built-in **Run Pipeline** UI.

Advantages:

* No additional tokens
* Native authentication
* Full audit trail (who clicked what, when)
* Easy variable injection

For many teams, this is more than sufficient.

Typical variables supplied at trigger time:

* `OWO_BUS` (e.g., `dev`, `prod`)
* `OWO_BUILDER_REF` (e.g., `prod`, `dev`)
* `OWO_METRICS_REF`
* `OWO_SANDBOX_REF`
* Optional human labels or notes

GitLab handles the rest.

---

### 8.3 Parameter Discipline

A small number of well-defined variables goes a long way.

Good parameters are:

* Explicit
* Validated at kickoff
* Propagated via dotenv

Bad parameters are:

* Inferred implicitly
* Mutated mid-run
* Introduced by services

If a parameter matters, surface it at the orchestrator boundary.

---

### 8.4 Static Helper UI (The "Nice Button")

Sometimes you want something friendlier than the GitLab UI -- but not *dangerous*.

A simple pattern is a **static HTML page** that:

* Presents a form
* Constructs a GitLab pipeline URL
* Redirects the user to GitLab's Run Pipeline page

Important properties:

* No JavaScript tokens
* No direct API calls
* GitLab still performs authentication

This gives you a one-click experience without creating a new attack surface.

---

### 8.5 Trigger Tokens (Optional, Handle With Care)

GitLab supports trigger tokens for programmatic pipeline starts.

They can be useful for:

* Scheduled runs
* External systems
* Automated testing

They are also:

* Powerful
* Easy to misuse

If you use trigger tokens:

* Scope them narrowly
* Rotate them
* Treat them like credentials

For a reference implementation, they are optional.

---

### 8.6 Scheduled Runs

Because orchestration lives entirely in GitLab CI, scheduling is trivial.

You can:

* Schedule nightly runs
* Schedule weekly audits
* Schedule regression sweeps

All without adding infrastructure.

Schedules are just another trigger.

---

### 8.7 What Not To Do

Avoid the temptation to:

* Let services trigger orchestration
* Let downstream pipelines spawn new DAGs
* Hide parameters inside scripts
* Build a bespoke UI too early

If triggering feels complicated, simplify the inputs -- not the machinery.

---

### 8.8 A Useful Litmus Test

If you can answer these questions by looking at the pipeline page:

* Who started this run?
* With what parameters?
* Against which versions?

Then your triggering model is working.

If not, fix that first.

---

## 9. Data Sharing, Collection, and Bundling

This system treats **artifacts as the sole mechanism for inter-service data exchange**.

No service reads another service’s workspace directly.
No implicit shared state is assumed.
No ad-hoc *service-to-service* API calls are required for routine data flow (the GitLab API is used for triggers and artifact retrieval).

Everything that matters is made explicit, versioned, and auditable through artifacts.

### 9.1 The `out/` Artifact Contract

```text
       ┌──────────────────────────────┐
       │        Orchestrator          │
       │      (control plane)         │
       └─────────────┬────────────────┘
               │
               │ needs: artifacts:true
               │
  ┌──────────────────────────────▼──────────────────────────────┐
  │                        Service Overlay                      │
  │                                                             │
  │   - runs pinned upstream                                    │
  │   - performs real work                                      │
  │                                                             │
  │   Produces job artifacts:                                   │
  │                                                             │
  │     out/                                                    │
  │       service_meta.json                                     │
  │       <service outputs>                                     │
  │                                                             │
  └──────────────────────────────┬──────────────────────────────┘
               │
               │ artifacts materialized
               │ (opaque payload)
               │
  ┌──────────────────────────────▼──────────────────────────────┐
  │                         Gatherer Job                        │
  │                      (orchestrator-owned)                   │
  │                                                             │
  │   - one gatherer job per service overlay                    │
  │   - depends on exactly one upstream                         │
  │   - validates artifacts are sane                            │
  │                                                             │
  │   Re-homes artifacts under a namespaced directory:          │
  │                                                             │
  │     out/                                                    │
  │       <gather-dir>/  <─── entire upstream out/*             │
  │                                                             │
  │   (fails if out/<gather-dir> already exists)                │
  │                                                             │
  └──────────────────────────────┬──────────────────────────────┘
                                 │
                                 │ needs: artifacts:true
                                 │
  ┌──────────────────────────────▼──────────────────────────────┐
  │                       Bundling Job                          │
  │                                                             │
  │   - depends on one or more gatherers                        │
  │   - assembles canonical out/ tree                           │
  │                                                             │
  │   Writes:                                                   │
  │     out/manifest.json                                       │
  │                                                             │
  │   Archives:                                                 │
  │     out/**  →  final/run-<RUN_ID>.7z                        │
  │                                                             │
  └──────────────────────────────┬──────────────────────────────┘
                                 │
                                 │ needs: artifacts:true
                                 │
  ┌──────────────────────────────▼──────────────────────────────┐
  │                          Gate Job                           │
  │                                                             │
  │   - evaluates policy                                        │
  │   - inspects bundled artifacts                              │
  │   - decides accept vs reject                                │
  │                                                             │
  │   (no artifact mutation)                                    │
  │                                                             │
  └──────────────────────────────┬──────────────────────────────┘
                                 │
                                 │ needs: artifacts:true
                                 │
  ┌──────────────────────────────▼──────────────────────────────┐
  │                        Publish Job                          │
  │                      (single-writer)                        │
  │                                                             │
  │   - runs only after gate decision                           │
  │   - uploads bundle + manifest                               │
  │   - targets success or quarantine package                   │
  │                                                             │
  └──────────────────────────────┬──────────────────────────────┘
                                 │
                                 │ publish
                                 │
                   ┌─────────────▼────────────────┐
                   │             Bus              │
                   │     (artifact ownership)     │
                   │                              │
                   │   - immutable run record     │
                   │   - manifest + bundle        │
                   │                              │
                   └──────────────────────────────┘

```

Every job that wishes to publish results **must write them under `out/`** and export `out/**` as job artifacts.

This rule applies universally:

* service overlays,
* orchestrator jobs,
* gatherers,
* and final bundling steps.

There are no exceptions and no alternate paths.

If a downstream job needs data, that data must have existed in some upstream job’s `out/` directory.

This single invariant keeps data flow:

* visible,
* debuggable,
* cacheable,
* and reproducible.

### 9.2 Required Service Metadata

Each service overlay **must include** a `out/service_meta.json` file in its artifacts.

This file exists for auditability and traceability and is part of the service ABI. It allows downstream consumers and the orchestrator to answer questions like:

* *Who produced this artifact?*
* *From which repository and revision?*
* *In which pipeline did it run?*

The orchestrator does **not** interpret this metadata beyond basic validation. Its presence is required; its meaning belongs to humans and audit tooling.

### 9.3 Artifact Propagation via `needs`

Within a pipeline graph, jobs receive upstream artifacts explicitly via:

* `needs:`
* with `artifacts: true`

This mechanism is used consistently to propagate `out/**` between jobs.

When a job declares such a dependency:

* upstream artifacts are materialized into the downstream job’s workspace,
* under the same `out/` path they were exported from,
* without renaming or transformation.

At this stage, artifacts are treated as **opaque payloads**.

### 9.4 Gatherer Jobs: Namespacing and Gating

To safely combine artifacts from multiple upstream jobs, the orchestrator introduces **gatherer jobs**.

A gatherer:

* depends on exactly one upstream job,
* receives that job’s `out/**`,
* validates that the artifacts are sane,
* and re-exports them under a **namespaced subdirectory** within its own `out/`.

For example:

* `out/built/**`
* `out/metrics/**`
* `out/source/**`

The specific directory name is chosen by the gatherer and is **not required to match the producing service’s name**. Bundle layout is an orchestration concern; service identity remains encoded in `service_meta.json`.

#### Collision Guard

To prevent accidental overwrites, gatherers **must fail** if their target subdirectory already exists.

This simple guard ensures:

* artifact sets remain disjoint,
* ordering mistakes fail fast,
* and the pipeline never silently merges unrelated outputs.

#### Validation Scope

Gatherers are the natural choke point for validation and gating.

Typical checks include:

* presence and validity of `out/service_meta.json`,
* existence of one or two expected outputs,
* basic format checks (e.g., valid JSON, executable binary).

These checks are intentionally shallow. They exist to catch structural errors, not to re-implement service logic.

### 9.5 Downstream Consumption

Downstream service overlays consume artifacts **exactly as they arrive**.

By convention:

* incoming artifacts appear under `out/`,
* the receiving service may rename or relocate them into service-specific input directories (e.g., `in-source/`, `in-built/`),
* and the service then produces its own outputs under a fresh `out/`.

This keeps responsibility aligned:

* producers publish,
* consumers adapt,
* the orchestrator does not guess.

### 9.6 Final Bundling

The final bundling job depends on one or more gatherers.

At this point:

* all artifact sets already live under disjoint subdirectories of `out/`,
* no further renaming is required.

The bundler:

1. writes a `out/manifest.json` file at the root,
2. archives `out/**` as a single bundle (e.g., `.7z`),
3. publishes the bundle to the bus.

This results in a stable, predictable bundle layout:

```text
out/
  manifest.json
  built/
    ...
  metrics/
    ...
  source/
    ...
```

The manifest serves as the top-level index; the directory structure reflects orchestration intent.

### 9.7 Why This Works

This model deliberately favors:

* explicitness over convenience,
* repetition over cleverness,
* and contracts over convention-by-implication.

By insisting that:

* all data flows through `out/`,
* all sharing is artifact-based,
* and all aggregation is explicit,

the system avoids hidden coupling while remaining easy to reason about under failure, re-runs, partial success, and audit.

If this feels almost boring — good. Boring pipelines are the ones you can trust at 3 a.m.

## 10. Security & Trust Model

Security in this architecture is not an afterthought.

It is the direct result of a small number of deliberate constraints applied consistently.

This section makes those constraints explicit.

---

### 10.1 Threat Model (What We Care About)

This build book assumes a realistic, not paranoid, threat model.

We care about:

* Preventing accidental cross-contamination between services
* Limiting blast radius if a service misbehaves
* Preserving artifact integrity and provenance
* Maintaining a clean audit trail

We are *not* trying to defend against:

* A fully malicious GitLab administrator
* Kernel-level compromise of the runner host

Those problems exist whether or not you use this architecture.

---

### 10.2 Trust Is Not Transitive

A foundational rule:

> Trust does not flow through the DAG.

Just because:

* The orchestrator trusts a service
* The bus trusts the orchestrator

Does *not* mean:

* The bus trusts the service

This is enforced structurally, not socially.

---

### 10.3 CI_JOB_TOKEN Allowlisting

GitLab's `CI_JOB_TOKEN` is the linchpin of secure communication.

In this architecture:

* Only the orchestrator's project is allowlisted to write to the bus
* Services are *not* allowlisted

This means:

* Services cannot publish artifacts
* Services cannot overwrite run records
* Services cannot exfiltrate data via the bus

If a service pipeline is compromised, the damage stops there.

---

### 10.4 Single-Writer Enforcement

The single-writer rule is enforced in two places:

1. **Policy** - only the orchestrator project is allowlisted
2. **Architecture** - services never attempt to publish

Defense in depth matters.

If you ever feel tempted to relax this rule "just once," don't.

---

### 10.5 Runner Isolation

Each service overlay can use:

* Different runners
* Different base images
* Different execution policies

This allows you to:

* Run untrusted code in hardened environments
* Separate build-time and run-time concerns
* Apply resource limits per service

Isolation is cheap compared to incident response.

---

### 10.6 Artifact Integrity

Artifacts are protected by:

* GitLab's pipeline scoping
* Immutable job outputs
* Explicit marshaling by the orchestrator

The manifest ties together:

* What ran
* Where it ran
* Which inputs produced which outputs

This makes silent tampering difficult and obvious.

---

### 10.7 Auditability

Every run leaves behind:

* An orchestrator pipeline
* One pipeline per service
* A manifest.json
* A durable artifact bundle

From this, you can reconstruct:

* Who initiated the run
* What code executed
* What decisions were made
* What artifacts were produced

Auditability is not a feature you add later.

It emerges naturally from the design.

---

### 10.8 Failure Modes and Containment

When something goes wrong:

* A service failure fails its pipeline
* The orchestrator sees the failure
* The run stops
* Partial results are not published as complete

There is no undefined middle state.

This is intentional.

---

### 10.9 The Security Posture in One Sentence

If you trust GitLab CI to run your jobs, this architecture lets you:

> Compose many jobs into a workflow **without multiplying trust**.

That is the entire security story.

---

## 11. Variations & Extensions

One of the strengths of this architecture is that it is **composable**.

You can extend it in multiple directions without changing its core constraints.

This section outlines common variations that preserve the model while adapting it to different organizational needs.

---

### 11.1 Multiple Buses (Organizational Scaling)

Nothing in the orchestrator assumes a single bus.

It is common to operate:

* `bus-dev` for experimentation
* `bus-prod` for authoritative runs
* `bus-audit` for long-term retention
* `bus-customer-<X>` for external delivery

Each bus can:

* Live in a different group
* Have different owners
* Enforce different retention policies

The orchestrator selects the bus via variables.

This allows one orchestration engine to serve many organizations without shared trust.

---

### 11.2 Partial DAGs and Optional Services

Not every run needs every service.

You can:

* Make services conditional
* Skip expensive stages during development
* Add specialized analysis only for certain runs

This is typically implemented using:

* Rules
* Variables
* Separate pipeline definitions

The key rule remains: skipped services do not produce artifacts.

---

### 11.3 Fan-Out and Parallelism

GitLab CI is very good at running pipelines in parallel.

Common patterns include:

* Running multiple analyzers in parallel
* Executing the same service against multiple inputs
* Comparing prod vs dev overlays side-by-side

Parallelism happens at the service level.

The orchestrator waits; it does not micromanage.

---

### 11.4 External Inputs and Pre-Existing Artifacts

Inputs do not have to be built inside the DAG.

You can:

* Pull inputs from a bus
* Accept externally uploaded artifacts
* Reference artifacts by hash or version

As long as inputs are:

* Explicit
* Recorded
* Immutable

The model holds.

---

### 11.5 Scheduled and Continuous Runs

Because everything lives in GitLab CI:

* Nightly regression runs are trivial
* Weekly compliance checks are easy
* Periodic re-analysis of historical inputs is possible

Scheduling is just another trigger.

---

### 11.6 Windows, macOS, and Mixed Environments

While containers are the default, they are not the only option.

Service overlays can target:

* Linux containers
* Windows runners
* macOS runners

The orchestrator does not care.

Heterogeneous execution environments fit naturally into the model.

---

### 11.7 External Consumers

The bus makes it easy to integrate with external systems:

* Artifact mirroring
* Report ingestion
* Long-term archival
* Customer delivery

External consumers never interact with services directly.

They read from the bus.

---

### 11.8 What Should *Not* Change

As you extend the system, resist changing these:

* The single-writer rule
* Service isolation
* Explicit artifacts
* Pinned execution

These constraints are what make the architecture predictable.

Break them only if you fully understand the consequences.

### 11.9 The Quarantine Pattern (Handling Failures)

By default, if a run fails, the orchestrator publishes nothing. Use the **Quarantine Pattern** to save debug data without polluting the main record.

1. **Service Level:** Configure service jobs to upload artifacts `when: always` or `when: on_failure`. This ensures `stdout.txt` or partial binaries are preserved even if the job exits with error.
2. **Orchestrator Level:** Add a `rescue` job marked `when: on_failure`.
3. **Separation:** This job publishes to a *different* package (e.g., `owo-runs-failed`).

Practical note: if you want the orchestrator to still **collect/bundle** and then publish quarantine outputs even when a *service pipeline* fails, make the service `trigger` jobs non-terminal and let the `gate` decide final success.

Example pattern:

```yaml
trigger_builder:
  stage: trigger
  trigger:
    project: owo/builder-hello
    branch: $OWO_BUILDER_REF
    strategy: depend
  allow_failure: true
```

Then, in `gate`, explicitly fail the pipeline if any required service did not succeed.

This keeps the main `owo-runs` package strictly for green, verified builds, while providing a "morgue" for analyzing crashes.

---

## 12. Tradeoffs & Limitations

No architecture is free.

This section is where we are explicit about what this pattern gives you -- and what it very intentionally does not.

Being honest here is what makes the rest of the document credible.

---

### 12.1 YAML Is the Interface

This architecture is built on GitLab CI.

That means:

* The primary interface is YAML
* Control flow is expressed declaratively
* Debugging sometimes involves staring at pipeline graphs

If you are allergic to YAML, this will not cure you.

The tradeoff is that the interface is:

* Versioned
* Auditable
* Already understood by most teams

---

### 12.2 No Dynamic DAG Mutation

The DAG is defined at pipeline creation time.

You cannot:

* Add new nodes mid-run
* Discover services dynamically
* Change execution order on the fly

This is a limitation compared to dedicated workflow engines.

It is also what makes runs predictable and reviewable.

---

### 12.3 Latency Over Throughput

GitLab CI pipelines are not low-latency systems.

Triggering downstream pipelines, waiting for runners, and collecting artifacts all take time.

This architecture optimizes for:

* Correctness
* Isolation
* Auditability

Not for:

* Sub-second execution
* High-frequency event processing

If you need millisecond responsiveness, look elsewhere.

---

### 12.4 Artifact Size and Volume

Artifacts are first-class citizens here.

Large artifacts:

* Take time to upload and download
* Consume storage
* Require retention discipline

The bus pattern helps manage this, but it does not make storage free.

Plan accordingly.

---

### 12.5 UI Is Functional, Not Magical

GitLab's pipeline UI is powerful, but it is not a bespoke workflow dashboard.

You get:

* DAG visualization
* Job logs
* Status propagation

You do not get:

* Custom per-node UIs
* Rich real-time telemetry
* Interactive graph editing

The upside is that you get all of this *without building it*.

---

### 12.6 Operational Discipline Is Required

This architecture rewards discipline.

You must:

* Pin upstreams
* Maintain overlays
* Review CI changes
* Treat the bus as authoritative

If you prefer systems that "just float forward," this will feel constraining.

That constraint is the point.

---

### 12.7 When This Is the Wrong Tool

This pattern is probably not a good fit if:

* You need dynamic, data-driven DAGs
* You require extremely low latency
* You want to centralize all execution into one pipeline
* You cannot tolerate YAML-driven configuration

Knowing when *not* to use a pattern is part of using it well.

---

### 12.8 Why These Tradeoffs Are Acceptable

Every limitation listed above is the result of a deliberate choice.

Those choices buy you:

* Reproducibility
* Strong trust boundaries
* Minimal platform dependencies
* A workflow engine hiding in plain sight

If those matter to you, the tradeoffs are usually worth it.

---

## 13. Reference Implementation Walkthrough (End-to-End Example)

This section walks through the minimal working reference implementation ("owo") end-to-end.

The goal is not to show a perfect production system. The goal is to prove the architecture works:

* One orchestrator pipeline defines the DAG
* Multiple isolated service pipelines execute real work
* The orchestrator marshals outputs
* A bus stores a durable, reviewable run record

We'll keep the example intentionally small:

* **builder-hello**: produces a tiny executable (`exe.bin`) + hash
* **metrics-basic**: computes basic file metrics (e.g., sha256, file type)
* **scanner-virustotal**: submits the binary to VirusTotal and records the analysis
* **sandbox-exec**: runs the executable in a constrained container and records output
* **bus-dev**: durable artifact store for the run

---

### 13.1 Repos in the reference implementation

At minimum, you will have these GitLab projects (names are illustrative):

* `owo/orchestrator` (control plane)
* `owo/bus-dev` and optionally `owo/bus-prod` (artifact ownership)
* `owo/builder-hello` (service overlay)
* `owo/metrics-basic` (service overlay)
* `owo/scanner-virustotal` (service overlay)
* `owo/sandbox-exec` (service overlay)

In the reference implementation you built, each service is a standalone GitLab project with its own CI.

---

### 13.2 Run Inputs and Variables

For the reference implementation, the orchestrator needs only a few inputs.

Minimum set:

* `OWO_BUS_PROJECT_ID` - numeric project ID of the bus
* `OWO_BUS_PACKAGE` - generic package name (e.g., `owo-runs` or `runs`)
* `OWO_BUILDER_REF` / `OWO_METRICS_REF` / `OWO_SANDBOX_REF` - which ref to run for each service (e.g., `prod` or `dev`)
* `OWO_SCANNER_REF` - optional; if set, triggers the VirusTotal scanner overlay at this ref

Service-specific secrets:

* `VT_API_KEY` - VirusTotal API key (scanner overlay)

Optional scanner tuning:

* `VT_TIMEOUT_SECONDS` - total time to wait for VirusTotal analysis completion (default: 300)
* `VT_POLL_INTERVAL_SECONDS` - seconds between analysis polls (default: 10)

Bundling note:

* The reference implementation encrypts the final `.7z` using `RUN_ID` as the password. This is lightweight friction to prevent “auto-open”; it is not a security boundary.

Generated at kickoff:

* `RUN_ID` - UUID used as the package version

A good kickoff job validates that the required variables are present and writes a dotenv file.

---

### 13.3 Orchestrator Pipeline (Conceptual)

The orchestrator expresses the DAG with `trigger` jobs using `strategy: depend`.

A typical stage layout:

* `kickoff`
* `trigger`
* `resolve`
* `collect`
* `bundle`
* `gate`
* `publish`

In your reference implementation, you already have kickoff + service triggers + gate logic. The remaining steps are:

* consistently marshaling artifacts
* bundling them into the final bundle (e.g., a `.7z`)
* publishing the bundle to the success or failure package based on the gate result

---

### 13.4 Service Contract: What Each Service Must Produce

Each service pipeline must emit job artifacts under `out/`.

Minimum:

* `out/service_meta.json`

Service-specific outputs:

* Builder

  * `out/exe.bin`
  * `out/exe.sha256`

* Metrics

  * `out/metrics.json`

* Sandbox

  * `out/sandbox.json`
  * `out/stdout.txt`
  * `out/stderr.txt`

This is what allows the orchestrator to remain dumb and stable.

---

### 13.5 Marshaling: How the Orchestrator Collects Results

After each triggered pipeline completes, the orchestrator downloads the child pipeline's job artifacts and assembles a canonical directory tree.

Recommended canonical tree inside the orchestrator job workspace:

```text
out/
  in/
    # (External inputs, if any. Empty in this example)
  builder/...
  metrics/...
  sandbox/...
```

This is the directory tree you:

* gate against
* archive into the final bundle (e.g., `.7z`)
* publish to the bus

---

### 13.6 Gates (The Reference Implementation Acceptance Criteria)

For the simplest "hello world" executable, the gates can be:

* Sandbox exit code is `0`
* `stdout.txt` contains `hello` (case-insensitive)

Example policy (conceptual):

```sh
test "$(jq -r .exit_code out/sandbox/sandbox.json)" = "0"
grep -qi "hello" out/sandbox/stdout.txt
```

If this fails, the orchestrator pipeline fails.

No partial "success."

---

### 13.7 Publishing to the Bus (Generic Package Registry)

Publishing means uploading files to the bus project's Generic Package Registry.

The package coordinates:

* **project:** `OWO_BUS_PROJECT_ID`
* **package:** `OWO_BUS_PACKAGE`
* **version:** `RUN_ID`

Recommended publish order:

1. `final/run-<RUN_ID>.7z`

This produces a durable, scriptable run record.

---

### 13.8 Where to See and Download Artifacts

There are two "artifact worlds" in GitLab:

1. **Job artifacts** (ephemeral)

   * Found on each job page: Pipeline -> Job -> Artifacts
   * Great for debugging
   * Not ideal for long-term storage

2. **Bus artifacts** (durable)

   * Found in the bus project under: Deploy -> Package Registry -> Generic
   * Organized by package and version (`RUN_ID`)

If you want the one-click "download everything" experience, that is exactly why we publish a:

* `final/run-<RUN_ID>.7z`

This is the portable, shareable bundle.

---

### 13.9 Triggering the Run

For the reference implementation, the simplest approach is:

* Go to `owo/orchestrator`
* CI/CD -> Pipelines -> **Run pipeline**
* Select branch
* Enter variables
* Run

This avoids commits purely to start a run, and preserves a clean audit trail.

---

### 13.10 Debugging the Reference Implementation: The Three Most Common Foot-Guns

These came up naturally during the reference implementation bring-up.

#### 1) Runner can't reach GitLab (clone failures)

Symptom:

* `Could not resolve host` or `Failed to connect`

Fix:

* Ensure runner job containers are on a Docker network that can resolve the GitLab container
* Set `network_mode` for the runner executor to that network
* Optionally set `clone_url` so the runner uses the correct internal URL

#### 2) Token permissions (403 when fetching)

Symptom:

* `curl: (22) 403` or `404 Not Found` when triggering

Fix:

* **Bus Access:** Ensure the bus project allowlists the orchestrator project for `CI_JOB_TOKEN` access.
* **Service Access:** Ensure service projects allow the orchestrator to download artifacts (Job Token Access settings).
* Ensure you are using the correct token type for the endpoint (Job Token vs. Trigger Token).

#### 3) Variables not set (services complaining about missing bus coordinates)

Symptom:

* `BUS_PROJECT_ID=<empty>`

Fix:

* Validate variables in kickoff
* Pass variables explicitly in each trigger
* Use dotenv artifacts to propagate generated values (like `RUN_ID`)

If the pipeline graph shows it was orchestrator-triggered but values are empty, the usual culprit is:

* a missing variable in the trigger block
* or a variable overwritten by job-level `variables:`

---

### 13.11 What "Good" Looks Like

A successful run produces:

* One orchestrator pipeline with a clean graph
* One pipeline per service, each with job artifacts
* A bus package version named by `RUN_ID`
* A `manifest.json`
* A `final/run-<RUN_ID>.7z` that contains the whole run record

At that point, you have demonstrated the core promise of this architecture:

> GitLab CI can orchestrate a multi-service DAG and produce a single durable, auditable bundle -- without an external workflow engine.

---

### 13.12 Copy/Paste Variable Set (Run Pipeline UI)

For the reference implementation, you should be able to kick off a run **without committing anything**.

Use **CI/CD -> Pipelines -> Run pipeline** and paste values like the following:

```text
OWO_BUS_PROJECT_ID=1
OWO_BUS_PACKAGE=runs

OWO_BUILDER_REF=orch-prod
OWO_METRICS_REF=orch-prod
OWO_SANDBOX_REF=orch-prod
```

Notes:

* `OWO_BUS_PROJECT_ID` must be the numeric project ID of the bus project
* `OWO_BUS_PACKAGE` is the Generic Package name (stable across runs)
* Each `*_REF` should point to a pinned, known-good branch or tag

If any required variable is missing, the **kickoff job should fail fast** with a clear error.

---

### 13.13 `manifest.json` Schema (Reference Implementation)

Every successful run should emit a machine-readable manifest.

This file is the **index card** for the run.

Minimal reference implementation schema:

```json
{
  "run_id": "<uuid>",
  "status": "success",
  "gate_passed": true,
  "orchestrator": {
    "project": "owo/orchestrator",
    "pipeline_url": "https://gitlab/..."
  },
  "bus": {
    "project_id": 1,
    "package": "runs",
    "version": "<uuid>"
  },
  "services": {
    "builder": {
      "ref": "orch-prod",
      "status": "success"
    },
    "metrics": {
      "ref": "orch-prod",
      "status": "success"
    },
    "sandbox": {
      "ref": "orch-prod",
      "status": "success"
    }
  },
  "artifacts": {
    "inputs": [],
    "outputs": {
      "builder": [
        {"file": "service_meta.json", "hash": "SHA256:1aab..."},
        {"file": "exe.bin", "hash": "SHA256:12ab.."},
      ],
      "metrics": [
        {"file": "service_meta.json", "hash": "SHA256:a4cb..."},
        {"file": "metrics.json", "hash": "SHA512:de0d..."},
      ],
      "sandbox": [
        {"file": "service_meta.json", "hash": "SHA256:34ba..."},
        {"file": "sandbox.json", "hash": "SHA512:42de..."},
        {"file": "stdout.txt", "hash": "SHA512:791e..."},
        {"file": "stderr.txt", "hash": "SHA512:0b9f..."},
      ]
    },
    "bundle": "final/run-<uuid>.7z"
  }
}
```

Design intent:

* Humans can skim it
* Machines can index it
* Nothing inside requires GitLab context to understand

If you lose GitLab tomorrow, the manifest still explains the run.

---

## 14. Appendix

This appendix collects reference material, conventions, and lookup tables that support the main text without interrupting its flow.

---

### 14.1 Glossary

**Orchestrator**
The central GitLab project that defines the DAG and coordinates execution across services.

**Service Overlay**
A GitLab project that wraps a vendor service with an orchestration-aware CI contract.

**Bus**
A GitLab project used as a durable artifact store, typically backed by the Generic Package Registry.

**Run ID**
A UUID generated at kickoff that uniquely identifies a workflow execution.

**Manifest**
A machine-readable JSON file describing the inputs, outputs, services, and bundle for a run.

**DAG**
Directed Acyclic Graph describing execution order and dependencies.

---

### 14.2 Canonical Directory Layout (Run Workspace)

Inside the orchestrator job workspace, the recommended structure is:

```text
out/
  in/
  <svc>/
    service_meta.json
    ...
  manifest.json
  final/
    run-<RUN_ID>.7z
```

This structure is intentionally boring and predictable.

---

### 14.3 Common CI Variables

| Variable             | Purpose                                  |
| -------------------- | ---------------------------------------- |
| `RUN_ID`             | Unique identifier for the run            |
| `OWO_BUS_PROJECT_ID` | Numeric project ID of the bus            |
| `OWO_BUS_PACKAGE`    | Generic Package name                     |
| `OWO_*_REF`          | Git ref for a service overlay            |
| `CI_JOB_TOKEN`       | Auth token used for intra-project access |

---

### 14.4 Minimal Kickoff Job (Reference)

```yaml
kickoff:
  stage: kickoff
  script:
    - set -e
    - test -n "$OWO_BUS_PROJECT_ID"
    # Ensure uuidgen is available (apk add util-linux) or use /proc/sys/kernel/random/uuid
    - echo "RUN_ID=$(uuidgen)" > run.env
  artifacts:
    reports:
      dotenv: run.env
```

---

### 14.5 Minimal Trigger Job (Reference)

```yaml
trigger_builder:
  stage: trigger
  needs:
    - job: kickoff
      artifacts: true
  trigger:
    project: owo/builder-hello
    branch: $OWO_BUILDER_REF
    strategy: depend
  variables:
    RUN_ID: $RUN_ID
    OWO_BUS_PROJECT_ID: $OWO_BUS_PROJECT_ID
    OWO_BUS_PACKAGE: $OWO_BUS_PACKAGE
```

---

### 14.6 Minimal Bus Publish (Reference)

The publish stage uses **two jobs** to route artifacts based on pipeline status.

```yaml
publish_success:
  stage: publish
  needs:
    - job: bundle
      artifacts: true
  script:
    - |
      curl --fail \
        --header "JOB-TOKEN: $CI_JOB_TOKEN" \
        --upload-file final/run-$RUN_ID.7z \
        "$CI_API_V4_URL/projects/$OWO_BUS_PROJECT_ID/packages/generic/$OWO_BUS_PACKAGE/$RUN_ID/final/run-$RUN_ID.7z"
  when: on_success  # Default; runs only if gate passed

publish_failed:
  stage: publish
  needs:
    - job: bundle
      artifacts: true
  script:
    - |
      curl --fail \
        --header "JOB-TOKEN: $CI_JOB_TOKEN" \
        --upload-file final/run-$RUN_ID.7z \
        "$CI_API_V4_URL/projects/$OWO_BUS_PROJECT_ID/packages/generic/${OWO_BUS_PACKAGE}-failed/$RUN_ID/final/run-$RUN_ID.7z"
  when: on_failure  # Runs only if gate failed
```

**How it works:**

* `when: on_success` (the default) means the job runs only if all prior stages succeeded.
* `when: on_failure` means the job runs only if a prior stage failed.
* Both jobs `need` the `bundle` job's artifacts, ensuring the bundle exists regardless of gate outcome.
* Only one of these jobs will ever execute per run.

---

### 14.7 Failure Modes Cheat Sheet

| Symptom           | Likely Cause                    |
| ----------------- | ------------------------------- |
| 403 from bus      | Token not allowlisted           |
| Empty variables   | Not passed via trigger          |
| Clone failures    | Runner network misconfigured    |
| Missing artifacts | Service CI not exporting `out/` |

---

### 14.8 Versioning the Build Book

This document should be versioned.

Treat it like code:

* Tag releases
* Note breaking changes
* Keep reference implementation examples reproducible

The architecture is stable.

The details will evolve.

---

### 14.9 Format Selection Decision Tree (YAML vs JSON vs XML)

When you're deciding what format a file should be, start by asking: is this file expressing **intent** (configuration) or preserving **evidence** (outputs/results)?

Quick decision tree:

```text
Is this file primarily authored/edited by humans?
  +- Yes -> YAML
  |        - best for configuration, knobs, and policy
  |        - readable, supports comments
  |
  +- No (generated by tools) -> JSON
           - best for manifests, machine output, indexing/ingestion
           - strict and widely supported across languages

Are you forced into a specific ecosystem/standard that requires XML?
  +- Yes -> XML (but keep it narrow; generate it from YAML/JSON when possible)
```

Rules of thumb:

* Use **YAML** for *control plane* artifacts: pipeline definitions, orchestration wiring, and parameters people will review and tune.
* Use **JSON** for *run records* and machine outputs: `manifest.json`, `service_meta.json`, metrics, and results.
* Use **XML** only when an external contract requires it (legacy tooling, standards-driven interfaces). Prefer generating it rather than hand-authoring.

One practical warning: YAML is powerful enough to be ambiguous across implementations. Keep YAML files "boringly structured" (maps/lists/scalars) and avoid clever features.

---

## 15. License

Copyright (c) 2026 Omega Development

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

[http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
