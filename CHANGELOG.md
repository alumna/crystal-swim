# Swim changelog

## 0.1.0 - 2026-06-23

### Added
* **protocol:** Implemented the core SWIM protocol logic (Direct Ping, Indirect Ping-Req, Ack).
* **protocol:** Integrated MTU-bounded, piggybacked gossip dissemination. Node states spread exponentially fast on top of standard failure-detection packets.
* **lifeguard:** Natively integrated **Suspicion Refutation**. Nodes can detect when they are suspected by the cluster, increment their incarnation number, and broadcast their survival to mathematically override the suspicion.
* **lifeguard:** Natively integrated **Local Health Awareness (LHA)**. Nodes dynamically scale their own timeout spans when their network probes fail, gracefully slowing down to prevent falsely declaring others dead during local network degradation.
* **architecture:** Hexagonal/Sans-I/O design. The core `Swim::Protocol` is a mathematically pure, dependency-free state machine, isolating it entirely from sockets and system time.
* **network:** Thread-safe, background UDP networking engine (`Swim::Node`) built natively for Crystal 1.20+ Execution Contexts (`preview_mt`).
* **tests:** Achieved 100% deterministic test coverage, including simulated network partitions and graceful recovery sequences, without using real sockets or `sleep` in the domain logic tests.
* **tests:** Real UDP tests, covering all scenarios including ones with malformed content, ensuring resiliency even on worts-case scenarios.
