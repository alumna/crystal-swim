require "../spec_helper"

describe Swim::Table do
  now = Time.instant

  it "starts empty" do
    table = Swim::Table.new(Random.new(1))
    table.size.should eq(0)
    table.find(SwimSpec.at(1)).should be_nil
    table.sample(1, false, Swim::Endpoint.zero) { fail "empty table yielded a peer" }
    table.sample(0, false, Swim::Endpoint.zero) { fail "zero sample yielded a peer" }
    only = SwimSpec.at(1)
    table.put(Swim::Peer.new(only, 1_u64, Swim::Status::Alive, now, only.to_ip))
    table.sample(1, false, Swim::Endpoint.zero) { |peer| peer.endpoint.should eq(only) }
  end

  it "stores, replaces, and samples without the excluded peer" do
    table = Swim::Table.new(Random.new(1))
    first = SwimSpec.at(1)
    second = SwimSpec.at(2)
    third = SwimSpec.at(3)
    table.put(Swim::Peer.new(first, 1_u64, Swim::Status::Alive, now, first.to_ip))
    table.put(Swim::Peer.new(second, 1_u64, Swim::Status::Alive, now, second.to_ip))
    table.put(Swim::Peer.new(third, 1_u64, Swim::Status::Dead, now, third.to_ip))
    table.put(Swim::Peer.new(second, 4_u64, Swim::Status::Suspect, now, second.to_ip))

    found = table.find(second)
    found.should_not be_nil
    if found
      found.incarnation.should eq(4)
      found.suspect?.should be_true
    end
    table.size.should eq(3)

    seen = [] of Swim::Endpoint
    table.sample(5, true, first) { |peer| seen << peer.endpoint }
    seen.size.should eq(1)
    seen.should eq([second])

    seen.clear
    table.sample(1, false, Swim::Endpoint.zero) { |peer| seen << peer.endpoint }
    seen.size.should eq(1)
  end

  it "grows and compacts" do
    table = Swim::Table.new(Random.new(2))
    keep = SwimSpec.at(1)
    table.put(Swim::Peer.new(keep, 1_u64, Swim::Status::Alive, now, keep.to_ip))
    40.times do |index|
      endpoint = SwimSpec.at(100 + index)
      table.put(Swim::Peer.new(endpoint, 1_u64, Swim::Status::Dead, now, endpoint.to_ip))
    end
    table.size.should eq(41)
    table.find(keep).should_not be_nil

    table.delete_dead(now, keep)
    table.size.should eq(1)
    table.find(keep).should_not be_nil
    table.find(SwimSpec.at(100)).should be_nil

    fresh = SwimSpec.at(9)
    table.put(Swim::Peer.new(fresh, 1_u64, Swim::Status::Alive, now, fresh.to_ip))
    table.find(fresh).should_not be_nil
  end

  it "reuses a tombstone and keeps peers inside the ttl" do
    table = Swim::Table.new(Random.new(3))
    keep = SwimSpec.at(1)
    dead = SwimSpec.at(2)
    alive = SwimSpec.at(3)
    suspect = SwimSpec.at(4)
    table.put(Swim::Peer.new(keep, 1_u64, Swim::Status::Alive, now, keep.to_ip))
    table.put(Swim::Peer.new(dead, 1_u64, Swim::Status::Dead, now, dead.to_ip))
    table.put(Swim::Peer.new(alive, 1_u64, Swim::Status::Alive, now, alive.to_ip))
    table.put(Swim::Peer.new(suspect, 1_u64, Swim::Status::Suspect, now, suspect.to_ip))

    table.delete_dead(now - 1.second, keep)
    table.size.should eq(4)

    table.delete_dead(now, keep)
    table.size.should eq(3)
    table.find(dead).should be_nil
    table.find(alive).should_not be_nil
    table.find(suspect).should_not be_nil

    reused = SwimSpec.at(8)
    table.put(Swim::Peer.new(reused, 1_u64, Swim::Status::Alive, now, reused.to_ip))
    table.find(reused).should_not be_nil
  end
end
