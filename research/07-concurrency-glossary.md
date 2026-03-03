# A Swift Concurrency Glossary

**Source:** https://www.massicotte.org/concurrency-glossary/
**Author:** Matt Massicotte
**Published:** January 25, 2025
**Updated:** September 17, 2025
**Level:** 1 — Practical Understanding (Reference)

A comprehensive reference compiling terminology, keywords, and annotations related to Swift concurrency. "By no means do you need to understand everything here to use Swift Concurrency successfully."

## Core Concepts

**`actor`** — A reference type keyword that protects mutable state and defines isolation units (SE-0306). Simple to create but require practice to use effectively.

**`@MainActor`** — The global actor annotation for the shared `MainActor` instance, commonly encountered in Swift development.

**Isolation** — An abstraction representing thread-safety provided by actors, potentially implemented through serial queues.

## Asynchronous Execution

**`async`** — A function keyword enabling `await` usage and suspension capabilities (SE-0296).

**`await`** — Marks suspension points within async functions, potentially allowing executor changes.

**`async let`** — Flow control enabling asynchronous work without immediate awaiting, useful for slow synchronous operations.

## Type Safety & Concurrency

**`Sendable`** — A marker protocol indicating types can safely operate across any isolation context (SE-0302).

**`sending`** — A keyword encoding strict behavioral promises about concurrent parameter/return value usage (SE-0430).

**Region-Based Isolation** — A compiler analysis system proving certain non-`Sendable` usage patterns remain safe within function scopes (SE-0414).

## Isolation Control

**`nonisolated`** — Explicitly disables actor isolation for specific declarations.

**`nonisolated(unsafe)`** — Opts declarations out of Sendable compiler checking (SE-0306).

**`isolated`** — Defines static isolation via function parameters, essential for non-`Sendable` type integration (SE-0313).

**`@concurrent`** — Marks a function to always run off the caller's actor, on the cooperative thread pool.

## Advanced Features

**`Task`** — Creates top-level async execution contexts with cancellation and result access support.

**`TaskGroup`** — Manages multiple child tasks simultaneously.

**`TaskLocal`** — Task-specific values analogous to thread-local storage.

**Continuations** — APIs wrapping callback-based code for `await` compatibility (SE-0300).

## Compatibility & Migration

**`@preconcurrency`** — Handles Swift 6 code interacting with pre-concurrent implementations, essential for gradual migration.

All entries include their type classification, usage context, and introducing Swift Evolution proposals for deeper exploration.
