require "./peer"

module Swim
  # Binary SWIM packet. The layout is fixed so encode and decode do not allocate.
  #
  # ```
  # 0  magic "SWIM"     4
  # 4  version          1
  # 5  type             1
  # 6  change count     1
  # 7  flags            1
  # 8  sequence         8
  # 16 sender endpoint  19
  # 35 target endpoint  19
  # 54 changes          28 each, at most 5
  # ```
  #
  # An endpoint is family (1), port (2), address (16).
  module Wire
    VERSION     = 1_u8
    PING        = 1_u8
    ACK         = 2_u8
    PING_REQ    = 3_u8
    ENDPOINT    =   19
    HEADER      =   54
    CHANGE      =   28
    MAX_CHANGES =    5
    MAX_BYTES   = HEADER + MAX_CHANGES * CHANGE

    struct View
      getter type : UInt8
      getter seq : UInt64
      getter sender : Endpoint
      getter target : Endpoint
      getter changes : Int32

      def initialize(@type : UInt8, @seq : UInt64, @sender : Endpoint, @target : Endpoint, @changes : Int32)
      end
    end

    # Writes the header. The change count starts at 0.
    def self.open(buf : Bytes, type : UInt8, seq : UInt64, sender : Endpoint, target : Endpoint) : Nil
      buf[0] = 'S'.ord.to_u8
      buf[1] = 'W'.ord.to_u8
      buf[2] = 'I'.ord.to_u8
      buf[3] = 'M'.ord.to_u8
      buf[4] = VERSION
      buf[5] = type
      buf[6] = 0_u8
      buf[7] = 0_u8
      write_u64(buf, 8, seq)
      write_endpoint(buf, 16, sender)
      write_endpoint(buf, 35, target)
    end

    # Writes one gossip change and stores the new count.
    def self.store(buf : Bytes, index : Int32, endpoint : Endpoint, incarnation : UInt64, status : Status) : Nil
      at = HEADER &+ index &* CHANGE
      write_endpoint(buf, at, endpoint)
      write_u64(buf, at &+ ENDPOINT, incarnation)
      buf[at &+ ENDPOINT &+ 8] = status.value
      # kcov misses this integer conversion. Specs check the stored count.
      buf[6] = (index &+ 1).to_u8 # LCOV_EXCL_LINE
    end

    def self.bytes(count : Int32) : Int32
      HEADER &+ count &* CHANGE
    end

    # Returns nil when the bytes are not a SWIM packet.
    def self.view?(buf : Bytes) : View?
      return nil if buf.size < HEADER
      return nil unless buf[0] === 'S' && buf[1] === 'W' && buf[2] === 'I' && buf[3] === 'M'
      return nil unless buf[4] == VERSION
      type = buf[5]
      return nil unless type == PING || type == ACK || type == PING_REQ
      count = buf[6].to_i32
      return nil if count > MAX_CHANGES
      return nil if buf.size < bytes(count)
      count.times do |index|
        return nil unless Status.from_value?(status_byte(buf, index))
      end
      View.new(type, read_u64(buf, 8), read_endpoint(buf, 16), read_endpoint(buf, 35), count)
    end

    def self.change(buf : Bytes, index : Int32) : {Endpoint, UInt64, Status}
      at = HEADER &+ index &* CHANGE
      status = Status.from_value(status_byte(buf, index))
      {read_endpoint(buf, at), read_u64(buf, at &+ ENDPOINT), status}
    end

    private def self.status_byte(buf : Bytes, index : Int32) : UInt8
      buf[HEADER &+ index &* CHANGE &+ ENDPOINT &+ 8]
    end

    private def self.write_endpoint(buf : Bytes, at : Int32, endpoint : Endpoint) : Nil
      buf[at] = endpoint.family
      write_u16(buf, at &+ 1, endpoint.port)
      16.times { |index| buf[at &+ 3 &+ index] = endpoint.octets[index] }
    end

    private def self.read_endpoint(buf : Bytes, at : Int32) : Endpoint
      octets = StaticArray(UInt8, 16).new(0_u8)
      16.times { |index| octets[index] = buf[at &+ 3 &+ index] }
      Endpoint.new(buf[at], read_u16(buf, at &+ 1), octets)
    end

    private def self.write_u16(buf : Bytes, at : Int32, value : UInt16) : Nil
      buf[at] = (value & 0xFF).to_u8
      buf[at &+ 1] = (value >> 8).to_u8
    end

    private def self.read_u16(buf : Bytes, at : Int32) : UInt16
      buf[at].to_u16 | (buf[at &+ 1].to_u16 << 8)
    end

    private def self.write_u64(buf : Bytes, at : Int32, value : UInt64) : Nil
      8.times { |index| buf[at &+ index] = ((value >> (8 &* index)) & 0xFF).to_u8 }
    end

    private def self.read_u64(buf : Bytes, at : Int32) : UInt64
      value = 0_u64
      8.times { |index| value |= buf[at &+ index].to_u64 << (8 &* index) }
      value
    end
  end
end
