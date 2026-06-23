# src/swim/membership_list.cr
require "sync"
require "./member"

module Swim
  class MembershipList
    alias Entry = {member: Member, updated_at: Time::Instant}

    def initialize
      @lock = Sync::RWLock.new
      @members = Hash(String, Entry).new
    end

    def update(new_member : Member) : Bool
      @lock.write do
        existing = @members[new_member.id]?

        if !existing || new_member.overrides?(existing[:member])
          @members[new_member.id] = {member: new_member, updated_at: Time.instant}
          true
        else
          false
        end
      end
    end

    def get(id : String) : Member?
      @lock.read { @members[id]?.try(&.[:member]) }
    end

    def all : Array(Member)
      @lock.read { @members.values.map(&.[:member]) }
    end

    def size : Int32
      @lock.read { @members.size }
    end

    def sample(count : Int32, exclude_ids : Enumerable(String) = [] of String, exclude_dead : Bool = false) : Array(Member)
      @lock.read do
        candidates = [] of Member
        @members.each_value do |entry|
          m = entry[:member]
          next if exclude_ids.includes?(m.id)
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
      cutoff = Time.instant - ttl
      @lock.write do
        @members.reject! do |_, entry|
          entry[:member].state.dead? && entry[:updated_at] < cutoff
        end
      end
    end
  end
end
