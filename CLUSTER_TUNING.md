# Cluster Tuning & Geographic Distribution Guide

`crystal-swim` is designed to be highly efficient right out of the box, with default settings tailored for typical cloud environments. However, distributed systems are rarely "one size fits all." 

Depending on whether your cluster is running entirely inside a single datacenter, or spanning multiple continents, you will need to tune the protocol:

- if you configure a global cluster to run too fast, it will fight the network latency (fighting the physical speed of light on fiber) and collapse.
- if you configure a local cluster to run too slow, you leave valuable failover speed on the table.

This guide gives suggestions on how to tune your cluster to work in harmony with your network's physics.

---

## The Two Core Knobs

To tune your cluster, you only need to understand two configuration options:

1. **`tick_interval`** (Passed to `Swim::Node#start`): How often a node picks a random peer to send a Ping. This dictates the "speed" of your cluster's gossip.
2. **`base_timeout`** (Passed to `Swim::Protocol.new`): How long a node will wait for an Ack before deciding the Ping failed and initiating indirect requests.

### The Golden Rule of Timeouts
Because the SWIM protocol dictates that a node must try a Direct Ping, wait for a failure, and *then* try an Indirect Ping-Req, **your `base_timeout` must always be less than half of your `tick_interval`.** 
*(e.g., If your `tick_interval` is 1 second, your `base_timeout` should be at most 500 milliseconds).*

---

## The Physics Limit: Why we can't just run at 100ms everywhere

Imagine you have a cluster spanning from New York to London. The physical speed-of-light network latency (Round Trip Time or RTT) is about **90ms**.

What happens if you aggressively set your `tick_interval` to `100ms` and your `base_timeout` to `40ms`?

1. Node A (NY) sends a Ping to Node B (London). The packet takes 45ms to cross the ocean.
2. At the 40ms mark, Node A's timeout expires. It assumes the packet was lost and flags the direct ping as a failure.
3. Meanwhile, Node B receives the Ping at 45ms and immediately replies with an Ack.
4. Node A triggers indirect helpers to verify Node B, but those timeouts also expire prematurely because crossing the ocean takes too long.
5. Node A declares Node B `Suspect`. Node B eventually hears this gossip, increments its incarnation, and shouts "I'm alive!"

Because *every* ping across the ocean fails the timeout, the network gets flooded with a storm of false suspicions and refutations. 

**The Lesson:** Your `base_timeout` must comfortably accommodate your network's maximum Round Trip Time (RTT), including jitter.

---

## Tuning Scenarios & Convergence Estimates

Here is a quick reference guide for recommended configurations based on your physical infrastructure:

| Environment | Average RTT | Recommended `base_timeout` | Recommended `tick_interval` |
| :--- | :--- | :--- | :--- |
| **Localhost / Tests** | < 1 ms | 40 ms | 100 ms |
| **Same Datacenter / LAN** | 1 - 2 ms | 100 ms | 250 - 500 ms |
| **Same Region (Multi-AZ)** | 2 - 10 ms | 200 ms | 500 ms - 1 second |
| **Multi-Region (e.g. US to EU)** | 80 - 150 ms | 500 ms | 1 - 2 seconds |
| **Global (e.g. US to Asia)** | 200 - 300 ms | 1000 ms (1 sec) | 2 - 3 seconds |

Because `crystal-swim` relies on an epidemic gossip model, state disseminates exponentially. The expected number of rounds required to fully synchronize a cluster of $N$ nodes is roughly mathematically modeled as: $R \approx \log_2(N) + \ln(N)$. 

Below is a detailed breakdown of specific scenarios, along with the estimated time it takes for a single cluster change to propagate to 100% of the nodes.

### Scenario A: High-Speed Local Network
**Use Case:** Highly available Game Servers, High-Frequency Trading, or single-datacenter local hardware with microsecond latency. You need failovers to happen near-instantly.

* **Average Latency:** < 2 ms
* **Recommended `tick_interval`:** 100 milliseconds
* **Recommended `base_timeout`:** 40 milliseconds
* **Network Load:** 10 Pings per second, per node.

```crystal
protocol = Swim::Protocol.new(local, members, base_timeout: 40.milliseconds)
node = Swim::Node.new(protocol, "0.0.0.0", 5000)
node.start(tick_interval: 100.milliseconds)
```

| Cluster Size | Estimated Convergence Time |
| :--- | :--- |
| **10 Nodes** | ~0.6 seconds |
| **100 Nodes** | ~1.1 seconds |
| **1,000 Nodes** | ~1.7 seconds |
| **10,000 Nodes** | ~2.3 seconds |

---

### Scenario B: Standard Cloud Infrastructure (Multi-AZ)
**Use Case:** A typical AWS, GCP, or Azure VPC spanning multiple Availability Zones within the same region (e.g., `us-east-1a` to `us-east-1c`). 

* **Average Latency:** 2 to 10 ms
* **Recommended `tick_interval`:** 500 milliseconds
* **Recommended `base_timeout`:** 200 milliseconds
* **Network Load:** 2 Pings per second, per node.

```crystal
protocol = Swim::Protocol.new(local, members, base_timeout: 200.milliseconds)
node = Swim::Node.new(protocol, "0.0.0.0", 5000)
node.start(tick_interval: 500.milliseconds)
```

| Cluster Size | Estimated Convergence Time |
| :--- | :--- |
| **10 Nodes** | ~2.8 seconds |
| **100 Nodes** | ~5.6 seconds |
| **1,000 Nodes** | ~8.4 seconds |
| **10,000 Nodes** | ~11.3 seconds |
| **100,000 Nodes**| ~14.1 seconds |

---

### Scenario C: Global / Multi-Region WAN
**Use Case:** Edge computing, multi-continent datacenters, or IoT networks spanning the globe (e.g., US to Europe to Asia). High latency is expected, and connections can occasionally flutter.

* **Average Latency:** 100 to 300 ms
* **Recommended `tick_interval`:** 2 seconds
* **Recommended `base_timeout`:** 800 milliseconds
* **Network Load:** 1 Ping every 2 seconds, per node.

```crystal
protocol = Swim::Protocol.new(local, members, base_timeout: 800.milliseconds)
node = Swim::Node.new(protocol, "0.0.0.0", 5000)
node.start(tick_interval: 2.seconds)
```

| Cluster Size | Estimated Convergence Time |
| :--- | :--- |
| **10 Nodes** | ~11.2 seconds |
| **100 Nodes** | ~22.6 seconds |
| **1,000 Nodes** | ~33.8 seconds |
| **10,000 Nodes** | ~45.0 seconds |
| **100,000 Nodes**| ~56.2 seconds |

*(Note: In global environments, consistency takes roughly a minute at massive scale, which is perfectly acceptable and expected for geo-distributed failure detection.)*

---

## A Note on MTU and Piggybacked Gossip

You might wonder why `crystal-swim` limits the amount of gossip attached to each Ping/Ack packet to exactly **5 updates** (`MAX_PIGGYBACK_SIZE`). 

This is a mathematical safety feature designed to protect your cluster from **UDP Fragmentation**. 

Standard Ethernet limits a single packet to 1500 bytes (the MTU). If a UDP packet exceeds this size, your network router will split it into smaller fragments. If *even one* of those fragments is dropped over the network, the entire UDP packet is silently discarded by the receiving operating system.

By capping the piggyback size at 5, `crystal-swim` guarantees that your protocol packets remain around **~600 bytes**. This ensures that your gossip packets easily fit inside a single transmission frame, even on highly restrictive networks or encrypted VPNs (like WireGuard), providing guaranteed resilience against packet loss.
