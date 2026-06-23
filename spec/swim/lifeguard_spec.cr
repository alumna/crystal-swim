require "spec"
require "../../src/swim/protocol"

describe "Lifeguard Extensions" do
  describe "Suspicion Refutation" do
    it "increments incarnation and refutes when a node receives gossip that it is suspect" do
      # Node B starts with incarnation 1
      local_b = Swim::Member.new("B", "10.0.0.2", 1_u64, Swim::State::Alive)
      list_b = Swim::MembershipList.new
      protocol_b = Swim::Protocol.new(local_b, list_b)

      # 1. Someone sends B a message containing gossip that B is Suspect
      # (Maybe A had a network blip and suspected B, then gossiped it to B directly)
      suspected_b = local_b.copy_with(state: Swim::State::Suspect)
      msg_from_a = Swim::Message.new(Swim::MessageType::Ping, 1_u64, "A", "10.0.0.1", changes: [suspected_b])

      # Node B processes the incoming message
      effects = protocol_b.on_message(msg_from_a)

      # 2. Node B should have updated its internal state to refute the suspicion
      protocol_b.local_member.incarnation.should eq(2_u64)
      protocol_b.local_member.state.should eq(Swim::State::Alive)

      # The updated local member should be safely stored in the MembershipList
      protocol_b.members.get("B").try(&.incarnation).should eq(2_u64)

      # 3. Node B replies to the Ping with an Ack.
      # This Ack MUST contain the rebuttal gossip!
      ack_effect = effects.find(&.is_a?(Swim::SendMessage)).as(Swim::SendMessage)
      ack_effect.message.type.should eq(Swim::MessageType::Ack)

      rebuttal_gossip = ack_effect.message.changes.first
      rebuttal_gossip.id.should eq("B")
      rebuttal_gossip.incarnation.should eq(2_u64)
      rebuttal_gossip.state.should eq(Swim::State::Alive)
    end
  end
end
