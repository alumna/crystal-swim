require "../spec_helper"

describe Swim::Cluster do
  it "reports the local peer and stops twice" do
    Swim::VERSION.should eq("0.3.0")
    cluster = Swim.join("127.0.0.1:0", period: 20.milliseconds, timeout: 10.milliseconds)
    begin
      cluster.port.should be > 0
      cluster.size.should eq(1)
      cluster.health.should eq(0)
      cluster.alive?("127.0.0.1:#{cluster.port}").should be_true
      cluster.alive?("127.0.0.1:9").should be_false
      seen = [] of String
      cluster.each { |peer| seen << peer.to_s }
      seen.should eq(["127.0.0.1:#{cluster.port} alive"])
    ensure
      cluster.stop
      cluster.stop
    end
  end

  it "stops when the join block ends" do
    port = 0
    Swim.join("127.0.0.1:0", period: 1.second, timeout: 200.milliseconds) do |cluster|
      port = cluster.port
      cluster.size.should eq(1)
    end
    port.should be > 0
  end

  it "rejects bad arguments" do
    expect_raises(ArgumentError) { Swim.join("not-an-address") }
    expect_raises(ArgumentError) { Swim.join("127.0.0.1:0", period: 0.seconds) }
    expect_raises(ArgumentError) { Swim.join("127.0.0.1:0", timeout: 0.seconds) }
    expect_raises(ArgumentError) { Swim.join("127.0.0.1:0", seeds: ["bad-seed"]) }
  end

  it "binds all interfaces and advertises the real port" do
    cluster = Swim.join("127.0.0.1:0", bind: "0.0.0.0:0", period: 1.second, timeout: 200.milliseconds)
    begin
      cluster.alive?("127.0.0.1:#{cluster.port}").should be_true
    ensure
      cluster.stop
    end
  end

  it "learns a peer over UDP" do
    left = Swim.join("127.0.0.1:0", period: 15.milliseconds, timeout: 40.milliseconds)
    right = Swim.join("127.0.0.1:0", seeds: ["127.0.0.1:#{left.port}"], period: 15.milliseconds, timeout: 40.milliseconds)
    begin
      wait_until { left.size == 2 && right.size == 2 }
      left.alive?("127.0.0.1:#{right.port}").should be_true
      right.alive?("127.0.0.1:#{left.port}").should be_true
    ensure
      left.stop
      right.stop
    end
  end

  it "learns a peer when the datagrams are sealed" do
    left = Swim.join("127.0.0.1:0", key: "same-key", period: 15.milliseconds, timeout: 40.milliseconds)
    right = Swim.join("127.0.0.1:0", seeds: ["127.0.0.1:#{left.port}"], key: "same-key", period: 15.milliseconds, timeout: 40.milliseconds)
    begin
      wait_until { left.size == 2 && right.size == 2 }
      left.size.should eq(2)
      right.size.should eq(2)
    ensure
      left.stop
      right.stop
    end
  end

  it "ignores a bad datagram and a datagram sealed with the wrong key" do
    plain = Swim.join("127.0.0.1:0", period: 50.milliseconds, timeout: 20.milliseconds)
    sealed = Swim.join("127.0.0.1:0", key: "right-key", period: 50.milliseconds, timeout: 20.milliseconds)
    begin
      socket = UDPSocket.new
      socket.send("garbage", Socket::IPAddress.new("127.0.0.1", plain.port))
      socket.send("garbage", Socket::IPAddress.new("127.0.0.1", sealed.port))
      socket.close
      sleep 30.milliseconds
      plain.size.should eq(1)
      sealed.size.should eq(1)
    ensure
      plain.stop
      sealed.stop
    end
  end

  it "raises local health when a seed never answers" do
    cluster = Swim.join("127.0.0.1:0", seeds: ["127.0.0.1:9"], period: 20.milliseconds, timeout: 10.milliseconds)
    begin
      wait_until(300.milliseconds) { cluster.health > 0 }
      cluster.health.should be > 0
    ensure
      cluster.stop
    end
  end

  it "keeps running after the socket is closed" do
    cluster = Swim.join("127.0.0.1:0", seeds: ["127.0.0.1:9"], period: 10.milliseconds, timeout: 5.milliseconds)
    sleep 20.milliseconds
    cluster.socket.close
    sleep 20.milliseconds
    cluster.stop
  end

  it "serves a read from the default context while the reactor runs" do
    Fiber::ExecutionContext.default.resize(2)
    cluster = Swim.join("127.0.0.1:0", seeds: ["127.0.0.1:9"], period: 10.milliseconds, timeout: 5.milliseconds)
    begin
      done = Channel(Nil).new
      spawn do
        50.times { cluster.size }
        done.send(nil)
      end
      done.receive
      cluster.size.should be >= 1
    ensure
      cluster.stop
    end
  end

  it "joins an IPv6 loopback address" do
    cluster = Swim.join("[::1]:0", period: 1.second, timeout: 200.milliseconds)
    begin
      cluster.alive?("[::1]:#{cluster.port}").should be_true
    ensure
      cluster.stop
    end
  end
end

describe Swim::Cluster::Outbox do
  it "sends a plain datagram and ignores a closed socket" do
    box = Swim::Cluster::Outbox.new
    endpoint = Swim::Endpoint.parse("127.0.0.1:9")
    box.add(endpoint, "ping".to_slice, nil)
    socket = UDPSocket.new
    socket.bind("127.0.0.1", 0)
    box.flush(socket)
    socket.close
    box.add(endpoint, "ping".to_slice, nil)
    box.flush(socket)
  end

  it "drops a datagram that does not fit in the seal buffer" do
    box = Swim::Cluster::Outbox.new
    endpoint = Swim::Endpoint.parse("127.0.0.1:9")
    seal = Swim::Seal.new("key")
    box.add(endpoint, Bytes.new(300), seal)
    socket = UDPSocket.new
    socket.bind("127.0.0.1", 0)
    box.flush(socket)
    socket.close
  end
end

def wait_until(limit : Time::Span = 500.milliseconds, &) : Nil
  deadline = Time.instant + limit
  until yield || Time.instant >= deadline
    sleep 5.milliseconds
  end
end
