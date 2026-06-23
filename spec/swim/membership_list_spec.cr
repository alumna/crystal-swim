require "spec"
require "../../src/swim/membership_list"

describe Swim::MembershipList do
  describe "SWIM Override Rules (Member)" do
    it "higher incarnation wins regardless of state" do
      old = Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Dead)
      newer = Swim::Member.new("1", "10.0.0.1", 2_u64, Swim::State::Alive)

      newer.overrides?(old).should be_true
      old.overrides?(newer).should be_false
    end

    it "same incarnation: Dead overrides Suspect and Alive" do
      alive = Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Alive)
      suspect = Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Suspect)
      dead = Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Dead)

      dead.overrides?(suspect).should be_true
      dead.overrides?(alive).should be_true

      suspect.overrides?(dead).should be_false
      alive.overrides?(dead).should be_false
    end

    it "same incarnation: Suspect overrides Alive" do
      alive = Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Alive)
      suspect = Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Suspect)

      suspect.overrides?(alive).should be_true
      alive.overrides?(suspect).should be_false
    end

    it "identical states do not override" do
      a = Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Alive)
      b = Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Alive)

      a.overrides?(b).should be_false
    end
  end

  describe "List Management" do
    it "adds new members and reports an update" do
      list = Swim::MembershipList.new
      m1 = Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Alive)

      list.update(m1).should be_true
      list.size.should eq(1)

      # Verifying safe unboxing
      found = list.get("1")
      found.should_not be_nil
      found.try(&.address).should eq("10.0.0.1")
    end

    it "ignores outdated gossip and reports no update" do
      list = Swim::MembershipList.new
      m_newer = Swim::Member.new("1", "10.0.0.1", 2_u64, Swim::State::Alive)
      m_older = Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Dead)

      list.update(m_newer).should be_true
      list.update(m_older).should be_false # Ignored

      list.get("1").try(&.incarnation).should eq(2_u64)
    end

    it "removes members safely" do
      list = Swim::MembershipList.new
      list.update(Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Alive))
      list.remove("1")

      list.get("1").should be_nil
      list.size.should eq(0)
    end
  end

  describe "Sampling" do
    it "samples random members excluding specified IDs" do
      list = Swim::MembershipList.new
      list.update(Swim::Member.new("A", "10.0.0.1", 1_u64, Swim::State::Alive))
      list.update(Swim::Member.new("B", "10.0.0.2", 1_u64, Swim::State::Alive))
      list.update(Swim::Member.new("C", "10.0.0.3", 1_u64, Swim::State::Alive))

      sampled = list.sample(count: 2, exclude_ids: ["A"])

      sampled.size.should eq(2)
      sampled.map(&.id).should_not contain("A")
    end

    it "safely requests more samples than available" do
      list = Swim::MembershipList.new
      list.update(Swim::Member.new("A", "10.0.0.1", 1_u64, Swim::State::Alive))

      sampled = list.sample(count: 5)
      sampled.size.should eq(1)
    end
  end

  describe "Tombstone GC" do
    it "removes dead members that exceed the TTL" do
      list = Swim::MembershipList.new
      list.update(Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Dead))

      # A TTL of 0 seconds guarantees it is immediately eligible for GC
      list.cleanup_tombstones(0.seconds)

      list.size.should eq(0)
    end

    it "does not remove alive or suspect members" do
      list = Swim::MembershipList.new
      list.update(Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Alive))
      list.update(Swim::Member.new("2", "10.0.0.2", 1_u64, Swim::State::Suspect))

      list.cleanup_tombstones(0.seconds)
      list.size.should eq(2)
    end

    it "does not remove dead members within the TTL window" do
      list = Swim::MembershipList.new
      list.update(Swim::Member.new("1", "10.0.0.1", 1_u64, Swim::State::Dead))

      list.cleanup_tombstones(1.hour) # Cutoff is in the past, member is newer
      list.size.should eq(1)
    end
  end
end
