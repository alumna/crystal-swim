require "spec"
require "../../src/swim/node"

describe Swim::Node do
  it "communicates over real UDP sockets" do
    # Create members
    member_a = Swim::Member.new("A", "127.0.0.1:5001", 1_u64, Swim::State::Alive)
    member_b = Swim::Member.new("B", "127.0.0.1:5002", 1_u64, Swim::State::Alive)

    # Initialize Lists and Protocols
    list_a = Swim::MembershipList.new
    list_a.update(member_b) # A knows about B
    protocol_a = Swim::Protocol.new(member_a, list_a)

    list_b = Swim::MembershipList.new
    list_b.update(member_a) # B knows about A
    protocol_b = Swim::Protocol.new(member_b, list_b)

    # Initialize Nodes binding to respective ports
    node_a = Swim::Node.new(protocol_a, "127.0.0.1", 5001)
    node_b = Swim::Node.new(protocol_b, "127.0.0.1", 5002)

    begin
      # Start both nodes with a very fast tick interval for the test
      node_a.start(tick_interval: 10.milliseconds)
      node_b.start(tick_interval: 10.milliseconds)

      # Give the background fibers enough time to:
      # 1. Tick
      # 2. Send UDP Ping
      # 3. Receive UDP Ping and Send UDP Ack
      # 4. Receive UDP Ack and process it
      sleep 50.milliseconds

      # Assert A still considers B alive after network communication
      node_a.protocol.members.get("B").try(&.state).should eq(Swim::State::Alive)

      # Assert B still considers A alive
      node_b.protocol.members.get("A").try(&.state).should eq(Swim::State::Alive)
    ensure
      # Guarantee sockets are closed even if assertions fail
      node_a.stop
      node_b.stop
    end
  end
end
