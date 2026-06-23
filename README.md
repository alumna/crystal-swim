# Swim (crystal-swim)

![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/alumna/crystal-swim/ci.yml) [![codecov](https://codecov.io/gh/alumna/crystal-swim/branch/master/graph/badge.svg?token=FasTA63Qyj)](https://codecov.io/gh/alumna/crystal-swim) ![Dynamic YAML Badge](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Falumna%2Fcrystal-swim%2Frefs%2Fheads%2Fmaster%2Fshard.yml&query=version&prefix=v&label=version) ![GitHub License](https://img.shields.io/github/license/alumna/backend)

A production-grade, thread-safe implementation of the [SWIM](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf) (Scalable Weakly-consistent Infection-style Process Group Membership) protocol for Crystal.

This shard is designed to answer one question deterministically and efficiently: *"Who is currently in the cluster, and who is dead?"*

## Features

* **Hexagonal Architecture (Sans-I/O):** The core protocol is a pure state machine decoupled from sockets, allowing for instantaneous, deterministic network partition testing.
* **Lifeguard Extensions Included:** Natively implements Suspicion Refutation and Local Health Awareness (LHA) to dynamically scale timeouts and prevent false-positive cascading failures in degraded networks.
* **Thread-Safe & Crystal 1.20+ Native:** Safe to read from and write to concurrently, natively supporting Execution Contexts (`preview_mt`). Uses `Time.instant` for monotonic, NTP-skew-proof clock safety.
* **Zero-Allocation Hot Paths:** Memory-optimized gossip engine and UDP networking to ensure flat memory usage in long-running, highly active clusters.
* **Randomized Piggybacked Gossip:** Cluster state is disseminated exponentially fast with zero extra packets via MTU-bounded randomized piggybacking, guaranteeing multi-hop convergence.
* **Tombstone Garbage Collection:** Automatically and safely prunes long-dead nodes from the registry to reclaim memory in long-running clusters.
* **Payload Encryption (AES-256-GCM):** Optional cryptographic authentication and encryption for secure clustering over untrusted public networks.
* **Zero Dependencies:** Pure Crystal implementation based entirely on Crystal's stdlib.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     swim:
       github: alumna/crystal-swim
   ```

2. Run `shards install`

## Usage

```crystal
require "swim"

# 1. Define the local member (Use a timestamp for the incarnation number in production)
local_member = Swim::Member.new(
  id: "node-1",
  address: "10.0.0.1:5000",
  incarnation: Time.utc.to_unix.to_u64,
  state: Swim::State::Alive
)

members = Swim::MembershipList.new

# 2. Initialize the Protocol 
# (Optional: Configure base timeouts and Tombstone GC time-to-live)
protocol = Swim::Protocol.new(
  local_member, 
  members,
  base_timeout: 500.milliseconds,
  tombstone_ttl: 24.hours
)

# (Optional) Seed the node with a known peer to join the cluster
seed_node = Swim::Member.new("node-2", "10.0.0.2:5000", 0_u64, Swim::State::Alive)
members.update(seed_node)

# 3. Start the background network engine
# (Optional: Pass a shared secret to enable AES-256-GCM encryption across the cluster)
node = Swim::Node.new(protocol, host: "0.0.0.0", port: 5000, encryption_key: "my-cluster-secret")
node.start(tick_interval: 1.second)

# Read the current active cluster state safely from any thread
puts "Currently active nodes: #{node.protocol.members.size}"

# Graceful shutdown
node.stop
```

## Contributing

1. Fork it (<https://github.com/alumna/crystal-swim/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Ensure specs pass with 100% coverage (`crystal spec`)
4. Commit your changes (`git commit -am 'Add some feature'`)
5. Push to the branch (`git push origin my-new-feature`)
6. Create a new Pull Request
