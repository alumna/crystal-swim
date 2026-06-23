require "spec"
require "json"
require "../../src/swim/member"

describe Swim::Member do
  it "serializes and deserializes cleanly via JSON" do
    member = Swim::Member.new("node1", "10.0.0.1:5000", 1_u64, Swim::State::Alive)

    json = member.to_json
    parsed = Swim::Member.from_json(json)

    parsed.id.should eq("node1")
    parsed.address.should eq("10.0.0.1:5000")
    parsed.incarnation.should eq(1_u64)
    parsed.state.should eq(Swim::State::Alive)
  end
end
