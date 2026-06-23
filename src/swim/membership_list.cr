require "sync"
require "./member"

module Swim
  class MembershipList
    def initialize
      @lock = Sync::RWLock.new
      @members = Hash(String, Member).new
    end

    # Merges a member into the list according to SWIM override rules.
    # Returns `true` if the internal state was updated (useful for triggering gossip).
    def update(new_member : Member) : Bool
      @lock.write do
        existing = @members[new_member.id]?

        if !existing || new_member.overrides?(existing)
          @members[new_member.id] = new_member
          true
        else
          false
        end
      end
    end

    # Retrieves a member by ID, returning nil if not found.
    def get(id : String) : Member?
      @lock.read { @members[id]? }
    end

    # Returns a snapshot of all members.
    def all : Array(Member)
      @lock.read { @members.values }
    end

    # Returns the total number of known members.
    def size : Int32
      @lock.read { @members.size }
    end

    # Selects random members.
    # exclude_dead: true prevents us from wasting network bandwidth pinging tombstones.
    def sample(count : Int32, exclude_ids : Enumerable(String) = [] of String, exclude_dead : Bool = false) : Array(Member)
      exclude_set = exclude_ids.to_set

      @lock.read do
        candidates = @members.values.reject do |m|
          exclude_set.includes?(m.id) || (exclude_dead && m.state.dead?)
        end
        candidates.sample(count)
      end
    end

    # Explicit removal is rarely used in standard SWIM (dead nodes remain as tombstones
    # briefly to prevent rapid rejoins), but it is necessary for local node cleanup or testing.
    def remove(id : String) : Nil
      @lock.write { @members.delete(id) }
    end
  end
end
