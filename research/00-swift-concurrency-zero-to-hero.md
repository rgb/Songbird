# Swift Concurrency from Zero to Hero

**Source:** https://swiftology.io/articles/swift-concurrency-zero-to-hero/

A curated learning path that progresses from foundational concepts to expert-level mastery of Swift Concurrency, with each level significantly more challenging than the previous.

## Level 0 — Foundations

**Primary Resource:**
- [Fucking Approachable Swift Concurrency](01-approachable-swift-concurrency.md) by Pedro Pinera Buendia — Easy and fun read with lots of playful analogies

**Bonus:**
- [Official Swift Language Guide on Concurrency](02-swift-book-concurrency.md) (more formal alternative)

## Level 1 — Practical Understanding

**Series by Matt Massicotte:**
1. [A Network Request](03-step-by-step-network-request.md)
2. [Reading from Storage](04-step-by-step-reading-from-storage.md)
3. [Stateful Systems](05-step-by-step-stateful-systems.md)
4. [Conforming to Protocols](06-step-by-step-conforming-to-protocols.md)

These materials go "beyond simple recipes" to weave in insights from industry veterans that deepen understanding as knowledge accumulates.

**Bonus:** [A Swift Concurrency Glossary](07-concurrency-glossary.md) (best used as reference after encountering concepts naturally)

## Level 2 — Design Principles

**Primary:**
- [Swift Concurrency Waits for No One](08-swift-concurrency-waits-for-no-one.md) by Saagar Jha — explores forward progress guarantees as a foundational design principle

**Bonus Video:**
- *Concurrency Hylomorphism* by Lucian Radu Teodorecu — demonstrates implementing similar concurrency models to reveal underlying principles

## Level 3 — Language Design

**Swift Evolution Proposals** covering:
- Core features (async/await, structured concurrency, continuations, async sequences)
- Actors (including global actors and custom executors)
- Isolation mechanisms
- Synchronization primitives

**Bonus:** Swift Concurrency Manifesto by Chris Lattner — provides historical context and original vision

## Level Hero — Code-Level Mastery

**Resource:** [swift-async-algorithms](../../swift-async-algorithms/) repository (cloned locally)

Study the ~12,000 lines of source code to understand practical implementations, including why certain types are `Sendable`, when to use `nonisolated(unsafe)`, and cancellation handling patterns.
