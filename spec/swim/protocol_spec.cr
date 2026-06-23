require "spec"
require "../../src/swim/protocol"

describe Swim::Protocol do
  local = Swim::Member.new("A", "10.0.0.1", 1_u64, Swim::State::Alive)
  node_b = Swim::Member.new("B", "10.0.0.2", 1_u64, Swim::State::Alive)
  node_c = Swim::Member.new("C", "10.0.0.3", 1_u64, Swim::State::Alive)

  it "performs a successful direct ping" do
    members = Swim::MembershipList.new
    members.update(node_b)
    protocol = Swim::Protocol.new(local, members)

    # 1. Trigger Tick
    effects = protocol.on_tick

    send_effect = effects.find(&.is_a?(Swim::SendMessage)).as(Swim::SendMessage)
    send_effect.message.type.should eq(Swim::MessageType::Ping)
    send_effect.address.should eq("10.0.0.2")

    timeout_effect = effects.find(&.is_a?(Swim::ScheduleTimeout)).as(Swim::ScheduleTimeout)

    # 2. Simulate Node B replying with an Ack
    ack = Swim::Message.new(Swim::MessageType::Ack, send_effect.message.seq, "B", "10.0.0.2")
    effects_from_ack = protocol.on_message(ack)
    effects_from_ack.should be_empty

    # 3. Trigger Timeout (should be a no-op because the Ack arrived)
    effects_from_timeout = protocol.on_timeout(timeout_effect.seq, timeout_effect.type)
    effects_from_timeout.should be_empty

    members.get("B").try(&.state).should eq(Swim::State::Alive)
  end

  it "fails direct ping, utilizes ping-req proxy, and recovers" do
    members = Swim::MembershipList.new
    # ONLY add node B initially so we deterministically target it
    members.update(node_b)
    protocol_a = Swim::Protocol.new(local, members)

    # 1. Tick initiates direct Ping to B
    tick_effects = protocol_a.on_tick
    ping_msg = tick_effects.find(&.is_a?(Swim::SendMessage)).as(Swim::SendMessage).message
    timeout_seq = ping_msg.seq

    # NOW add node C, so it is the only available candidate for the indirect proxy
    members.update(node_c)

    # 2. Direct ping times out (simulating network drop between A and B)
    indirect_effects = protocol_a.on_timeout(timeout_seq, Swim::TimeoutType::DirectPing)

    # A should now send a PingReq to C
    ping_req_effect = indirect_effects.find(&.is_a?(Swim::SendMessage)).as(Swim::SendMessage)
    ping_req_effect.address.should eq("10.0.0.3")
    ping_req_effect.message.type.should eq(Swim::MessageType::PingReq)
    ping_req_effect.message.target_id.should eq("B")

    # 3. Now simulate Node C receiving the PingReq
    protocol_c = Swim::Protocol.new(node_c, Swim::MembershipList.new)
    c_effects = protocol_c.on_message(ping_req_effect.message)

    # C sends a Ping to B
    c_ping = c_effects.find(&.is_a?(Swim::SendMessage)).as(Swim::SendMessage)
    c_ping.address.should eq("10.0.0.2")

    # 4. Simulate B replying Ack to C
    b_ack = Swim::Message.new(Swim::MessageType::Ack, c_ping.message.seq, "B", "10.0.0.2")
    c_ack_effects = protocol_c.on_message(b_ack)

    # C forwards the Ack to A
    c_forwarded_ack = c_ack_effects.find(&.is_a?(Swim::SendMessage)).as(Swim::SendMessage)
    c_forwarded_ack.address.should eq("10.0.0.1")
    c_forwarded_ack.message.target_id.should eq("B")

    # 5. A receives the forwarded Ack from C
    final_effects = protocol_a.on_message(c_forwarded_ack.message)
    final_effects.should be_empty

    # Assert A still sees B as Alive
    members.get("B").try(&.state).should eq(Swim::State::Alive)
  end

  it "marks node suspect if indirect probe also fails" do
    members = Swim::MembershipList.new
    members.update(node_b)
    protocol = Swim::Protocol.new(local, members)

    tick_effects = protocol.on_tick
    seq = tick_effects.find(&.is_a?(Swim::SendMessage)).as(Swim::SendMessage).message.seq

    # Direct fails
    protocol.on_timeout(seq, Swim::TimeoutType::DirectPing)

    # Indirect fails
    protocol.on_timeout(seq, Swim::TimeoutType::IndirectPingReq)

    members.get("B").try(&.state).should eq(Swim::State::Suspect)
  end

  it "transitions from suspect to dead on subsequent failure" do
    members = Swim::MembershipList.new

    # Force node B to start as Suspect
    suspect_b = node_b.copy_with(state: Swim::State::Suspect)
    members.update(suspect_b)

    protocol = Swim::Protocol.new(local, members)
    tick_effects = protocol.on_tick
    seq = tick_effects.find(&.is_a?(Swim::SendMessage)).as(Swim::SendMessage).message.seq

    # Direct fails
    protocol.on_timeout(seq, Swim::TimeoutType::DirectPing)

    # Indirect fails
    protocol.on_timeout(seq, Swim::TimeoutType::IndirectPingReq)

    # Because it was already Suspect, it is now Dead!
    members.get("B").try(&.state).should eq(Swim::State::Dead)
  end

  it "triggers tombstone garbage collection periodically" do
    members = Swim::MembershipList.new
    # Setting a 0 TTL so any Dead node gets collected immediately on GC
    protocol = Swim::Protocol.new(local, members, tombstone_ttl: 0.seconds)

    members.update(Swim::Member.new("DEAD_NODE", "10.0.0.99", 1_u64, Swim::State::Dead))
    members.size.should eq(2) # local + dead

    # Force ticks up to the periodic GC threshold
    60.times { protocol.on_tick }

    members.size.should eq(1)
    members.get("DEAD_NODE").should be_nil
  end
end
