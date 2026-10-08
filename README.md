# Swim

![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/alumna/crystal-swim/ci.yml) [![codecov](https://codecov.io/gh/alumna/crystal-swim/branch/master/graph/badge.svg?token=FasTA63Qyj)](https://codecov.io/gh/alumna/crystal-swim) ![Dynamic YAML Badge](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Falumna%2Fcrystal-swim%2Frefs%2Fheads%2Fmaster%2Fshard.yml&query=version&prefix=v&label=version) ![GitHub License](https://img.shields.io/github/license/alumna/backend)

Swim keeps a cluster membership list. Each node learns which peers are alive, suspect, or dead.

The protocol is [SWIM](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf). Lifeguard local health and suspicion refutation are included.

Use Swim for failure detection and peer discovery. Use Raft or Paxos when you need one agreed order for data.

### The advantage

In traditional heartbeating, network traffic grows quadratically as the cluster grows. With SWIM, each node only talks to a constant, small number of peers. The network load stays flat regardless of cluster size. Maintaining a 10,000-node cluster costs each node the same few UDP packets per second as a 10-node cluster.

## Install

Add the shard to `shard.yml`.

```yaml
dependencies:
  swim:
    github: alumna/crystal-swim
```

Run `shards install`. The shard needs Crystal 1.21 or newer. The source on this branch includes the unreleased API in the changelog. Tag `0.2.1` is the previous API.

## Use

```crystal
require "swim"

cluster = Swim.join("10.0.0.1:7946", seeds: ["10.0.0.2:7946"])

cluster.each do |peer|
  puts peer
end

cluster.stop
```

`Swim.join` binds a UDP socket and returns a `Swim::Cluster`. Call `stop` when the process leaves the cluster.

The block form stops the cluster when the block ends.

```crystal
Swim.join("10.0.0.1:7946", seeds: ["10.0.0.2:7946"]) do |cluster|
  cluster.each { |peer| puts peer }
end
```

A peer address is `host:port` or `[ipv6]:port`.

## Options

| Name | Default | Role |
| --- | --- | --- |
| `bind` | the advertise address | Local UDP address. Use `0.0.0.0:7946` to listen on all IPv4 interfaces. |
| `seeds` | none | Known peers. The node learns the rest by gossip. |
| `key` | none | Shared secret. The node seals each datagram with AES-256-GCM. |
| `period` | 1 second | Time between probes. |
| `timeout` | 500 milliseconds | Time to wait for one ack. |
| `tombstone` | 24 hours | Time to keep a dead peer before removal. |

Set `timeout` to less than half of `period`.

`period` and `timeout` for a local network, a region, and a wide area network are in [CLUSTER_TUNING.md](CLUSTER_TUNING.md).

## Detection

1. The node probes one live peer.
2. When the ack does not arrive, the node asks up to three other peers to probe that target.
3. When those probes also fail, the peer becomes suspect.
4. The next failed probe marks a suspect peer dead.
5. A peer that sees itself as suspect or dead increases its incarnation and sends alive.

Each datagram carries up to five peer updates. Dead peers stay in the list until the tombstone time ends. An old datagram cannot bring a removed peer back with an old incarnation.

The reactor runs in one concurrent execution context. Reads from your fibers take a lock.

## Hardware use

A node spends nearly all of its time asleep, waiting for the network. The CPU work for one probe is a fraction of a microsecond.

These times are from a release build. They are CPU time inside the process. Travel time on the wire comes from `period` and `timeout`.

| Work | CPU time | Memory allocated |
| --- | ---: | ---: |
| One probe and its ack | 0.55 µs | 0 |
| Encrypt and decrypt one datagram | 1.2 µs | 0 |
| Choose 5 peers from a list of 1,000 | 0.075 µs | 0 |

With the default `period` of 1 second, a node does this work once per second. That is a tiny share of one CPU core. Set `key` when you want AES-256-GCM. The extra cost is about 1.2 µs per datagram, and that path also allocates nothing.

| Peers in memory | Heap after a collection | Peak process memory |
| --- | ---: | ---: |
| 2 | 0.5 MB | 6.9 MB |
| 1,000 | 1.2 MB | 7.4 MB |

Most of that process memory is the Crystal runtime. The member list itself grows slowly: 1,000 peers use about 0.7 MB more heap than 2 peers. Probes allocate nothing, so a long run stays at this size and the GC stays quiet.

## In-memory engine

`Swim::Core` is the same protocol without sockets. Pass `now` into `tick`, `expire`, and `receive`. Specs use this to control time.

## Development

```bash
crystal spec
crystal build all_specs.cr -o bin/all_specs --debug
kcov --clean --include-path=$(pwd)/src ./coverage ./bin/all_specs
```

`src/` line coverage must stay at 100%.

## License

MIT
