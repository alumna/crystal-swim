require "sync"
require "./member"

module Swim
  class MembershipList
    alias Entry = {Member, Time}

    def initialize
      @lock = Sync::RWLock.new
      @members = Hash(String, Entry).new
    end

    def update(new_member : Member) : Bool
      @lock.write do
        existing = @members[new_member.id]?

        if !existing || new_member.overrides?(existing[0])
          @members[new_member.id] = {new_member, Time.utc}
          true
        else
          false
        end
      end
    end

    def get(id : String) : Member?
      @lock.read { @members[id]?.try(&.[0]) }
    end

    def all : Array(Member)
      @lock.read { @members.values.map(&.[0]) }
    end

    def size : Int32
      @lock.read { @members.size }
    end

    def sample(count : Int32, exclude_ids : Enumerable(String) = [] of String, exclude_dead : Bool = false) : Array(Member)
      exclude_set = exclude_ids.to_set

      @lock.read do
        candidates = [] of Member
        @members.each_value do |(m, _)|
          next if exclude_set.includes?(m.id)
          next if exclude_dead && m.state.dead?
          candidates << m
        end
        candidates.sample(count)
      end
    end

    def remove(id : String) : Nil
      @lock.write { @members.delete(id) }
    end

    def cleanup_tombstones(ttl : Time::Span) : Nil
      cutoff = Time.utc - ttl
      @lock.write do
        @members.reject! { |_, (m, updated_at)| m.state.dead? && updated_at < cutoff }
      end
    end
  end
end
