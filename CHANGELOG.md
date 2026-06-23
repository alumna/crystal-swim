# Swim changelog

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
