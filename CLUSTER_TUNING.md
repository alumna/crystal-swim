# Cluster tuning

`period` is the time between probes. `timeout` is the time to wait for one ack.

A probe has two steps. The node sends a direct ping. When that ack does not arrive, the node asks other peers to ping the same target. Set `timeout` to less than half of `period`.

Example: `period` is 1 second. Set `timeout` to 500 milliseconds or less.

## Match the timeout to the network

`timeout` must be larger than the maximum round trip time, plus jitter.

A path from New York to London has a round trip time of about 90 milliseconds. A timeout of 40 milliseconds expires before the ack can return. The node then marks a live peer suspect. The peer refutes the suspicion. The cluster repeats this on every probe.

## Suggested settings

| Network | Round trip time | `timeout` | `period` |
| --- | --- | --- | --- |
| Localhost and tests | under 1 ms | 40 ms | 100 ms |
| One datacenter or LAN | 1 to 2 ms | 100 ms | 250 to 500 ms |
| One region, several zones | 2 to 10 ms | 200 ms | 500 ms to 1 second |
| Several regions | 80 to 150 ms | 500 ms | 1 to 2 seconds |
| Global | 200 to 300 ms | 1 second | 2 to 3 seconds |

Gossip needs about `log2(N) + ln(N)` probe periods to reach N nodes. The tables below use that model.

### Local network

Use this for a game server or a single datacenter with a round trip time under 2 milliseconds.

* `period`: 100 milliseconds
* `timeout`: 40 milliseconds
* Load: 10 probes per second on each node

```crystal
Swim.join("10.0.0.1:7946", seeds: ["10.0.0.2:7946"], period: 100.milliseconds, timeout: 40.milliseconds)
```

| Cluster size | Time to spread one update |
| --- | --- |
| 10 nodes | 0.6 seconds |
| 100 nodes | 1.1 seconds |
| 1,000 nodes | 1.7 seconds |
| 10,000 nodes | 2.3 seconds |

### One cloud region

Use this for several availability zones in one region. The round trip time is 2 to 10 milliseconds.

* `period`: 500 milliseconds
* `timeout`: 200 milliseconds
* Load: 2 probes per second on each node

```crystal
Swim.join("10.0.0.1:7946", seeds: ["10.0.0.2:7946"], period: 500.milliseconds, timeout: 200.milliseconds)
```

| Cluster size | Time to spread one update |
| --- | --- |
| 10 nodes | 2.8 seconds |
| 100 nodes | 5.6 seconds |
| 1,000 nodes | 8.4 seconds |
| 10,000 nodes | 11.3 seconds |
| 100,000 nodes | 14.1 seconds |

### Global network

Use this when peers are on different continents. The round trip time is 100 to 300 milliseconds.

* `period`: 2 seconds
* `timeout`: 800 milliseconds
* Load: 1 probe every 2 seconds on each node

```crystal
Swim.join("10.0.0.1:7946", seeds: ["10.0.0.2:7946"], period: 2.seconds, timeout: 800.milliseconds)
```

| Cluster size | Time to spread one update |
| --- | --- |
| 10 nodes | 11.2 seconds |
| 100 nodes | 22.6 seconds |
| 1,000 nodes | 33.8 seconds |
| 10,000 nodes | 45.0 seconds |
| 100,000 nodes | 56.2 seconds |

## Datagram size

Each datagram carries at most five peer updates. The binary packet stays under 256 bytes before sealing. AES-256-GCM adds 28 bytes. The datagram fits in one Ethernet frame. The network does not fragment it.
