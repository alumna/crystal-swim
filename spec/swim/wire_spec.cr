require "../spec_helper"

describe Swim::Wire do
  it "round-trips a ping-req with gossip" do
    sender = Swim::Endpoint.parse("10.0.0.1:5000")
    target = Swim::Endpoint.parse("[::1]:5001")
    other = Swim::Endpoint.parse("10.0.0.2:5002")
    buf = Bytes.new(Swim::Wire::MAX_BYTES)
    Swim::Wire.open(buf, Swim::Wire::PING_REQ, 42_u64, sender, target)
    Swim::Wire.store(buf, 0, other, 7_u64, Swim::Status::Suspect)
    Swim::Wire.store(buf, 1, sender, 3_u64, Swim::Status::Alive)
    packet = buf[0, Swim::Wire.bytes(2)]

    view = Swim::Wire.view?(packet)
    view.should_not be_nil
    if view
      view.type.should eq(Swim::Wire::PING_REQ)
      view.seq.should eq(42)
      view.sender.should eq(sender)
      view.target.should eq(target)
      view.changes.should eq(2)
    end

    endpoint, incarnation, status = Swim::Wire.change(packet, 0)
    endpoint.should eq(other)
    incarnation.should eq(7)
    status.should eq(Swim::Status::Suspect)

    endpoint, incarnation, status = Swim::Wire.change(packet, 1)
    endpoint.should eq(sender)
    incarnation.should eq(3)
    status.should eq(Swim::Status::Alive)
  end

  it "rejects a packet that is not SWIM" do
    Swim::Wire.view?(Bytes.new(10)).should be_nil
    Swim::Wire.view?(Bytes.new(Swim::Wire::HEADER)).should be_nil

    sender = Swim::Endpoint.parse("10.0.0.1:5000")
    buf = Bytes.new(Swim::Wire::MAX_BYTES)
    Swim::Wire.open(buf, Swim::Wire::PING, 1_u64, sender, Swim::Endpoint.zero)
    Swim::Wire.store(buf, 0, sender, 1_u64, Swim::Status::Alive)
    packet = buf[0, Swim::Wire.bytes(1)]

    packet[0] = 0_u8
    Swim::Wire.view?(packet).should be_nil

    Swim::Wire.open(buf, Swim::Wire::PING, 1_u64, sender, Swim::Endpoint.zero)
    Swim::Wire.store(buf, 0, sender, 1_u64, Swim::Status::Alive)
    packet = buf[0, Swim::Wire.bytes(1)]
    packet[4] = 9_u8
    Swim::Wire.view?(packet).should be_nil

    Swim::Wire.open(buf, Swim::Wire::ACK, 1_u64, sender, Swim::Endpoint.zero)
    Swim::Wire.store(buf, 0, sender, 1_u64, Swim::Status::Alive)
    packet = buf[0, Swim::Wire.bytes(1)]
    packet[5] = 9_u8
    Swim::Wire.view?(packet).should be_nil

    Swim::Wire.open(buf, Swim::Wire::ACK, 1_u64, sender, Swim::Endpoint.zero)
    Swim::Wire.store(buf, 0, sender, 1_u64, Swim::Status::Alive)
    packet = buf[0, Swim::Wire.bytes(1)]
    packet[6] = 6_u8
    Swim::Wire.view?(packet).should be_nil

    Swim::Wire.open(buf, Swim::Wire::PING, 1_u64, sender, Swim::Endpoint.zero)
    Swim::Wire.store(buf, 0, sender, 1_u64, Swim::Status::Alive)
    short = buf[0, Swim::Wire::HEADER]
    Swim::Wire.view?(short).should be_nil

    Swim::Wire.open(buf, Swim::Wire::PING, 1_u64, sender, Swim::Endpoint.zero)
    Swim::Wire.store(buf, 0, sender, 1_u64, Swim::Status::Dead)
    packet = buf[0, Swim::Wire.bytes(1)]
    packet[Swim::Wire::HEADER + Swim::Wire::ENDPOINT + 8] = 9_u8
    Swim::Wire.view?(packet).should be_nil
  end
end
