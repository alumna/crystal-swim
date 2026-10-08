require "../spec_helper"

describe Swim::Core do
  t0 = Time.instant

  it "rejects a non-positive timeout" do
    expect_raises(ArgumentError) do
      Swim::Core.new(SwimSpec.at(1), timeout: 0.seconds)
    end
  end

  it "uses default arguments" do
    core = Swim::Core.new(SwimSpec.at(1))
    core.size.should eq(1)
    core.incarnation.should eq(1)
    core.health.should eq(0)
    core.alive?(SwimSpec.at(1)).should be_true
    core.alive?(SwimSpec.at(2)).should be_false
    core.pending.should eq(0)
  end

  it "completes a direct ping when the ack arrives" do
    left = SwimSpec.core(1, now: t0)
    right = SwimSpec.core(2, now: t0)
    left.add(SwimSpec.at(2), 1_u64, Swim::Status::Alive, t0)

    left.tick(t0) do |endpoint, bytes|
      endpoint.should eq(SwimSpec.at(2))
      right.receive(bytes, t0) do |reply_to, reply|
        reply_to.should eq(SwimSpec.at(1))
        left.receive(reply, t0) { fail "ack must not create another packet" }
      end
    end

    left.pending.should eq(0)
    left.health.should eq(0)
    peer = left.get(SwimSpec.at(2))
    peer.should_not be_nil
    peer.try(&.alive?).should be_true
    right.size.should eq(2)
  end

  it "recovers through an indirect probe" do
    left = SwimSpec.core(1, now: t0)
    helper = SwimSpec.core(3, now: t0)
    target = SwimSpec.core(2, now: t0)
    left.add(SwimSpec.at(2), 1_u64, Swim::Status::Alive, t0)

    ping = Bytes.new(0)
    left.tick(t0) { |_, bytes| ping = bytes.dup }
    left.pending.should eq(1)

    left.add(SwimSpec.at(3), 1_u64, Swim::Status::Alive, t0)
    requests = [] of {Swim::Endpoint, Bytes}
    left.expire(t0 + 100.milliseconds) { |endpoint, bytes| requests << {endpoint, bytes.dup} }
    requests.size.should eq(1)
    requests[0][0].should eq(SwimSpec.at(3))

    view = Swim::Wire.view?(requests[0][1])
    view.should_not be_nil
    view.try(&.type).should eq(Swim::Wire::PING_REQ)
    view.try(&.target).should eq(SwimSpec.at(2))

    forwarded = [] of {Swim::Endpoint, Bytes}
    helper.receive(requests[0][1], t0) do |endpoint, bytes|
      target.receive(bytes, t0) do |reply_to, reply|
        helper.receive(reply, t0) { |origin, ack| forwarded << {origin, ack.dup} }
        reply_to.should eq(SwimSpec.at(3))
      end
    end

    forwarded.size.should eq(1)
    forwarded[0][0].should eq(SwimSpec.at(1))
    left.receive(forwarded[0][1], t0) { fail "origin ack is terminal" }
    left.expire(t0 + 1.second) { fail "the probe is already done" }
    left.get(SwimSpec.at(2)).try(&.alive?).should be_true
    left.health.should eq(0)
  end

  it "marks a peer suspect and then dead" do
    core = SwimSpec.core(1, now: t0)
    core.add(SwimSpec.at(2), 1_u64, Swim::Status::Alive, t0)
    core.tick(t0) { }
    core.expire(t0 + 100.milliseconds) { }
    core.expire(t0 + 200.milliseconds) { }
    core.get(SwimSpec.at(2)).try(&.suspect?).should be_true
    core.health.should eq(1)
    core.timeout_span.should eq(200.milliseconds)

    core.tick(t0 + 200.milliseconds) { }
    core.expire(t0 + 400.milliseconds) { }
    core.get(SwimSpec.at(2)).try(&.suspect?).should be_true
    core.expire(t0 + 600.milliseconds) { }
    core.get(SwimSpec.at(2)).try(&.dead?).should be_true
    core.health.should eq(2)
  end

  it "does not fire a scaled timeout early" do
    core = SwimSpec.core(1, now: t0, timeout: 100.milliseconds)
    core.add(SwimSpec.at(2), 1_u64, Swim::Status::Alive, t0)
    core.tick(t0) { }
    core.expire(t0 + 100.milliseconds) { }
    core.expire(t0 + 200.milliseconds) { }
    core.health.should eq(1)
    core.get(SwimSpec.at(2)).try(&.suspect?).should be_true

    later = t0 + 1.second
    core.tick(later) { }
    core.expire(later + 199.milliseconds) { }
    core.pending.should eq(1)
    core.get(SwimSpec.at(2)).try(&.suspect?).should be_true
    core.expire(later + 200.milliseconds) { }
    core.pending.should eq(1)
    core.expire(later + 400.milliseconds) { }
    core.get(SwimSpec.at(2)).try(&.dead?).should be_true
  end

  it "clamps local health" do
    core = SwimSpec.core(1, now: t0, timeout: 10.milliseconds)
    core.add(SwimSpec.at(2), 1_u64, Swim::Status::Alive, t0)
    now = t0
    incarnation = 1_u64
    6.times do
      # A higher incarnation puts the peer back to Alive so the next probe can fail.
      core.add(SwimSpec.at(2), incarnation, Swim::Status::Alive, now)
      incarnation &+= 1
      core.tick(now) { }
      span = core.timeout_span
      core.expire(now + span) { }
      core.expire(now + span + span) { }
      now += span + span + 1.millisecond
    end
    core.health.should eq(5)

    other = SwimSpec.core(2, now: now)
    core.tick(now) do |_, bytes|
      other.receive(bytes, now) do |_, reply|
        core.receive(reply, now) { }
      end
    end
    core.health.should eq(4)
  end

  it "refutes suspect and dead gossip about itself" do
    node = SwimSpec.core(2, now: t0, incarnation: 5_u64)
    suspect = Bytes.new(Swim::Wire::MAX_BYTES)
    Swim::Wire.open(suspect, Swim::Wire::PING, 1_u64, SwimSpec.at(1), Swim::Endpoint.zero)
    Swim::Wire.store(suspect, 0, SwimSpec.at(2), 5_u64, Swim::Status::Suspect)
    node.receive(suspect[0, Swim::Wire.bytes(1)], t0) { }
    node.incarnation.should eq(6)
    node.get(SwimSpec.at(2)).try(&.alive?).should be_true

    dead = Bytes.new(Swim::Wire::MAX_BYTES)
    Swim::Wire.open(dead, Swim::Wire::PING, 2_u64, SwimSpec.at(1), Swim::Endpoint.zero)
    Swim::Wire.store(dead, 0, SwimSpec.at(2), 6_u64, Swim::Status::Dead)
    node.receive(dead[0, Swim::Wire.bytes(1)], t0) do |_, reply|
      view = Swim::Wire.view?(reply)
      view.should_not be_nil
      found = false
      if view
        view.changes.times do |index|
          endpoint, incarnation, status = Swim::Wire.change(reply, index)
          next unless endpoint == SwimSpec.at(2)
          found = true
          incarnation.should eq(7)
          status.should eq(Swim::Status::Alive)
        end
      end
      found.should be_true
    end
  end

  it "ignores alive gossip about itself and stale gossip about others" do
    core = SwimSpec.core(1, now: t0, incarnation: 3_u64)
    packet = Bytes.new(Swim::Wire::MAX_BYTES)
    Swim::Wire.open(packet, Swim::Wire::ACK, 9_u64, SwimSpec.at(2), Swim::Endpoint.zero)
    Swim::Wire.store(packet, 0, SwimSpec.at(1), 9_u64, Swim::Status::Alive)
    Swim::Wire.store(packet, 1, SwimSpec.at(4), 1_u64, Swim::Status::Alive)
    core.receive(packet[0, Swim::Wire.bytes(2)], t0) { }
    core.incarnation.should eq(3)
    core.get(SwimSpec.at(4)).try(&.incarnation).should eq(1)

    core.add(SwimSpec.at(4), 1_u64, Swim::Status::Dead, t0 + 1.second)
    core.get(SwimSpec.at(4)).try(&.dead?).should be_true
    updated = core.get(SwimSpec.at(4)).try(&.updated)
    core.add(SwimSpec.at(4), 1_u64, Swim::Status::Dead, t0 + 2.seconds)
    core.get(SwimSpec.at(4)).try(&.updated).should eq(updated)

    core.add(SwimSpec.at(4), 2_u64, Swim::Status::Alive, t0 + 3.seconds)
    core.get(SwimSpec.at(4)).try(&.alive?).should be_true
    core.get(SwimSpec.at(4)).try(&.incarnation).should eq(2)
  end

  it "drops a bad packet, an empty target, and an ack with an unknown sequence" do
    core = SwimSpec.core(1, now: t0)
    core.receive(Bytes.new(8), t0) { fail "bad packet" }.should be_false
    core.receive(Bytes.new(4), t0) { }.should be_false

    packet = Bytes.new(Swim::Wire::MAX_BYTES)
    Swim::Wire.open(packet, Swim::Wire::PING_REQ, 1_u64, SwimSpec.at(2), Swim::Endpoint.zero)
    Swim::Wire.store(packet, 0, SwimSpec.at(2), 1_u64, Swim::Status::Alive)
    core.receive(packet[0, Swim::Wire.bytes(1)], t0) { fail "no target" }
    core.pending.should eq(0)

    Swim::Wire.open(packet, Swim::Wire::ACK, 99_u64, SwimSpec.at(2), Swim::Endpoint.zero)
    Swim::Wire.store(packet, 0, SwimSpec.at(2), 1_u64, Swim::Status::Alive)
    core.receive(packet[0, Swim::Wire.bytes(1)], t0) { fail "unknown ack" }
    core.health.should eq(0)
  end

  it "drops a proxy request when every probe slot is full" do
    helper = SwimSpec.core(3, now: t0)
    packet = Bytes.new(Swim::Wire::MAX_BYTES)
    Swim::Wire.open(packet, Swim::Wire::PING_REQ, 1_u64, SwimSpec.at(1), SwimSpec.at(2))
    Swim::Wire.store(packet, 0, SwimSpec.at(1), 1_u64, Swim::Status::Alive)
    bytes = packet[0, Swim::Wire.bytes(1)]
    64.times { helper.receive(bytes, t0) { } }
    helper.pending.should eq(64)
    helper.receive(bytes, t0) { fail "no free probe slot" }
    helper.pending.should eq(64)
    helper.expire(t0 + 1.second) { }
    helper.pending.should eq(0)
    helper.health.should eq(0)
  end

  it "releases a direct probe when the target is gone" do
    core = SwimSpec.core(1, now: t0, timeout: 1.hour, tombstone: 0.seconds)
    core.add(SwimSpec.at(2), 1_u64, Swim::Status::Alive, t0)
    core.tick(t0) { }
    core.add(SwimSpec.at(2), 1_u64, Swim::Status::Dead, t0)
    59.times { |index| core.tick(t0 + index.seconds) { } }
    core.get(SwimSpec.at(2)).should be_nil
    core.expire(t0 + 2.hours) { fail "missing target" }
    core.pending.should eq(0)
    core.health.should eq(0)
  end

  it "degrades health when an indirect probe loses its target" do
    core = SwimSpec.core(1, now: t0, timeout: 1.hour, tombstone: 0.seconds)
    core.add(SwimSpec.at(2), 1_u64, Swim::Status::Alive, t0)
    core.tick(t0) { }
    core.expire(t0 + 1.hour) { }
    core.add(SwimSpec.at(2), 1_u64, Swim::Status::Dead, t0)
    59.times { |index| core.tick(t0 + index.seconds) { } }
    core.get(SwimSpec.at(2)).should be_nil
    core.expire(t0 + 3.hours) { }
    core.health.should eq(1)
    core.pending.should eq(0)
  end

  it "removes expired tombstones and keeps fresh ones" do
    fresh = SwimSpec.core(1, now: t0, tombstone: 1.hour)
    fresh.add(SwimSpec.at(9), 1_u64, Swim::Status::Dead, t0)
    fresh.add(SwimSpec.at(8), 1_u64, Swim::Status::Suspect, t0)
    60.times { |index| fresh.tick(t0 + index.seconds) { } }
    fresh.get(SwimSpec.at(9)).should_not be_nil
    fresh.get(SwimSpec.at(8)).should_not be_nil

    stale = SwimSpec.core(1, now: t0, tombstone: 0.seconds)
    stale.add(SwimSpec.at(9), 1_u64, Swim::Status::Dead, t0)
    59.times { stale.tick(t0) { } }
    stale.get(SwimSpec.at(9)).should_not be_nil
    stale.tick(t0) { }
    stale.get(SwimSpec.at(9)).should be_nil
    stale.size.should eq(1)
  end

  it "does not tick when the only other peers are dead" do
    core = SwimSpec.core(1, now: t0)
    core.add(SwimSpec.at(2), 1_u64, Swim::Status::Dead, t0)
    core.tick(t0) { fail "dead peer is not a probe target" }
    core.pending.should eq(0)
    deadlines = 0
    core.each_deadline { deadlines += 1 }
    deadlines.should eq(0)
    peers = 0
    core.each { peers += 1 }
    peers.should eq(2)
  end

  it "converges a line of nodes, detects death, and accepts a rejoin" do
    nodes = {} of UInt16 => Swim::Core
    7.times do |index|
      port = (5000 + index).to_u16
      nodes[port] = SwimSpec.core(port.to_i, now: t0, timeout: 20.milliseconds, seed: index + 1)
    end
    (1..6).each do |index|
      nodes[(5000 + index).to_u16].add(SwimSpec.at(5000 + index - 1), 0_u64, Swim::Status::Alive, t0)
    end

    now = t0
    80.times do |round|
      now += 10.milliseconds
      exchange(nodes, now, expire: true, tick: round.even?)
    end

    nodes[5000_u16].size.should eq(7)
    nodes[5006_u16].size.should eq(7)
    nodes[5000_u16].get(SwimSpec.at(5004)).try(&.alive?).should be_true

    nodes.delete(5004_u16)
    40.times do |round|
      now += 10.milliseconds
      exchange(nodes, now, expire: true, tick: round.even?)
    end
    nodes[5000_u16].get(SwimSpec.at(5004)).try(&.dead?).should be_true
    nodes[5006_u16].get(SwimSpec.at(5004)).try(&.dead?).should be_true

    reborn = SwimSpec.core(5004, now: now, timeout: 20.milliseconds, incarnation: 2_u64, seed: 9)
    reborn.add(SwimSpec.at(5003), 0_u64, Swim::Status::Alive, now)
    nodes[5004_u16] = reborn
    80.times do |round|
      now += 10.milliseconds
      exchange(nodes, now, expire: true, tick: round.even?)
    end
    nodes[5000_u16].get(SwimSpec.at(5004)).try(&.alive?).should be_true
    nodes[5000_u16].get(SwimSpec.at(5004)).try(&.incarnation).should eq(2)
  end
end

def exchange(nodes : Hash(UInt16, Swim::Core), now : Time::Instant, *, expire : Bool, tick : Bool) : Nil
  queue = [] of {Swim::Endpoint, Bytes}
  nodes.each_value do |node|
    node.expire(now) { |endpoint, bytes| queue << {endpoint, bytes.dup} } if expire
  end
  deliver(nodes, now, queue)
  return unless tick
  queue.clear
  nodes.each_value do |node|
    node.tick(now) { |endpoint, bytes| queue << {endpoint, bytes.dup} }
  end
  deliver(nodes, now, queue)
end

def deliver(nodes : Hash(UInt16, Swim::Core), now : Time::Instant, queue : Array({Swim::Endpoint, Bytes})) : Nil
  index = 0
  while index < queue.size
    endpoint, bytes = queue[index]
    index += 1
    if node = nodes[endpoint.port]?
      node.receive(bytes, now) do |reply_to, reply|
        queue << {reply_to, reply.dup}
      end
    end
  end
end
