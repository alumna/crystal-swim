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
      # 2KB safely fits any standard ~1400B MTU UDP packet without truncation
      buffer = Bytes.new(2048)

      # Ensure we do not even try to loop if the socket is closed
      while @running.get && !@socket.closed?
        begin
          bytes_read, _client_addr = @socket.receive(buffer)
          msg_json = String.new(buffer[0, bytes_read])
          msg = Message.from_json(msg_json)

          effects = @protocol_lock.synchronize { @protocol.on_message(msg) }
          process_effects(effects)
        rescue ex : IO::Error | JSON::ParseException
          # If the socket was closed out from under us, break immediately
          break if @socket.closed?

          # Otherwise, it might be a transient routing error or bad JSON packet.
          # We ignore it and continue listening.
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
            host, port_str = effect.address.split(":", 2)
            target_addr = Socket::IPAddress.new(host, port_str.to_i)
            @socket.send(effect.message.to_json, target_addr)
          rescue ex : IO::Error
            # UDP sends can fail for routing issues (e.g., EHOSTUNREACH).
            # We silently drop the packet; the protocol's timeout logic handles the failure.
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
  end
end
