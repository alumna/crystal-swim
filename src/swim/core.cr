require "./table"
require "./wire"

module Swim
  # In-memory SWIM engine. Pass `now` from the caller so tests control time.
  # The hot path writes packets into one buffer and does not allocate.
  class Core
    PROBE_SLOTS = 64
    GC_EVERY    = 60
    MAX_HEALTH  =  5
    HELPERS     =  3

    getter incarnation : UInt64
    getter health : Int32

    @probes : StaticArray(Probe, 64)
    @out : Bytes
    @seq : UInt64
    @ticks : UInt64
    @updated : Time::Instant

    def initialize(local : Endpoint, *, incarnation : UInt64 = 1_u64, now : Time::Instant = Time.instant, @timeout : Time::Span = 500.milliseconds, @tombstone : Time::Span = 24.hours, random : Random = Random.new)
      raise ArgumentError.new("Timeout must be positive") unless @timeout > Time::Span.zero
      @local = local
      @incarnation = incarnation
      @updated = now
      @local_ip = local.to_ip
      @health = 0
      @seq = 0_u64
      @ticks = 0_u64
      @table = Table.new(random)
      @table.put(local_peer)
      @out = Bytes.new(Wire::MAX_BYTES)
      @idle = Probe.idle
      @probes = StaticArray(Probe, 64).new(@idle)
    end

    def size : Int32
      @table.size
    end

    def get(endpoint : Endpoint) : Peer?
      @table.find(endpoint)
    end

    def each(& : Peer ->) : Nil
      @table.each { |peer| yield peer }
    end

    def alive?(endpoint : Endpoint) : Bool
      return true if endpoint == @local
      if peer = @table.find(endpoint)
        peer.alive?
      else
        false
      end
    end

    def timeout_span : Time::Span
      @timeout * (1 &+ @health)
    end

    def pending : Int32
      count = 0
      PROBE_SLOTS.times { |index| count &+= 1 if @probes[index].live? }
      count
    end

    # Adds a peer, or ignores the update when the current row wins.
    def add(endpoint : Endpoint, incarnation : UInt64, status : Status, now : Time::Instant) : Nil
      apply(endpoint, incarnation, status, now)
    end

    # One probe period. Yields one ping when another peer can be probed.
    def tick(now : Time::Instant, & : Endpoint, Bytes ->) : Nil
      @ticks &+= 1
      @table.delete_dead(now - @tombstone, @local) if (@ticks % GC_EVERY) == 0
      target = Endpoint.zero
      found = false
      @table.sample(1, true, @local) do |peer|
        target = peer.endpoint
        found = true
      end
      return unless found
      index = alloc_probe
      return if index < 0
      seq = next_seq
      @probes[index] = Probe.direct(seq, target, now + timeout_span)
      emit(Wire::PING, seq, Endpoint.zero) { |bytes| yield target, bytes }
    end

    # Fires due probes. A direct timeout yields ping-req packets.
    def expire(now : Time::Instant, & : Endpoint, Bytes ->) : Nil
      PROBE_SLOTS.times do |index|
        probe = @probes[index]
        next unless probe.live?
        next if probe.deadline > now
        if probe.direct?
          expire_direct(index, probe, now) { |endpoint, bytes| yield endpoint, bytes }
        elsif probe.indirect?
          expire_indirect(index, probe, now)
        else
          free_probe(index)
        end
      end
    end

    # Applies one datagram. Yields at most one reply. Returns false for a bad packet.
    def receive(bytes : Bytes, now : Time::Instant, & : Endpoint, Bytes ->) : Bool
      view = Wire.view?(bytes)
      return false unless view
      view.changes.times do |index|
        endpoint, incarnation, status = Wire.change(bytes, index)
        apply(endpoint, incarnation, status, now)
      end
      case view.type
      when Wire::PING
        emit(Wire::ACK, view.seq, Endpoint.zero) { |packet| yield view.sender, packet }
      when Wire::ACK
        accept_ack(view, now) { |endpoint, packet| yield endpoint, packet }
      else
        accept_ping_req(view, now) { |endpoint, packet| yield endpoint, packet }
      end
      true
    end

    def each_deadline(& : Time::Instant ->) : Nil
      PROBE_SLOTS.times do |index|
        probe = @probes[index]
        yield probe.deadline if probe.live?
      end
    end

    private def accept_ack(view : Wire::View, now : Time::Instant, &) : Nil
      if (index = find_probe(view.seq, owned: true)) >= 0
        free_probe(index)
        improve
        return
      end
      return unless (index = find_probe(view.seq, owned: false)) >= 0
      proxy = @probes[index]
      free_probe(index)
      emit(Wire::ACK, proxy.origin_seq, proxy.target) { |packet| yield proxy.origin, packet }
    end

    private def accept_ping_req(view : Wire::View, now : Time::Instant, &) : Nil
      return if view.target.family == 0
      index = alloc_probe
      return if index < 0
      seq = next_seq
      @probes[index] = Probe.proxy(seq, view.target, view.sender, view.seq, now + timeout_span)
      emit(Wire::PING, seq, Endpoint.zero) { |packet| yield view.target, packet }
    end

    private def expire_direct(index : Int32, probe : Probe, now : Time::Instant, &) : Nil
      unless @table.find(probe.target)
        free_probe(index)
        return
      end
      # Copy helpers first. Emit shuffles the table, so it must not run inside sample.
      helpers = StaticArray(Endpoint, 3).new(Endpoint.zero)
      helper_count = 0
      @table.sample(HELPERS, true, @local, probe.target) do |helper|
        helpers[helper_count] = helper.endpoint
        helper_count &+= 1
      end
      helper_count.times do |helper_index|
        emit(Wire::PING_REQ, probe.seq, probe.target) { |packet| yield helpers[helper_index], packet }
      end
      @probes[index] = probe.as_indirect(now + timeout_span)
    end

    private def expire_indirect(index : Int32, probe : Probe, now : Time::Instant) : Nil
      if current = @table.find(probe.target)
        status = current.suspect? ? Status::Dead : Status::Suspect
        @table.put(current.with(current.incarnation, status, now)) if Rank.beats?(current.incarnation, status, current)
      end
      degrade
      free_probe(index)
    end

    private def apply(endpoint : Endpoint, incarnation : UInt64, status : Status, now : Time::Instant) : Nil
      if endpoint == @local
        # Suspicion refutation. This node is the authority for its own row.
        if status.suspect? || status.dead?
          @incarnation &+= 1
          @updated = now
          @table.put(local_peer)
        end
        return
      end
      if current = @table.find(endpoint)
        return unless Rank.beats?(incarnation, status, current)
        @table.put(current.with(incarnation, status, now))
      else
        @table.put(Peer.new(endpoint, incarnation, status, now, endpoint.to_ip))
      end
    end

    private def emit(type : UInt8, seq : UInt64, target : Endpoint, &) : Nil
      Wire.open(@out, type, seq, @local, target)
      count = 0
      @table.sample(Wire::MAX_CHANGES &- 1, false, @local) do |peer|
        Wire.store(@out, count, peer.endpoint, peer.incarnation, peer.status)
        count &+= 1
      end
      Wire.store(@out, count, @local, @incarnation, Status::Alive)
      count &+= 1
      yield @out[0, Wire.bytes(count)]
    end

    private def local_peer : Peer
      Peer.new(@local, @incarnation, Status::Alive, @updated, @local_ip)
    end

    private def next_seq : UInt64
      @seq &+= 1
      @seq
    end

    private def alloc_probe : Int32
      PROBE_SLOTS.times { |index| return index unless @probes[index].live? }
      -1
    end

    private def free_probe(index : Int32) : Nil
      @probes[index] = @idle
    end

    private def find_probe(seq : UInt64, owned : Bool) : Int32
      PROBE_SLOTS.times do |index|
        probe = @probes[index]
        next unless probe.live? && probe.seq == seq
        is_owned = probe.direct? || probe.indirect?
        return index if is_owned == owned
      end
      -1
    end

    private def improve : Nil
      return if @health == 0
      @health &-= 1
    end

    private def degrade : Nil
      return if @health >= MAX_HEALTH
      @health &+= 1
    end

    # One outstanding probe. Slot 0 is not reserved. Any free slot is valid.
    struct Probe
      DIRECT   = 1_u8
      INDIRECT = 2_u8
      PROXY    = 3_u8

      getter? live : Bool
      getter phase : UInt8
      getter seq : UInt64
      getter deadline : Time::Instant
      getter target : Endpoint
      getter origin : Endpoint
      getter origin_seq : UInt64

      def initialize(@live : Bool, @phase : UInt8, @seq : UInt64, @deadline : Time::Instant, @target : Endpoint, @origin : Endpoint, @origin_seq : UInt64)
      end

      def self.idle : Probe
        new(false, 0_u8, 0_u64, Time.instant, Endpoint.zero, Endpoint.zero, 0_u64)
      end

      def self.direct(seq : UInt64, target : Endpoint, deadline : Time::Instant) : Probe
        new(true, DIRECT, seq, deadline, target, Endpoint.zero, 0_u64)
      end

      def self.proxy(seq : UInt64, target : Endpoint, origin : Endpoint, origin_seq : UInt64, deadline : Time::Instant) : Probe
        new(true, PROXY, seq, deadline, target, origin, origin_seq)
      end

      def as_indirect(deadline : Time::Instant) : Probe
        Probe.new(true, INDIRECT, @seq, deadline, @target, @origin, @origin_seq)
      end

      def direct? : Bool
        @phase == DIRECT
      end

      def indirect? : Bool
        @phase == INDIRECT
      end
    end
  end
end
