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

        if existing
          if new_member.overrides?(existing)
            @members[new_member.id] = new_member
            return true
          end
          return false
        else
          @members[new_member.id] = new_member
          return true
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

    # Selects random members for pinging/ping-reqs.
    def sample(count : Int32, exclude_ids : Enumerable(String) = [] of String) : Array(Member)
      @lock.read do
        # For a mature system, if the cluster exceeds 10k nodes, this linear filter
        # could be optimized, but keeping it simple is the right baseline.
        candidates = @members.values.reject { |m| exclude_ids.includes?(m.id) }
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
