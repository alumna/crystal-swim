require "socket"
require "json"
require "sync"
require "digest/sha256"
require "./protocol"

module Swim
  class Node
    getter protocol : Protocol
    getter socket : UDPSocket

    @socket : UDPSocket
    @running = Atomic(Bool).new(false)
    @protocol_lock = Sync::Mutex.new

    @addr_cache = Hash(String, Socket::IPAddress).new
    @addr_cache_lock = Sync::Mutex.new

    # Store the processed 32-byte symmetric key, if provided
    @encryption_key : Bytes?

    def initialize(@protocol : Protocol, @host : String, @port : Int32, encryption_key : String? = nil)
      @socket = UDPSocket.new
      @socket.bind(@host, @port)

      if key = encryption_key
        # Hash any length string into exactly 32 bytes for AES-256
        @encryption_key = Digest::SHA256.digest(key).to_slice
      end
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
          packet = buffer[0, bytes_read]

          # Decrypt if a key is configured, otherwise read raw JSON
          msg_json = if key = @encryption_key
                       Cipher.decrypt(packet, key)
                     else
                       String.new(packet)
                     end

          msg = Message.from_json(msg_json)

          effects = @protocol_lock.synchronize { @protocol.on_message(msg) }
          process_effects(effects)
        rescue OpenSSL::Cipher::Error
          # Invalid cluster key or tampered packet - drop
        rescue JSON::ParseException
          # Bad network packet - silently drop and continue
        rescue IO::Error
          # Transient UDP error or socket closed on shutdown.
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
            plaintext = effect.message.to_json

            # Encrypt if a key is configured, otherwise send raw JSON
            payload = if key = @encryption_key
                        Cipher.encrypt(plaintext, key)
                      else
                        plaintext.to_slice
                      end

            @socket.send(payload, target_addr)
          rescue ex : IO::Error
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
