require "../spec_helper"

describe Swim::Peer do
  it "prints each status" do
    now = Time.instant
    endpoint = Swim::Endpoint.parse("10.0.0.1:5000")
    ip = endpoint.to_ip

    alive = Swim::Peer.new(endpoint, 1_u64, Swim::Status::Alive, now, ip)
    suspect = alive.with(2_u64, Swim::Status::Suspect, now)
    dead = alive.with(2_u64, Swim::Status::Dead, now)

    alive.alive?.should be_true
    alive.suspect?.should be_false
    alive.dead?.should be_false
    alive.to_s.should eq("10.0.0.1:5000 alive")

    suspect.suspect?.should be_true
    suspect.to_s.should eq("10.0.0.1:5000 suspect")
    suspect.incarnation.should eq(2)

    dead.dead?.should be_true
    dead.to_s.should eq("10.0.0.1:5000 dead")
    dead.updated.should eq(now)
    dead.endpoint.should eq(endpoint)
  end
end

describe Swim::Rank do
  now = Time.instant
  endpoint = Swim::Endpoint.parse("10.0.0.1:5000")
  ip = endpoint.to_ip

  it "lets a higher incarnation win" do
    current = Swim::Peer.new(endpoint, 1_u64, Swim::Status::Dead, now, ip)
    Swim::Rank.beats?(2_u64, Swim::Status::Alive, current).should be_true
    Swim::Rank.beats?(1_u64, Swim::Status::Alive, current).should be_false
  end

  it "lets Dead beat Suspect and Alive at the same incarnation" do
    alive = Swim::Peer.new(endpoint, 1_u64, Swim::Status::Alive, now, ip)
    suspect = Swim::Peer.new(endpoint, 1_u64, Swim::Status::Suspect, now, ip)
    Swim::Rank.beats?(1_u64, Swim::Status::Dead, alive).should be_true
    Swim::Rank.beats?(1_u64, Swim::Status::Dead, suspect).should be_true
    Swim::Rank.beats?(1_u64, Swim::Status::Suspect, alive).should be_true
    Swim::Rank.beats?(1_u64, Swim::Status::Alive, suspect).should be_false
    Swim::Rank.beats?(1_u64, Swim::Status::Alive, alive).should be_false
  end
end
