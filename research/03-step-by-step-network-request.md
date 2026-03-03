# Concurrency Step-by-Step: A Network Request

**Source:** https://www.massicotte.org/step-by-step-network-request/
**Author:** Matt Massicotte
**Level:** 1 — Practical Understanding

A foundational guide to understanding Swift Concurrency through a practical example: loading an image from a network request. Emphasizes building solid conceptual understanding rather than just making code compile.

## Setup

The tutorial uses SwiftUI to create a simple robot image loader from the Robohash API. It demonstrates handling optional data and managing asynchronous operations.

## GCD Approach

The initial implementation uses Grand Central Dispatch, showing:
- Network requests that occur on background threads
- Explicit main thread dispatching for UI updates
- A two-phase operation: I/O-bound networking and CPU-bound image processing

Key insight: "I/O-bound" networking is "waiting," while CPU-bound processing is "working."

## Isolation and MainActor

A critical concept introduced is "isolation" — Swift Concurrency's way of protecting shared state. The `MainActor` ensures code runs on the main thread, replacing the mental model of "main thread vs. not."

**Isolation applies to an entire function. Not some parts — the whole thing.**

## Async/Await Implementation

Using SwiftUI's `.task` modifier provides an async context. The function becomes cleaner but initially keeps all work on the MainActor.

## Optimization with @concurrent

The `@concurrent` attribute forces background execution, requiring refactoring to separate data fetching from UI updates. This matches the GCD pattern's benefits more explicitly.

## Alternative Approaches

Two alternatives are presented:

1. **Task.detached** — Mirrors GCD patterns but adds complexity
2. **MainActor.run** — More explicit but less elegant than leveraging the type system

## Core Takeaways

- Understand **where** code executes (main thread vs. background)
- Use function signatures and attributes to express isolation requirements
- Keep UI mutations on the MainActor; computations can happen elsewhere
- Let the type system guide proper concurrent design

The author recommends mastering these basics before exploring advanced isolation mechanics.
