require "spec"
require "../../src/swim/protocol"

describe "Lifeguard Extensions" do
  describe "Suspicion Refutation" do
    it "increments incarnation and refutes when a node receives gossip that it is suspect" do
      local_b = Swim::Member.new("B", "10.0.0.2", 1_u64, Swim::State::Alive)
      list_b = Swim::MembershipList.new
      protocol_b = Swim::Protocol.new(local_b, list_b)

      suspected_b = local_b.copy_with(state: Swim::State::Suspect)
      msg_from_a = Swim::Message.new(Swim::MessageType::Ping, 1_u64, "A", "10.0.0.1", changes: [suspected_b])

      effects = protocol_b.on_message(msg_from_a)

      protocol_b.local_member.incarnation.should eq(2_u64)
      protocol_b.local_member.state.should eq(Swim::State::Alive)

      ack_effect = effects.find(&.is_a?(Swim::SendMessage)).as(Swim::SendMessage)
      ack_effect.message.type.should eq(Swim::MessageType::Ack)

      # We search the gossip payload specifically for the rebuttal (Incarnation 2)
      rebuttal_gossip = ack_effect.message.changes.find { |m| m.incarnation == 2_u64 }

      rebuttal_gossip.should_not be_nil
      rebuttal_gossip.try(&.id).should eq("B")
      rebuttal_gossip.try(&.state).should eq(Swim::State::Alive)
    end

    it "increments incarnation and refutes when a node receives gossip that it is DEAD" do
      local_b = Swim::Member.new("B", "10.0.0.2", 1_u64, Swim::State::Alive)
      protocol_b = Swim::Protocol.new(local_b, Swim::MembershipList.new)

      dead_b = local_b.copy_with(state: Swim::State::Dead)
      msg = Swim::Message.new(Swim::MessageType::Ping, 1_u64, "A", "10.0.0.1", changes: [dead_b])

      protocol_b.on_message(msg)

      protocol_b.local_member.incarnation.should eq(2_u64)
      protocol_b.local_member.state.should eq(Swim::State::Alive)
    end
  end

  describe "Local Health Awareness" do
    it "dynamically scales timeouts when local health degrades and recovers" do
      local = Swim::Member.new("A", "10.0.0.1", 1_u64, Swim::State::Alive)
      node_b = Swim::Member.new("B", "10.0.0.2", 1_u64, Swim::State::Alive)

      list = Swim::MembershipList.new
      list.update(node_b)

      protocol = Swim::Protocol.new(local, list)

      # Ensure baseline health is perfect (multiplier 0 means 500ms timeouts)
      protocol.local_health_multiplier.should eq(0)

      # 1. Simulate a completely failed probe to B
      tick_effects = protocol.on_tick
      seq = tick_effects.find(&.is_a?(Swim::ScheduleTimeout)).as(Swim::ScheduleTimeout).seq

      protocol.on_timeout(seq, Swim::TimeoutType::DirectPing)
      protocol.on_timeout(seq, Swim::TimeoutType::IndirectPingReq)

      # Health should now be degraded
      protocol.local_health_multiplier.should eq(1)

      # 2. Check the duration of the NEXT tick
      # Because multiplier is 1, the timeout should be 500ms * (1 + 1) = 1000ms
      list.update(Swim::Member.new("C", "10.0.0.3", 1_u64, Swim::State::Alive)) # Add node C to tick
      next_tick_effects = protocol.on_tick
      next_timeout = next_tick_effects.find(&.is_a?(Swim::ScheduleTimeout)).as(Swim::ScheduleTimeout)

      next_timeout.duration.should eq(1000.milliseconds)

      # 3. Simulate a successful probe to recover health
      ack = Swim::Message.new(Swim::MessageType::Ack, next_timeout.seq, "C", "10.0.0.3")
      protocol.on_message(ack)

      # Health should recover back to 0
      protocol.local_health_multiplier.should eq(0)
    end
  end
end
