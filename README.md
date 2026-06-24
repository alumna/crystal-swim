# Swim (crystal-swim)

![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/alumna/crystal-swim/ci.yml) [![codecov](https://codecov.io/gh/alumna/crystal-swim/branch/master/graph/badge.svg?token=FasTA63Qyj)](https://codecov.io/gh/alumna/crystal-swim) ![Dynamic YAML Badge](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Falumna%2Fcrystal-swim%2Frefs%2Fheads%2Fmaster%2Fshard.yml&query=version&prefix=v&label=version) ![GitHub License](https://img.shields.io/github/license/alumna/backend)

A production-grade, thread-safe implementation of [SWIM](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf) (Scalable Weakly-consistent Infection-style Process Group Membership) for Crystal, with Lifeguard extensions built in.

It answers one question efficiently: **"Who is currently in the cluster, and who is dead?"**

---

## What is SWIM?

SWIM is a highly efficient, decentralized protocol used in distributed computing to track which nodes are active in a cluster and quickly detect any node failures.

SWIM is not a consensus algorithm like Paxos or Raft. It does not agree on values or replicate logs. It maintains a live member list.

How it works, in three steps:

1. **Direct ping:** every second, your node randomly picks one peer and pings it
2. **Indirect check:** if no ack, it asks 2 to 3 other random peers to ping that target for it
3. **Gossip:** the result (alive, suspect, dead) is piggybacked on the next few UDP packets, spreading like infection

Because each node only talks to a constant, small number of peers, **network load stays flat regardless of cluster size**. A 10-node cluster and a 1,000-node cluster cost each node about the same few UDP packets per second. Traditional heartbeating grows quadratically with N, SWIM does not.

The trade-off is consistency: views are eventually consistent, not instantly identical everywhere. For membership, that is usually what you want.

## Why not just use Raft?

Use Raft or Paxos when you need strong agreement on data. Use SWIM when you need cheap, fast awareness of liveness.

| You need | Reach for |
| --- | --- |
| Replicated state machine, linearizable writes | Raft / Paxos |
| Service discovery, consistent-hash ring, failure detection at scale | SWIM |

Most real systems use both: SWIM keeps the peer list, a small Raft group (3 to 5 nodes) decides the data.

## How Lifeguard makes this production-ready

Pure SWIM assumes "if I don't get an ack, you are dead." Under CPU pressure, GC pauses, or spot-instance throttling, that causes false positives.

This shard natively implements the [Lifeguard extensions developed by HashiCorp](https://arxiv.org/abs/1707.00788) to solve this. It introduces two core ideas by default:

**1. Local Health Awareness (LHA)**
Your node tracks its own health score. Successful probes improve it, missed acks degrade it. When unhealthy, it automatically stretches its timeouts (`dynamic_timeout = base_timeout * (1 + health_multiplier)`). Instead of declaring the cluster dead, it backs off.

**2. Suspicion Refutation**
Nodes are never marked dead instantly. First they become "suspect" and that suspicion is gossiped. The suspect node can refute by bumping its incarnation number and announcing "I'm alive." Only after confirmation timeout does the cluster mark it dead.

In practice this reduces false-positive cascades by more than 50x in degraded networks, while keeping detection times low for real failures.

## When to use crystal-swim

- **Large, dynamic Crystal clusters:** 20 to 2,000 workers, game servers, job processors, or edge nodes that join and leave often
- **Ephemeral infrastructure:** Kubernetes pods, preemptible VMs, autoscaling groups where nodes get slow before they die
- **Decentralized discovery:** you want a member list without running etcd, Consul, or ZooKeeper
- **WAN or multi-AZ meshes:** where RTT varies and you need indirect probes to avoid false partitions

## When not to use it

- You need strong consistency or leader election for data. Use Raft.
- Your cluster is tiny (3 to 5 nodes) and completely stable. A simple TCP heartbeat is less code.
- You need millisecond-perfect global membership. SWIM converges in seconds, by design.

## Features

* **Lifeguard included:** Suspicion Refutation and Local Health Awareness are on by default, no config needed
* **Hexagonal Architecture (Sans-I/O):** core protocol is a pure state machine. You can simulate partitions deterministically in specs without opening sockets
* **Thread-Safe & Crystal 1.20+ Native:** safe for `preview_mt`, uses `Time.instant` for monotonic, NTP-skew-proof timers
* **Zero-Allocation Hot Paths:** gossip engine and AES-GCM cipher avoid GC pressure in long-running clusters
* **Randomized Piggybacked Gossip:** state disseminates exponentially with zero extra packets, MTU-bounded
* **Tombstone Garbage Collection:** dead nodes are pruned automatically after `tombstone_ttl`
* **Optional Payload Encryption:** AES-256-GCM for clustering over the public internet
* **Zero Dependencies:** pure Crystal stdlib

## Installation

1. Add to your `shard.yml`:

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
# (Using milliseconds guarantees a higher incarnation even on rapid sub-second reboots)
local_member = Swim::Member.new(
  id: "node-1",
  address: "10.0.0.1:5000",
  incarnation: Time.utc.to_unix_ms.to_u64,
  state: Swim::State::Alive
)

members = Swim::MembershipList.new

# 2. Initialize the protocol
protocol = Swim::Protocol.new(
  local_member,
  members,
  base_timeout: 500.milliseconds,
  tombstone_ttl: 24.hours
)

# Optional: seed with a known peer
seed = Swim::Member.new("node-2", "10.0.0.2:5000", 0_u64, Swim::State::Alive)
members.update(seed)

# 3. Start the network engine (Ensure UDP port 5000 is open in your firewall!)
# Pass an optional `encryption_key` to enable AES-256-GCM cluster-wide.
# (Omit this if your network is already secure, e.g. VPC/WireGuard, to save CPU).
node = Swim::Node.new(protocol, host: "0.0.0.0", port: 5000, encryption_key: "my-cluster-secret")
node.start(tick_interval: 1.second)

# 4. Keep the main fiber alive to let the background network engine run
begin
  loop do
    # Read cluster state safely from any fiber
    puts "Active nodes: #{node.protocol.members.all.count(&.state.alive?)}"
    sleep 2.seconds
  end
ensure
  # Graceful leave when you press Ctrl+C
  node.stop
end
```

The `Swim::Node` runs the UDP loop in the background. The `Swim::Protocol` is the pure logic you can unit-test by feeding it `Message` objects and inspecting the returned `Effect`s.

### Try it locally!

Want to see the cluster discovery and failure detection in action right now? Clone this repository and run the included example in three separate terminals:

```bash
# Terminal 1: Start the seed node
crystal run examples/cluster.cr -- -p 5000

# Terminal 2: Join the cluster
crystal run examples/cluster.cr -- -p 5001 -s 127.0.0.1:5000

# Terminal 3: Join the cluster
crystal run examples/cluster.cr -- -p 5002 -s 127.0.0.1:5001
```
*Tip: Try killing Terminal 2 (`Ctrl+C`) and watch Terminals 1 and 3 dynamically downgrade Node 5001 to `SUSPECT` and then `DEAD`!*

## How it works under the hood

- **Failure detector:** direct ping → indirect ping-req (k=3 by default) → suspect → dead
- **Dissemination:** up to 6 member updates piggybacked on every ping, ack, and ping-req
- **LHA:** health multiplier clamped 0..5, increases on timeout, decreases on success
- **Safety:** incarnation numbers prevent old gossip from resurrecting dead nodes

See `spec/swim/lifeguard_spec.cr` and `cluster_integration_spec.cr` for deterministic partition tests.

## Contributing

1. Fork it (<https://github.com/alumna/crystal-swim/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Ensure specs pass with 100% coverage (`crystal spec`)
4. Commit your changes (`git commit -am 'Add some feature'`)
5. Push to the branch (`git push origin my-new-feature`)
6. Create a new Pull Request

## License

MIT - see LICENSE
