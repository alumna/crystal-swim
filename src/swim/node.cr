require "socket"
require "json"
require "sync"
require "./protocol"

module Swim
  class Node
    getter protocol : Protocol
    # Exposing the socket to allow users to set advanced UDP flags if needed
    getter socket : UDPSocket

    @socket : UDPSocket
    @running = Atomic(Bool).new(false)

    # Protects the purely functional Protocol from concurrent fiber access
    @protocol_lock = Sync::Mutex.new

    # IP Parsing cache for performance
    @addr_cache = Hash(String, Socket::IPAddress).new
    @addr_cache_lock = Sync::Mutex.new

    def initialize(@protocol : Protocol, @host : String, @port : Int32)
      @socket = UDPSocket.new
      @socket.bind(@host, @port)
    end

    # Starts the background engine.
    def start(tick_interval : Time::Span = 1.second) : Nil
      return if @running.swap(true) # Prevent double-starting

      spawn(name: "swim_listener") { listen_loop }
      spawn(name: "swim_ticker") { tick_loop(tick_interval) }
    end

    def stop : Nil
      return unless @running.swap(false)
      @socket.close rescue nil
    end

    private def listen_loop
      buffer = Bytes.new(2048)

      while @running.get && !@socket.closed?
        begin
          bytes_read, _client_addr = @socket.receive(buffer)
          msg_json = String.new(buffer[0, bytes_read])
          msg = Message.from_json(msg_json)

          effects = @protocol_lock.synchronize { @protocol.on_message(msg) }
          process_effects(effects)
        rescue JSON::ParseException
          # Bad network packet - silently drop and continue
          next
        rescue IO::Error
          # Socket closed or unroutable
          break if @socket.closed?
          break unless @running.get
        end
      end
    end

    private def tick_loop(interval : Time::Span)
      while @running.get
        effects = @protocol_lock.synchronize { @protocol.on_tick }
        process_effects(effects)

        # Sleep until the next cycle, but allow safe exit on shutdown
        sleep interval
      end
    end

    private def process_effects(effects : Array(Effect))
      effects.each do |effect|
        case effect
        when SendMessage
          begin
            target_addr = get_target_address(effect.address)
            @socket.send(effect.message.to_json, target_addr)
          rescue ex : IO::Error
            # Silently drop unroutable packets; protocol logic handles it
            nil
          end
        when ScheduleTimeout
          spawn(name: "swim_timeout_#{effect.seq}") do
            sleep effect.duration

            if @running.get
              timeout_effects = @protocol_lock.synchronize do
                @protocol.on_timeout(effect.seq, effect.type)
              end
              process_effects(timeout_effects)
            end
          end
        end
      end
    end

    private def get_target_address(addr_str : String) : Socket::IPAddress
      @addr_cache_lock.synchronize do
        @addr_cache[addr_str] ||= begin
          host, port = addr_str.split(":", 2)
          Socket::IPAddress.new(host, port.to_i)
        end
      end
    end
  end
end
