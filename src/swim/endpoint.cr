require "socket"

module Swim
  # A UDP peer address. The value is 20 bytes and compares without a heap allocation.
  struct Endpoint
    getter family : UInt8
    getter port : UInt16

    # Address bytes. IPv4 uses the first 4 bytes. IPv6 uses all 16 bytes.
    getter octets : StaticArray(UInt8, 16)

    def initialize(@family : UInt8, @port : UInt16, @octets : StaticArray(UInt8, 16))
    end

    # An empty address. A packet uses this when it has no target.
    def self.zero : Endpoint
      new(0_u8, 0_u16, StaticArray(UInt8, 16).new(0_u8))
    end

    # Parses `host:port` or `[ipv6]:port`.
    def self.parse(text : String) : Endpoint
      if text.starts_with?('[')
        close = text.index(']')
        raise ArgumentError.new("Invalid address") unless close
        host = text.byte_slice(1, close - 1)
        tail = text.byte_slice(close + 1)
        raise ArgumentError.new("Invalid address") unless tail.starts_with?(':')
        port = port_of(tail.byte_slice(1))
        fields = Socket::IPAddress.parse_v6_fields?(host)
        raise ArgumentError.new("Invalid address") unless fields
        return from_v6(fields, port)
      end

      colon = text.rindex(':')
      raise ArgumentError.new("Invalid address") unless colon
      host = text.byte_slice(0, colon)
      port = port_of(text.byte_slice(colon + 1))
      fields = Socket::IPAddress.parse_v4_fields?(host)
      raise ArgumentError.new("Invalid address") unless fields
      from_v4(fields, port)
    end

    def self.from_v4(fields : UInt8[4], port : UInt16) : Endpoint
      octets = StaticArray(UInt8, 16).new(0_u8)
      4.times { |index| octets[index] = fields[index] }
      new(4_u8, port, octets)
    end

    def self.from_v6(fields : UInt16[8], port : UInt16) : Endpoint
      octets = StaticArray(UInt8, 16).new(0_u8)
      8.times do |index|
        octets[index &* 2] = (fields[index] >> 8).to_u8
        octets[index &* 2 &+ 1] = (fields[index] & 0xFF).to_u8
      end
      new(6_u8, port, octets)
    end

    def with_port(port : UInt16) : Endpoint
      Endpoint.new(@family, port, @octets)
    end

    def v4? : Bool
      @family == 4
    end

    def v6? : Bool
      @family == 6
    end

    # Builds a socket address on the stack. No string is allocated.
    def to_ip : Socket::IPAddress
      if v4?
        fields = uninitialized UInt8[4]
        4.times { |index| fields[index] = @octets[index] }
        Socket::IPAddress.v4(fields, @port)
      elsif v6?
        words = uninitialized UInt16[8]
        8.times do |index|
          hi = @octets[index &* 2].to_u16 << 8
          lo = @octets[index &* 2 &+ 1].to_u16
          words[index] = hi | lo
        end
        Socket::IPAddress.v6(words, @port)
      else
        raise ArgumentError.new("Invalid address")
      end
    end

    # Host text for `UDPSocket#bind`. This allocates one string.
    def host : String
      return to_ip.address if v6?
      String.build { |io| write_host(io) }
    end

    def ==(other : Endpoint) : Bool
      @family == other.family && @port == other.port && @octets == other.octets
    end

    # FNV-1a mix for the membership table. The method does not allocate.
    def mix : UInt32
      hash = 2166136261_u32
      hash = (hash ^ @family) &* 16777619
      hash = (hash ^ (@port & 0xFF).to_u8) &* 16777619
      hash = (hash ^ (@port >> 8).to_u8) &* 16777619
      16.times { |index| hash = (hash ^ @octets[index]) &* 16777619 }
      hash
    end

    def to_s(io : IO) : Nil
      if v4?
        write_host(io)
        io << ':' << @port
      elsif v6?
        io << '[' << to_ip.address << "]:" << @port
      end
    end

    private def write_host(io : IO) : Nil
      io << @octets[0] << '.' << @octets[1] << '.' << @octets[2] << '.' << @octets[3]
    end

    private def self.port_of(text : String) : UInt16
      port = text.to_i?(whitespace: false)
      raise ArgumentError.new("Invalid port") unless port
      raise ArgumentError.new("Invalid port") unless 0 <= port <= 65535
      # kcov misses this integer conversion. Specs check the parsed port.
      port.to_u16 # LCOV_EXCL_LINE
    end
  end
end
