# Swim changelog

## 0.2.1 - 2026-06-23

### Performance
* **memory:** **Zero-Allocation Cipher Hot Path.** Replaced `IO::Memory` with direct slice copying and `String.build` in AES-GCM encryption/decryption, reducing GC pressure on encrypted clusters.
* **memory:** Refactored `MembershipList#sample` to eliminate continuous `Set` allocations per tick, utilizing faster Array lookups for exclusion checking.
* **memory:** Compacted the `Swim::State` enum to `UInt8` to reduce the baseline memory footprint of the cluster registry.
* **network:** Removed string allocation in `Swim::Node`'s address cache by utilizing stack-allocated `rpartition` tuples.

### Reliability & Fixes
* **core:** **Monotonic Clock Migration.** Replaced `Time.utc` with Crystal 1.20's `Time.instant`. Tombstone Garbage Collection is now better prepared to system clock skew and NTP synchronization jumps.
* **network:** **Maximum UDP Buffer.** Increased the UDP receive buffer in `Swim::Node` to 65507 bytes (the absolute maximum UDP payload). This guarantees messages are never truncated, even in massive clusters with large piggyback MTUs.
* **tests:** Resolved an intermittent port collision (`5010`) between sequential runs of `node_spec.cr` and `cluster_integration_spec.cr`.

### Internal
* **safety:** Introduced exhaustive pattern matching (`case ... in`) across `MessageType`, `TimeoutType`, and `Effect` unions. The compiler now statically guarantees that all future protocol additions are safely handled.
* **protocol:** DRY'd up identical state update branches (`mark_alive`, `mark_suspect`, `mark_dead`) into a single, idempotent `mark_as` routine.

## 0.2.0 - 2026-06-23

### Added
* **security:** Optional **AES-256-GCM Payload Encryption**. Passing a shared `encryption_key` to `Swim::Node` hashes the key via SHA-256 and silently secures all UDP traffic. Unauthenticated or tampered packets are automatically dropped before reaching the protocol layer.
* **memory:** **Tombstone Garbage Collection**. `Swim::Protocol` now periodically and non-blockingly prunes `Dead` nodes older than `tombstone_ttl` (defaults to 24 hours), permanently fixing memory leaks in long-running deployments.

### Changed
* **protocol:** A node will now aggressively refute `Dead` status gossip about itself, not just `Suspect` status, ensuring smooth cluster rejoins after network partitions heal.
* **protocol:** `fetch_gossip` now guarantees the inclusion of the local node's state in its payload. This ensures suspicion refutations propagate with zero added latency.
* **architecture:** `Swim::Effect` is now implemented as a compile-time exhaustive union alias (`SendMessage | ScheduleTimeout`), enhancing type safety.

### Performance
* **network:** Implemented a thread-safe Address Cache inside `Swim::Node` to prevent allocating and resolving IP strings on every single UDP send.
* **core:** Replaced nested logic in `MembershipList` with native tuple comparisons to execute SWIM precedence rules (`Dead > Suspect > Alive`) branchlessly.
* **core:** O(N) optimizations to `MembershipList#sample` using native Crystal `Set` allocations.

## 0.1.0 - 2026-06-23

### Added
* **protocol:** Implemented the core SWIM protocol logic (Direct Ping, Indirect Ping-Req, Ack).
* **protocol:** Integrated MTU-bounded, **Randomized Piggybacked Gossip**. Node states spread exponentially fast on top of standard failure-detection packets, automatically healing network splits and guaranteeing multi-hop convergence.
* **protocol:** Nodes instantly self-announce upon booting to ensure zero-latency discovery by seed nodes.
* **lifeguard:** Natively integrated **Suspicion Refutation**. Nodes can detect when they are suspected by the cluster, increment their incarnation number, and broadcast their survival to mathematically override the suspicion.
* **lifeguard:** Natively integrated **Local Health Awareness (LHA)**. Nodes dynamically scale their own timeout spans when their network probes fail, gracefully slowing down to prevent falsely declaring others dead during local network degradation.
* **architecture:** Hexagonal/Sans-I/O design. The core `Swim::Protocol` is a mathematically pure, dependency-free state machine, isolating it entirely from sockets and system time.
* **network:** Thread-safe, background UDP networking engine (`Swim::Node`) built natively for Crystal 1.20+ Execution Contexts (`preview_mt`).
* **api:** Centralized `src/swim.cr` entrypoint for simpler application inclusion.
* **api:** Parameterized `base_timeout` and `tick_interval` to support both environment-specific tuning and lightning-fast local testing.
* **tests:** Achieved 100% deterministic test coverage on domain logic without using real sockets or `sleep`.
* **tests:** Exhaustive real UDP integration tests (3, 5, and 7-node linear topologies) validating multi-hop propagation, strict MTU payload limits, sudden hardware crashes, and dynamic dead-node resurrections.
