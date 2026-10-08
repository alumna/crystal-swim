require "socket"
require "sync"
require "./core"
require "./seal"

module Swim
  # UDP node. Two fibers share one concurrent context, so they never run at
  # the same time. The user fiber can run in parallel, so reads take a lock.
  # Datagrams are copied into a per-fiber outbox before the lock is released.
  # The send happens after the lock. This avoids a lock-order cycle with the
  # socket lock, which is held for the whole receive.
  class Cluster
    getter port : Int32
    getter socket : UDPSocket

    def initialize(@socket : UDPSocket, @core : Core, @seal : Seal?, @period : Time::Span, @port : Int32)
      @lock = Sync::Mutex.new
      @running = Atomic(Bool).new(true)
      @recv = Bytes.new(2048)
      @plain = Bytes.new(Wire::MAX_BYTES &+ 16)
      @poke = Channel(Nil).new(1)
      @done = Channel(Nil).new
      @io_stopped = Atomic(Bool).new(false)
      @tick_stopped = Atomic(Bool).new(false)
      @signaled = Atomic(Bool).new(false)
      @next_tick = Time.instant
      @context = Fiber::ExecutionContext::Concurrent.new("swim")
      @context.spawn(name: "swim-io") { run_io }
      @context.spawn(name: "swim-tick") { run_tick }
    end

    def stop : Nil
      return unless @running.swap(false)
      signal
      @socket.close rescue nil
      @done.receive
    end

    def size : Int32
      @lock.synchronize { @core.size }
    end

    def health : Int32
      @lock.synchronize { @core.health }
    end

    def alive?(address : String) : Bool
      endpoint = Endpoint.parse(address)
      @lock.synchronize { @core.alive?(endpoint) }
    end

    # Yields each peer, including this node. Do not call the cluster from the block.
    def each(& : Peer ->) : Nil
      @lock.synchronize { @core.each { |peer| yield peer } }
    end

    private def run_io : Nil
      outbox = Outbox.new
      loop do
        break unless @running.get
        begin
          count, _ = @socket.receive(@recv)
        rescue IO::Error
          break unless @running.get
          sleep 1.milliseconds
          next
        end
        now = Time.instant
        @lock.synchronize do
          if plain = unwrap(@recv[0, count])
            @core.receive(plain, now) { |endpoint, bytes| outbox.add(endpoint, bytes, @seal) }
          end
        end
        outbox.flush(@socket)
        signal
      end
    ensure
      @io_stopped.set(true)
      finish
    end

    private def run_tick : Nil
      outbox = Outbox.new
      loop do
        break unless @running.get
        now = Time.instant
        wait = Time::Span.zero
        @lock.synchronize do
          @core.expire(now) { |endpoint, bytes| outbox.add(endpoint, bytes, @seal) }
          if now >= @next_tick
            @core.tick(now) { |endpoint, bytes| outbox.add(endpoint, bytes, @seal) }
            @next_tick = now + @period
          end
          wait = next_wait
        end
        outbox.flush(@socket)
        break unless @running.get
        pause(wait)
      end
    ensure
      @tick_stopped.set(true)
      finish
    end

    private def unwrap(bytes : Bytes) : Bytes?
      if seal = @seal
        size = seal.decrypt(bytes, @plain)
        return nil if size < 0
        @plain[0, size]
      else
        bytes
      end
    end

    private def next_wait : Time::Span
      soon = @next_tick
      now = Time.instant
      @core.each_deadline { |deadline| soon = deadline if deadline < soon }
      span = soon - now
      span < Time::Span.zero ? Time::Span.zero : span
    end

    private def pause(wait : Time::Span) : Nil
      select
      when @poke.receive
      when timeout(wait)
      end
    end

    # Wakes the ticker. A full channel already has a wake pending.
    private def signal : Nil
      select
      when @poke.send(nil)
      else
      end
    end

    private def finish : Nil
      return unless @io_stopped.get && @tick_stopped.get
      return if @signaled.swap(true)
      @done.send(nil)
    end

    # Four datagrams cover one probe plus three indirect checks.
    class Outbox
      SLOTS =   4
      SLOT  = 256

      def initialize
        @bytes = Bytes.new(SLOTS * SLOT)
        @endpoints = Slice(Endpoint).new(SLOTS, Endpoint.zero)
        @lengths = Slice(Int32).new(SLOTS, 0)
        @count = 0
      end

      # Copies one datagram. When `seal` is set, the ciphertext is written into this outbox.
      # Call this while the cluster lock is held. `Seal` is not safe for parallel use.
      def add(endpoint : Endpoint, plain : Bytes, seal : Seal?) : Nil
        offset = @count &* SLOT
        if seal
          size = seal.encrypt(plain, @bytes[offset, SLOT])
          return if size < 0
          @lengths[@count] = size
        else
          @bytes[offset, plain.size].copy_from(plain)
          @lengths[@count] = plain.size
        end
        @endpoints[@count] = endpoint
        @count &+= 1
      end

      def flush(socket : UDPSocket) : Nil
        count = @count
        @count = 0
        count.times do |index|
          offset = index &* SLOT
          socket.send(@bytes[offset, @lengths[index]], @endpoints[index].to_ip)
        rescue IO::Error
          nil
        end
      end
    end
  end
end
