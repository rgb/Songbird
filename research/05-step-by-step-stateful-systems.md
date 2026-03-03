# Concurrency Step-by-Step: Stateful Systems

**Source:** https://www.massicotte.org/step-by-step-stateful-systems/
**Author:** Matt Massicotte
**Date:** December 30, 2024
**Level:** 1 — Practical Understanding

Explores managing stateful systems in Swift concurrency, moving beyond read-only examples to tackle real-world scenarios involving mutable state and asynchronous operations.

## The Problem: Reentrancy

Asynchronous operations can create "logical races" when a function can be invoked multiple times before previous invocations complete. This occurs without data races — multiple threads aren't accessing the same memory locations. Instead, non-deterministic execution ordering causes issues.

## From Dispatch to Actors

The author compares two implementations of a remote system:

**Original (dispatch-based):** Uses `DispatchQueue` with completion handlers and `@unchecked Sendable` marking.

**Modern (actor-based):** Dramatically simplifies the code using Swift's actor model, which naturally enforces async-only access to internal state.

## Critical Insight: Synchronous Checks Matter

To prevent multiple concurrent executions, state checks must happen synchronously, before any `await` points:

> "The check must be synchronous... while more than one could potentially be started, only one can execute the synchronous code."

Placing guards inside async blocks after `await` calls creates vulnerabilities where state assumptions become invalid.

## Important Distinctions

- Async functions aren't mere syntactic sugar for completion handlers — they have critical semantic differences
- Actors can still experience logical races internally despite being single-threaded constructs
- Real network services cannot be made synchronous, requiring ongoing queue or stream solutions

## Practical Recommendations

For managing actor state mutations:

- Start by confirming you actually need an actor
- Keep state access simple before reaching for locks
- Consider async-aware synchronization primitives when necessary
- Use `AsyncStream` for observable state changes
