require "spec"
require "../../src/swim/node"

describe "SWIM Cluster Integration" do
  it "discovers nodes, detects sudden failure, and safely transitions a node to DEAD" do
    # 1. Define the members
    member_a = Swim::Member.new("A", "127.0.0.1:5010", 1_u64, Swim::State::Alive)
    member_b = Swim::Member.new("B", "127.0.0.1:5011", 1_u64, Swim::State::Alive)
    member_c = Swim::Member.new("C", "127.0.0.1:5012", 1_u64, Swim::State::Alive)

    # 2. Initialize the lists
    list_a = Swim::MembershipList.new
    list_b = Swim::MembershipList.new
    list_c = Swim::MembershipList.new

    # A boots alone. B joins via A. C joins via B. (Just like our manual test!)
    list_b.update(Swim::Member.new("seed", "127.0.0.1:5010", 0_u64, Swim::State::Alive))
    list_c.update(Swim::Member.new("seed", "127.0.0.1:5011", 0_u64, Swim::State::Alive))

    # 3. Create Protocols
    protocol_a = Swim::Protocol.new(member_a, list_a)
    protocol_b = Swim::Protocol.new(member_b, list_b)
    protocol_c = Swim::Protocol.new(member_c, list_c)

    # 4. Create Nodes
    node_a = Swim::Node.new(protocol_a, "127.0.0.1", 5010)
    node_b = Swim::Node.new(protocol_b, "127.0.0.1", 5011)
    node_c = Swim::Node.new(protocol_c, "127.0.0.1", 5012)

    begin
      # 5. Start the cluster (Tick very fast so they chat constantly)
      node_a.start(tick_interval: 100.milliseconds)
      node_b.start(tick_interval: 100.milliseconds)
      node_c.start(tick_interval: 100.milliseconds)

      # Give the cluster 1 second to fully discover each other via gossip
      sleep 1.second

      # Assert full cluster discovery
      list_a.size.should eq(3)
      list_a.get("B").try(&.state).should eq(Swim::State::Alive)
      list_a.get("C").try(&.state).should eq(Swim::State::Alive)

      # 6. SIMULATE HARD HARDWARE CRASH ON NODE C
      node_c.stop

      # 7. Wait for the cluster to declare C dead.
      # The math:
      # - First tick failure (Direct 500ms + Indirect 500ms) = ~1.0s -> transitions to SUSPECT
      # - Next tick failure (Direct 500ms*health + Indirect 500ms*health) = ~1.5s -> transitions to DEAD
      # We sleep for 3.5 seconds to comfortably cover the full cycle and CPU jitter.
      sleep 3.5.seconds

      # 8. Assert that Node A successfully identified the crash and marked C as DEAD!
      final_state_c = list_a.get("C")
      final_state_c.should_not be_nil
      final_state_c.try(&.state).should eq(Swim::State::Dead)

      # Ensure Node B also learned about it
      list_b.get("C").try(&.state).should eq(Swim::State::Dead)
    ensure
      # Safely close all sockets even if assertions fail
      node_a.stop
      node_b.stop
      node_c.stop
    end
  end
end
