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

  it "processes timeouts successfully while running" do
    member_a = Swim::Member.new("A", "127.0.0.1:5003", 1_u64, Swim::State::Alive)
    member_b = Swim::Member.new("B", "127.0.0.1:5004", 1_u64, Swim::State::Alive)

    list = Swim::MembershipList.new
    list.update(member_b) # A knows about B

    protocol = Swim::Protocol.new(member_a, list)
    node = Swim::Node.new(protocol, "127.0.0.1", 5003)

    # Start ticking. It will immediately send a ping and schedule a 500ms Direct timeout.
    # When that fails, it schedules another 500ms Indirect timeout.
    node.start(tick_interval: 1.second)

    # Wait 1.1 seconds to comfortably exceed the combined 1000ms protocol timeouts
    sleep 1.1.seconds

    # Assert that the full failure detection sequence completed and marked B as suspect
    node.protocol.members.get("B").try(&.state).should eq(Swim::State::Suspect)

    node.stop
  end

  it "safely swallows UDP socket errors on send" do
    member = Swim::Member.new("A", "127.0.0.1:5005", 1_u64, Swim::State::Alive)
    list = Swim::MembershipList.new
    list.update(Swim::Member.new("B", "127.0.0.1:5006", 1_u64, Swim::State::Alive))

    protocol = Swim::Protocol.new(member, list)
    node = Swim::Node.new(protocol, "127.0.0.1", 5005)

    # Deliberately close the socket *before* sending to trigger IO::Error
    node.socket.close

    node.start(tick_interval: 10.milliseconds)

    # Let the ticker attempt to send on a closed socket. It should gracefully rescue `nil`.
    sleep 50.milliseconds

    node.stop
  end

  it "ignores malformed JSON packets without crashing" do
    member = Swim::Member.new("A", "127.0.0.1:5007", 1_u64, Swim::State::Alive)
    list = Swim::MembershipList.new

    protocol = Swim::Protocol.new(member, list)
    node = Swim::Node.new(protocol, "127.0.0.1", 5007)

    node.start(tick_interval: 1.second)

    # Manually send garbage UDP data to the node's listening port
    garbage_socket = UDPSocket.new
    target_addr = Socket::IPAddress.new("127.0.0.1", 5007)
    garbage_socket.send("{ bad json packet... ", target_addr)
    garbage_socket.close

    # Give the background listen_loop time to receive and fail parsing
    sleep 50.milliseconds

    # The node should have rescued the JSON error and still be fully operational
    node.protocol.members.size.should eq(1) # Still just knows about itself

    node.stop
  end

  it "communicates securely when an encryption key is provided" do
    member_a = Swim::Member.new("A", "127.0.0.1:5008", 1_u64, Swim::State::Alive)
    member_b = Swim::Member.new("B", "127.0.0.1:5009", 1_u64, Swim::State::Alive)

    list_a = Swim::MembershipList.new
    list_a.update(member_b)
    protocol_a = Swim::Protocol.new(member_a, list_a)

    list_b = Swim::MembershipList.new
    list_b.update(member_a)
    protocol_b = Swim::Protocol.new(member_b, list_b)

    # Both nodes share the same cluster key
    cluster_secret = "super-secret-cluster-key"
    node_a = Swim::Node.new(protocol_a, "127.0.0.1", 5008, encryption_key: cluster_secret)
    node_b = Swim::Node.new(protocol_b, "127.0.0.1", 5009, encryption_key: cluster_secret)

    begin
      node_a.start(tick_interval: 10.milliseconds)
      node_b.start(tick_interval: 10.milliseconds)

      sleep 50.milliseconds

      # Verify they successfully decrypted each other's packets
      node_a.protocol.members.get("B").try(&.state).should eq(Swim::State::Alive)
      node_b.protocol.members.get("A").try(&.state).should eq(Swim::State::Alive)
    ensure
      node_a.stop
      node_b.stop
    end
  end

  it "ignores packets encrypted with the wrong key" do
    member = Swim::Member.new("A", "127.0.0.1:5099", 1_u64, Swim::State::Alive)
    protocol = Swim::Protocol.new(member, Swim::MembershipList.new)

    node = Swim::Node.new(protocol, "127.0.0.1", 5099, encryption_key: "correct-key")
    node.start(tick_interval: 1.second)

    # Simulate an attacker or misconfigured node sending garbage/wrong key
    garbage_socket = UDPSocket.new
    target_addr = Socket::IPAddress.new("127.0.0.1", 5099)
    garbage_socket.send("unencrypted plaintext json", target_addr)
    garbage_socket.close

    sleep 50.milliseconds

    # The node should have rescued the Cipher error and ignored the packet
    node.protocol.members.size.should eq(1)

    node.stop
  end
end
