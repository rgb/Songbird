# Concurrency Step-by-Step: Conforming to Protocols

**Source:** https://www.massicotte.org/step-by-step-conforming-to-protocols/
**Author:** Matt Massicotte
**Date:** October 25, 2025
**Level:** 1 — Practical Understanding

Explores the practical challenges of adding protocol conformances to types in Swift's concurrency system, focusing on isolation mismatches and available solutions.

## The Core Problem

When a type is isolated to an actor (like `@MainActor`), conforming it to protocols expecting `nonisolated` methods creates a conflict. "We cannot have a method that is both usable from everywhere and also only usable from the `MainActor`."

## Four Solution Approaches

### 1. Dynamic Isolation (`assumeIsolated`)

Requires wrapping code that accesses isolated properties within `MainActor.assumeIsolated {}` blocks. This is verbose and risks crashes if called from wrong contexts.

### 2. Preconcurrency Conformance

Using `@preconcurrency` annotation simplifies syntax but semantically misrepresents the problem — it implies the protocol itself should be actor-isolated.

### 3. Isolated Conformances (Swift 6.2+)

The modern solution allowing conformances constrained to specific global actors:

```swift
extension ImageModel: @MainActor Equatable {}
```

### 4. Non-Sendable First Design

Making types `nonisolated` and relying on `Sendable` restrictions to ensure thread safety naturally, avoiding isolation altogether when possible.

## Practical Recommendation

Massicotte's preferred ordering for solutions:

1. Nonisolated types
2. Isolated conformances
3. Preconcurrency conformances
4. Dynamic isolation (last resort)

## Important Context

Compiler settings matter significantly. "Approachable Concurrency" (combining `MainActor` defaults with `InferIsolatedConformances`) differs fundamentally from strict Swift 6 semantics, making code behavior settings-dependent.
