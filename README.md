# Swim (crystal-swim)

[![Crystal CI](https://github.com/alumna/crystal-swim/actions/workflows/ci.yml/badge.svg)](https://github.com/alumna/crystal-swim/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/alumna/crystal-swim/branch/main/graph/badge.svg)](https://codecov.io/gh/alumna/crystal-swim)

A production-grade, thread-safe implementation of the [SWIM](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf) (Scalable Weakly-consistent Infection-style Process Group Membership) protocol for Crystal.

This shard is designed to answer one question deterministically and efficiently: *"Who is currently in the cluster, and who is dead?"*

## Features

* **Hexagonal Architecture (Sans-I/O):** The core protocol is a pure state machine decoupled from time and sockets, allowing for instantaneous, deterministic network partition testing.
* **Thread-Safe:** Safe to read from and write to concurrently, natively supporting Crystal 1.20+ Execution Contexts (`preview_mt`).
* **Piggybacked Gossip:** Cluster state is disseminated exponentially fast with zero extra packets via MTU-bounded piggybacking.
* **Zero Dependencies:** Relies entirely on the Crystal standard library.

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

# 1. Define the local member
local_member = Swim::Member.new(
  id: "node-1", 
  address: "10.0.0.1:5000", 
  incarnation: 1_u64, 
  state: Swim::State::Alive
)

# 2. Initialize the Membership List and Protocol
members = Swim::MembershipList.new
protocol = Swim::Protocol.new(local_member, members)

# (Optional) Seed the node with a known peer to join the cluster
seed_node = Swim::Member.new("node-2", "10.0.0.2:5000", 1_u64, Swim::State::Alive)
members.update(seed_node)

# 3. Start the background network engine
node = Swim::Node.new(protocol, host: "0.0.0.0", port: 5000)
node.start(tick_interval: 1.second)

# ... your application logic ...
puts "Currently active nodes: #{node.protocol.members.size}"

# Graceful shutdown
node.stop
```

## Contributing

1. Fork it (<https://github.com/alumna/crystal-swim/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Ensure specs pass (`crystal spec`)
4. Commit your changes (`git commit -am 'Add some feature'`)
5. Push to the branch (`git push origin my-new-feature`)
6. Create a new Pull Request
