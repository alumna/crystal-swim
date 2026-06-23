require "spec"
require "../../src/swim/node"

describe "SWIM Cluster Integration" do
  fast_tick = 50.milliseconds

  it "3 Nodes: discovers nodes, detects sudden failure, and safely transitions a node to DEAD" do
    member_a = Swim::Member.new("A", "127.0.0.1:5010", 1_u64, Swim::State::Alive)
    member_b = Swim::Member.new("B", "127.0.0.1:5011", 1_u64, Swim::State::Alive)
    member_c = Swim::Member.new("C", "127.0.0.1:5012", 1_u64, Swim::State::Alive)

    list_a = Swim::MembershipList.new
    list_b = Swim::MembershipList.new
    list_c = Swim::MembershipList.new

    list_b.update(Swim::Member.new("A", "127.0.0.1:5010", 0_u64, Swim::State::Alive))
    list_c.update(Swim::Member.new("B", "127.0.0.1:5011", 0_u64, Swim::State::Alive))

    protocol_a = Swim::Protocol.new(member_a, list_a, base_timeout: fast_tick)
    protocol_b = Swim::Protocol.new(member_b, list_b, base_timeout: fast_tick)
    protocol_c = Swim::Protocol.new(member_c, list_c, base_timeout: fast_tick)

    node_a = Swim::Node.new(protocol_a, "127.0.0.1", 5010)
    node_b = Swim::Node.new(protocol_b, "127.0.0.1", 5011)
    node_c = Swim::Node.new(protocol_c, "127.0.0.1", 5012)

    begin
      node_a.start(tick_interval: fast_tick)
      node_b.start(tick_interval: fast_tick)
      node_c.start(tick_interval: fast_tick)

      sleep 200.milliseconds

      list_a.size.should eq(3)
      list_a.get("C").try(&.state).should eq(Swim::State::Alive)

      # SIMULATE CRASH
      node_c.stop

      # Wait for failure detection (Direct + Indirect + Health scaling)
      sleep 400.milliseconds

      list_a.get("C").try(&.state).should eq(Swim::State::Dead)
    ensure
      node_a.stop
      node_b.stop
      node_c.stop
    end
  end

  it "5 Nodes: handles multi-hop discovery, node death, and successful cluster rejoin" do
    ports = (5020..5024).to_a
    members = ports.map_with_index { |p, i| Swim::Member.new("N#{i}", "127.0.0.1:#{p}", 1_u64, Swim::State::Alive) }
    lists = ports.map { Swim::MembershipList.new }

    # Star topology: Nodes 1-4 use Node 0 as their seed.
    (1..4).each do |i|
      lists[i].update(Swim::Member.new("N0", "127.0.0.1:5020", 0_u64, Swim::State::Alive))
    end

    protocols = (0..4).map { |i| Swim::Protocol.new(members[i], lists[i], base_timeout: fast_tick) }
    nodes = (0..4).map { |i| Swim::Node.new(protocols[i], "127.0.0.1", ports[i]) }

    begin
      nodes.each(&.start(tick_interval: fast_tick))

      # 1. Wait for discovery
      sleep 300.milliseconds
      lists[0].size.should eq(5)
      lists[0].get("N2").try(&.state).should eq(Swim::State::Alive)

      # 2. Kill Node N2 (Port 5022)
      nodes[2].stop

      # Wait for failure detection to propagate across 5 nodes
      sleep 600.milliseconds
      lists[0].get("N2").try(&.state).should eq(Swim::State::Dead)

      # 3. REBOOT N2
      # We instantiate a fresh node with Incarnation 2 to mathematically override the tombstone.
      new_member_2 = Swim::Member.new("N2", "127.0.0.1:5022", 2_u64, Swim::State::Alive)
      new_list_2 = Swim::MembershipList.new
      new_list_2.update(Swim::Member.new("N0", "127.0.0.1:5020", 0_u64, Swim::State::Alive)) # Re-seed to N0

      new_protocol_2 = Swim::Protocol.new(new_member_2, new_list_2, base_timeout: fast_tick)
      new_node_2 = Swim::Node.new(new_protocol_2, "127.0.0.1", 5022)

      # Swap the node reference so the ensure block cleans it up later
      nodes[2] = new_node_2
      new_node_2.start(tick_interval: fast_tick)

      # Wait for the cluster to accept the rebooted node
      sleep 300.milliseconds

      # Verify N2 is Alive and its incarnation is successfully updated across the cluster!
      lists[0].get("N2").try(&.state).should eq(Swim::State::Alive)
      lists[0].get("N2").try(&.incarnation).should eq(2_u64)
    ensure
      nodes.each(&.stop)
    end
  end

  it "7 Nodes: ensures piggyback MTU limits don't prevent full cluster convergence and recovery" do
    # Because @max_piggyback_size is 5, a 7-node cluster proves that
    # multi-packet randomized gossip successfully converges the entire state!
    ports = (5030..5036).to_a
    members = ports.map_with_index { |p, i| Swim::Member.new("N#{i}", "127.0.0.1:#{p}", 1_u64, Swim::State::Alive) }
    lists = ports.map { Swim::MembershipList.new }

    # Linear topology (A->B->C...) to heavily test multi-hop gossip limits
    (1..6).each do |i|
      lists[i].update(Swim::Member.new("N#{i - 1}", "127.0.0.1:#{ports[i - 1]}", 0_u64, Swim::State::Alive))
    end

    protocols = (0..6).map { |i| Swim::Protocol.new(members[i], lists[i], base_timeout: fast_tick) }
    nodes = (0..6).map { |i| Swim::Node.new(protocols[i], "127.0.0.1", ports[i]) }

    begin
      nodes.each(&.start(tick_interval: fast_tick))

      # Give the 7 nodes slightly longer to distribute 7 states 5 at a time
      sleep 400.milliseconds

      lists[0].size.should eq(7)
      lists[6].size.should eq(7) # Prove the ends of the linear chain know each other
      lists[0].get("N4").try(&.state).should eq(Swim::State::Alive)

      # Kill Node N4
      nodes[4].stop

      sleep 800.milliseconds
      lists[0].get("N4").try(&.state).should eq(Swim::State::Dead)
      lists[6].get("N4").try(&.state).should eq(Swim::State::Dead)

      # Reboot N4
      new_member_4 = Swim::Member.new("N4", "127.0.0.1:5034", 2_u64, Swim::State::Alive)
      new_list_4 = Swim::MembershipList.new
      new_list_4.update(Swim::Member.new("N3", "127.0.0.1:5033", 0_u64, Swim::State::Alive))

      new_protocol_4 = Swim::Protocol.new(new_member_4, new_list_4, base_timeout: fast_tick)
      new_node_4 = Swim::Node.new(new_protocol_4, "127.0.0.1", 5034)

      nodes[4] = new_node_4
      new_node_4.start(tick_interval: fast_tick)

      sleep 400.milliseconds

      lists[0].get("N4").try(&.state).should eq(Swim::State::Alive)
      lists[0].get("N4").try(&.incarnation).should eq(2_u64)
    ensure
      nodes.each(&.stop)
    end
  end
end
