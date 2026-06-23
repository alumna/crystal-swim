require "spec"
require "../../src/swim/node"

describe "SWIM Cluster Integration" do
  it "discovers nodes, detects sudden failure, and safely transitions a node to DEAD" do
    member_a = Swim::Member.new("A", "127.0.0.1:5010", 1_u64, Swim::State::Alive)
    member_b = Swim::Member.new("B", "127.0.0.1:5011", 1_u64, Swim::State::Alive)
    member_c = Swim::Member.new("C", "127.0.0.1:5012", 1_u64, Swim::State::Alive)

    list_a = Swim::MembershipList.new
    list_b = Swim::MembershipList.new
    list_c = Swim::MembershipList.new

    # Seed with the actual target IDs but Incarnation 0.
    # Real gossip (Inc 1) will seamlessly overwrite them.
    list_b.update(Swim::Member.new("A", "127.0.0.1:5010", 0_u64, Swim::State::Alive))
    list_c.update(Swim::Member.new("B", "127.0.0.1:5011", 0_u64, Swim::State::Alive))

    # Configure the protocol to use lightning-fast 50ms timeouts for the test
    fast_timeout = 50.milliseconds
    protocol_a = Swim::Protocol.new(member_a, list_a, base_timeout: fast_timeout)
    protocol_b = Swim::Protocol.new(member_b, list_b, base_timeout: fast_timeout)
    protocol_c = Swim::Protocol.new(member_c, list_c, base_timeout: fast_timeout)

    node_a = Swim::Node.new(protocol_a, "127.0.0.1", 5010)
    node_b = Swim::Node.new(protocol_b, "127.0.0.1", 5011)
    node_c = Swim::Node.new(protocol_c, "127.0.0.1", 5012)

    begin
      # Start the cluster with lightning-fast 50ms ticks
      fast_tick = 50.milliseconds
      node_a.start(tick_interval: fast_tick)
      node_b.start(tick_interval: fast_tick)
      node_c.start(tick_interval: fast_tick)

      # Give the cluster 200ms to fully discover each other
      sleep 200.milliseconds

      # Assert full cluster discovery (Exactly 3 nodes, no ghost seeds!)
      list_a.size.should eq(3)
      list_a.get("B").try(&.state).should eq(Swim::State::Alive)
      list_a.get("C").try(&.state).should eq(Swim::State::Alive)

      # SIMULATE HARD HARDWARE CRASH ON NODE C
      node_c.stop

      # Wait for the cluster to declare C dead.
      # Math:
      # - Tick + Direct (50) + Indirect (50) = ~100ms -> SUSPECT
      # - Next Tick + Direct (50*health) + Indirect (50*health) = ~200ms -> DEAD
      # Sleeping 400ms is perfectly safe and fast.
      sleep 400.milliseconds

      final_state_c = list_a.get("C")
      final_state_c.should_not be_nil
      final_state_c.try(&.state).should eq(Swim::State::Dead)

      list_b.get("C").try(&.state).should eq(Swim::State::Dead)
    ensure
      node_a.stop
      node_b.stop
      node_c.stop
    end
  end
end
