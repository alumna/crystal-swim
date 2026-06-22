require "spec"
require "../../src/swim/protocol"

describe "SWIM Gossip Dissemination" do
  it "piggybacks new node discovery onto a ping" do
    member_a = Swim::Member.new("A", "10.0.0.1", 1_u64, Swim::State::Alive)
    member_b = Swim::Member.new("B", "10.0.0.2", 1_u64, Swim::State::Alive)

    # Node C is the NEW node joining the cluster
    member_c = Swim::Member.new("C", "10.0.0.3", 1_u64, Swim::State::Alive)

    list_a = Swim::MembershipList.new
    list_a.update(member_b)

    protocol_a = Swim::Protocol.new(member_a, list_a)

    # 1. Simulate an incoming Ack from B that contains gossip about C.
    msg_from_b = Swim::Message.new(Swim::MessageType::Ack, 1_u64, "B", "10.0.0.2", changes: [member_c])
    protocol_a.on_message(msg_from_b)

    # A now knows about C
    protocol_a.members.size.should eq(3) # A, B, C

    # 2. Sometime later, Node A ticks and decides to ping a node.
    effects = protocol_a.on_tick
    ping_effect = effects.find(&.is_a?(Swim::SendMessage)).as(Swim::SendMessage)

    # The outgoing Ping should contain the gossip about C!
    ping_effect.message.changes.size.should eq(1)
    ping_effect.message.changes.first.id.should eq("C")

    # 3. Simulate Node B receiving this Ping from A
    list_b = Swim::MembershipList.new
    protocol_b = Swim::Protocol.new(member_b, list_b)

    # Before message, B only knows about itself
    protocol_b.members.size.should eq(1)

    protocol_b.on_message(ping_effect.message)

    # MAGIC: B now knows about C because of the piggybacked gossip!
    # Note: B does NOT automatically learn about A from the message header because
    # the header lacks the strict incarnation number required by the membership list.
    protocol_b.members.size.should eq(2) # B itself, and C (from gossip)

    # Verify C was successfully parsed and applied
    protocol_b.members.get("C").should_not be_nil
    protocol_b.members.get("C").try(&.address).should eq("10.0.0.3")
  end
end
