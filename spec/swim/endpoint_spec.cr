require "../spec_helper"

describe Swim::Endpoint do
  it "parses an IPv4 address" do
    endpoint = Swim::Endpoint.parse("10.0.0.1:5000")
    endpoint.v4?.should be_true
    endpoint.v6?.should be_false
    endpoint.port.should eq(5000)
    endpoint.to_s.should eq("10.0.0.1:5000")
    endpoint.host.should eq("10.0.0.1")
    endpoint.to_ip.to_s.should eq("10.0.0.1:5000")
    endpoint.mix.should be > 0
  end

  it "parses an IPv6 address" do
    endpoint = Swim::Endpoint.parse("[::1]:7946")
    endpoint.v6?.should be_true
    endpoint.port.should eq(7946)
    endpoint.to_s.should eq("[::1]:7946")
    endpoint.host.should eq("::1")
    endpoint.to_ip.port.should eq(7946)
    endpoint.with_port(1_u16).port.should eq(1)
  end

  it "compares address bytes and port" do
    left = Swim::Endpoint.parse("10.0.0.1:5000")
    same = Swim::Endpoint.parse("10.0.0.1:5000")
    other = Swim::Endpoint.parse("10.0.0.1:5001")
    left.should eq(same)
    left.should_not eq(other)
  end

  it "rejects malformed text" do
    ["", "10.0.0.1", "10.0.0.1:", "10.0.0.1:abc", "10.0.0.1:70000", "not:1", "[::1]", "[::1]:", "[::1]:abc", "[gggg::1]:1", "10.0.0.1:-1"].each do |text|
      expect_raises(ArgumentError) { Swim::Endpoint.parse(text) }
    end
  end

  it "rejects a socket conversion for an empty address" do
    expect_raises(ArgumentError) { Swim::Endpoint.zero.to_ip }
    Swim::Endpoint.zero.to_s.should eq("")
  end
end
