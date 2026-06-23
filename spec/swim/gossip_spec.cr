require "spec"
require "../../src/swim/protocol"

describe "SWIM Gossip Dissemination" do
  it "piggybacks new node discovery onto a ping" do
    member_a = Swim::Member.new("A", "10.0.0.1", 1_u64, Swim::State::Alive)
    member_b = Swim::Member.new("B", "10.0.0.2", 1_u64, Swim::State::Alive)

    member_c = Swim::Member.new("C", "10.0.0.3", 1_u64, Swim::State::Alive)

    list_a = Swim::MembershipList.new
    list_a.update(member_b)
    protocol_a = Swim::Protocol.new(member_a, list_a)

    # 1. Simulate an incoming Ack from B that contains gossip about C.
    msg_from_b = Swim::Message.new(Swim::MessageType::Ack, 1_u64, "B", "10.0.0.2", changes: [member_c])
    protocol_a.on_message(msg_from_b)

    # 2. Node A ticks and decides to ping a node.
    effects = protocol_a.on_tick
    ping_effect = effects.find(&.is_a?(Swim::SendMessage)).as(Swim::SendMessage)

    # Because we use random sampling and the cluster has exactly 3 nodes,
    # it will confidently attach all 3 nodes!
    ping_effect.message.changes.size.should eq(3)

    gossiped_c = ping_effect.message.changes.find { |m| m.id == "C" }
    gossiped_c.should_not be_nil

    # 3. Simulate Node B receiving this Ping from A
    list_b = Swim::MembershipList.new
    protocol_b = Swim::Protocol.new(member_b, list_b)

    protocol_b.on_message(ping_effect.message)

    # MAGIC: B now knows about C (from A's gossip) AND A (from A's self-announcement)!
    protocol_b.members.size.should eq(3) # B, A, and C

    protocol_b.members.get("A").should_not be_nil
    protocol_b.members.get("C").should_not be_nil
  end
end
