# Concurrency Step-by-Step: Reading from Storage

**Source:** https://www.massicotte.org/step-by-step-reading-from-storage/
**Author:** Matt Massicotte
**Level:** 1 — Practical Understanding

Explores Swift concurrency fundamentals by working through a practical example of loading data from storage. Builds on previous networking concepts to help developers understand concurrent behavior through type system design.

## The Core Problem

The article demonstrates why a simple data-loading pattern fails in Swift 6 mode. When attempting to pass non-`Sendable` types across actor boundaries (like from background work back to `MainActor`), the compiler raises errors that often confuse developers.

## Why Types Matter

"Swift concurrency is an extension of the type system." This means developers can iterate on designs and receive compiler feedback about concurrent behavior without running code — a powerful advantage.

## Practical Solutions

The author presents several approaches:

- **Making types `Sendable`** — Converting classes to final or restructuring as value types removes boundary-crossing issues
- **Isolating work** — Applying `@MainActor` prevents background execution but simplifies constraints
- **Value types with stateless functions** — Keeping pure input-to-output transformations in non-isolated async methods
- **Swift 5 compatibility modules** — Isolating non-concurrent code in separate build targets
- **Advanced tools** — The `sending` keyword and custom actors provide flexibility for complex scenarios

## Critical Warnings

Massicotte cautions against "split isolation" — applying different isolation attributes to methods within the same non-`Sendable` type. He emphasizes that adding actors increases boundary complexity rather than solving it, and warns that unsafe opt-out mechanisms like `@unchecked Sendable` carry hidden costs.

## Key Takeaway

Introduce concurrency complexity only when justified by real requirements.
