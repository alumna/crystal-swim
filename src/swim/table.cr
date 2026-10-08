require "./peer"

module Swim
  # Open-address table of peers. Lookup and update of a known peer do not allocate.
  # The table allocates only when it grows, or when it compacts tombstones.
  class Table
    EMPTY = 0_u8
    LIVE  = 1_u8
    TOMB  = 2_u8

    @slots : Slice(Slot)
    @order : Slice(Int32)
    @order_pos : Slice(Int32)
    @cap : Int32
    @live : Int32
    @tombs : Int32
    @order_n : Int32

    def initialize(@random : Random)
      @slots = Slice(Slot).empty
      @order = Slice(Int32).empty
      @order_pos = Slice(Int32).empty
      @cap = 0
      @live = 0
      @tombs = 0
      @order_n = 0
    end

    def size : Int32
      @live
    end

    def find(endpoint : Endpoint) : Peer?
      index = find_index(endpoint)
      return nil if index < 0
      @slots[index].peer
    end

    # Inserts or replaces a peer. A replace does not allocate.
    def put(peer : Peer) : Nil
      if (index = find_index(peer.endpoint)) >= 0
        slot = @slots[index]
        slot.peer = peer
        @slots[index] = slot
        return
      end
      grow if @cap == 0 || (@live &+ @tombs) &* 4 >= @cap &* 3
      insert_new(peer)
    end

    def each(& : Peer ->) : Nil
      @order_n.times { |index| yield @slots[@order[index]].peer }
    end

    # Picks up to `want` peers. The shuffle uses the order array in place.
    # `skip_dead` keeps failed peers out of probes. Gossip leaves it false.
    def sample(want : Int32, skip_dead : Bool, exclude_a : Endpoint, exclude_b : Endpoint = Endpoint.zero, & : Peer ->) : Nil
      return if want <= 0 || @order_n == 0
      found = 0
      index = 0
      while index < @order_n && found < want
        span = @order_n &- index
        pick = index &+ @random.rand(span)
        swap_order(index, pick)
        peer = @slots[@order[index]].peer
        index &+= 1
        next if peer.endpoint == exclude_a || peer.endpoint == exclude_b
        next if skip_dead && peer.dead?
        found &+= 1
        yield peer
      end
    end

    # Removes dead peers whose update time is at or before `before`.
    # The local peer is kept.
    def delete_dead(before : Time::Instant, keep : Endpoint) : Nil
      index = 0
      while index < @order_n
        peer = @slots[@order[index]].peer
        if peer.endpoint != keep && peer.dead? && peer.updated <= before
          delete_order(index)
        else
          index &+= 1
        end
      end
      compact if @tombs > 32 && @tombs > @live
    end

    private def find_index(endpoint : Endpoint) : Int32
      return -1 if @cap == 0
      mask = @cap &- 1
      start = (endpoint.mix & mask.to_u32).to_i
      found = -1
      @cap.times do |step|
        index = (start.to_i &+ step) & mask
        slot = @slots[index]
        case slot.tag
        when EMPTY
          return -1
        when LIVE
          if slot.peer.endpoint == endpoint
            found = index
            break
          end
        else
          # A tombstone. Keep probing.
        end
      end
      found
    end

    private def insert_new(peer : Peer) : Nil
      mask = @cap &- 1
      start = (peer.endpoint.mix & mask.to_u32).to_i
      @cap.times do |step|
        index = (start &+ step) & mask
        slot = @slots[index]
        next if slot.tag == LIVE
        was_tomb = slot.tag == TOMB
        slot.tag = LIVE
        slot.peer = peer
        @slots[index] = slot
        @tombs &-= 1 if was_tomb
        @live &+= 1
        @order[@order_n] = index
        @order_pos[index] = @order_n
        @order_n &+= 1
        return
      end
    end

    private def delete_order(order_index : Int32) : Nil
      slot_index = @order[order_index]
      slot = @slots[slot_index]
      slot.tag = TOMB
      @slots[slot_index] = slot
      @live &-= 1
      @tombs &+= 1
      last = @order_n &- 1
      if order_index != last
        moved = @order[last]
        @order[order_index] = moved
        @order_pos[moved] = order_index
      end
      @order_pos[slot_index] = -1
      @order_n = last
    end

    private def swap_order(left : Int32, right : Int32) : Nil
      return if left == right
      first = @order[left]
      second = @order[right]
      @order[left] = second
      @order[right] = first
      @order_pos[first] = right
      @order_pos[second] = left
    end

    private def grow : Nil
      rehash(@cap == 0 ? 16 : @cap &* 2)
    end

    private def compact : Nil
      rehash(@cap)
    end

    private def rehash(capacity : Int32) : Nil
      previous = @slots
      previous_n = @cap
      @cap = capacity
      @slots = Slice(Slot).new(@cap, Slot.empty)
      @order = Slice(Int32).new(@cap, 0)
      @order_pos = Slice(Int32).new(@cap, -1)
      @live = 0
      @tombs = 0
      @order_n = 0
      previous_n.times do |index|
        slot = previous[index]
        insert_new(slot.peer) if slot.tag == LIVE
      end
    end

    struct Slot
      property tag : UInt8
      property peer : Peer

      def initialize(@tag : UInt8, @peer : Peer)
      end

      def self.empty : Slot
        octets = StaticArray(UInt8, 16).new(0_u8)
        endpoint = Endpoint.new(0_u8, 0_u16, octets)
        ip = Socket::IPAddress.v4(uninitialized_v4, 0_u16)
        peer = Peer.new(endpoint, 0_u64, Status::Alive, Time.instant, ip)
        Slot.new(EMPTY, peer)
      end

      private def self.uninitialized_v4 : UInt8[4]
        fields = uninitialized UInt8[4]
        fields[0] = 0_u8
        fields[1] = 0_u8
        fields[2] = 0_u8
        fields[3] = 0_u8
        fields
      end
    end
  end
end
