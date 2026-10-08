require "socket"
require "./endpoint"

module Swim
  # Membership state. The numeric order is the SWIM rank at one incarnation.
  # Dead beats Suspect. Suspect beats Alive.
  enum Status : UInt8
    Alive   = 0
    Suspect = 1
    Dead    = 2
  end

  # One row in the membership table. The struct is copied by value.
  struct Peer
    getter endpoint : Endpoint
    getter incarnation : UInt64
    getter status : Status
    getter updated : Time::Instant
    getter ip : Socket::IPAddress

    def initialize(@endpoint : Endpoint, @incarnation : UInt64, @status : Status, @updated : Time::Instant, @ip : Socket::IPAddress)
    end

    def alive? : Bool
      @status.alive?
    end

    def suspect? : Bool
      @status.suspect?
    end

    def dead? : Bool
      @status.dead?
    end

    def with(incarnation : UInt64, status : Status, updated : Time::Instant) : Peer
      Peer.new(@endpoint, incarnation, status, updated, @ip)
    end

    def to_s(io : IO) : Nil
      @endpoint.to_s(io)
      io << ' '
      case @status
      in .alive?
        io << "alive"
      in .suspect?
        io << "suspect"
      in .dead?
        io << "dead"
      end
    end
  end

  # SWIM conflict rule. A higher incarnation always wins.
  module Rank
    def self.beats?(incarnation : UInt64, status : Status, current : Peer) : Bool
      incarnation > current.incarnation || (incarnation == current.incarnation && status.value > current.status.value)
    end
  end
end
