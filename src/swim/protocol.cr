require "./membership_list"
require "./message"
require "./effect"

module Swim
  class Protocol
    getter local_member : Member
    getter members : MembershipList

    @seq_counter : UInt64 = 0_u64

    record PendingPing, target_id : String
    @pending_pings = Hash(UInt64, PendingPing).new

    record ProxyPing, origin_address : String, origin_seq : UInt64, target_id : String
    @proxy_pings = Hash(UInt64, ProxyPing).new

    # A simple queue of state changes that need to be broadcasted to the cluster.
    @gossip_queue = [] of Member
    @max_piggyback_size : Int32 = 5

    def initialize(@local_member : Member, @members : MembershipList, @ping_req_group_size : Int32 = 3)
      @members.update(@local_member)
    end

    def on_tick : Array(Effect)
      effects = [] of Effect
      targets = @members.sample(1, exclude_ids: [@local_member.id])

      return effects if targets.empty?

      target = targets.first
      seq = next_seq

      @pending_pings[seq] = PendingPing.new(target.id)

      # Attach gossip to the outgoing Ping
      msg = Message.new(MessageType::Ping, seq, @local_member.id, @local_member.address, changes: fetch_gossip)
      effects << SendMessage.new(target.address, msg)

      effects << ScheduleTimeout.new(500.milliseconds, TimeoutType::DirectPing, seq)

      effects
    end

    def on_message(msg : Message) : Array(Effect)
      effects = [] of Effect

      # Process any piggybacked gossip from the sender
      msg.changes.each do |gossiped_member|
        apply_update(gossiped_member)
      end

      case msg.type
      when MessageType::Ping
        # Attach gossip to the returning Ack
        ack = Message.new(MessageType::Ack, msg.seq, @local_member.id, @local_member.address, changes: fetch_gossip)
        effects << SendMessage.new(msg.sender_address, ack)
      when MessageType::Ack
        if pending = @pending_pings.delete(msg.seq)
          mark_alive(pending.target_id)
        end

        if proxy = @proxy_pings.delete(msg.seq)
          # Attach gossip to the forwarded Ack
          forwarded_ack = Message.new(
            type: MessageType::Ack,
            seq: proxy.origin_seq,
            sender_id: @local_member.id,
            sender_address: @local_member.address,
            target_id: proxy.target_id,
            changes: fetch_gossip
          )
          effects << SendMessage.new(proxy.origin_address, forwarded_ack)
        end
      when MessageType::PingReq
        if (target_id = msg.target_id) && (target_addr = msg.target_address)
          seq = next_seq
          @proxy_pings[seq] = ProxyPing.new(msg.sender_address, msg.seq, target_id)

          # Attach gossip to the Proxy Ping
          proxy_ping = Message.new(MessageType::Ping, seq, @local_member.id, @local_member.address, changes: fetch_gossip)
          effects << SendMessage.new(target_addr, proxy_ping)

          effects << ScheduleTimeout.new(500.milliseconds, TimeoutType::IndirectPingReq, seq)
        end
      end

      effects
    end

    def on_timeout(seq : UInt64, type : TimeoutType) : Array(Effect)
      effects = [] of Effect

      case type
      when TimeoutType::DirectPing
        if pending = @pending_pings[seq]?
          target = @members.get(pending.target_id)

          if target
            helpers = @members.sample(@ping_req_group_size, exclude_ids: [@local_member.id, target.id])

            helpers.each do |helper|
              req = Message.new(
                type: MessageType::PingReq,
                seq: seq,
                sender_id: @local_member.id,
                sender_address: @local_member.address,
                target_id: target.id,
                target_address: target.address,
                changes: fetch_gossip # Attach gossip to PingReq
              )
              effects << SendMessage.new(helper.address, req)
            end

            effects << ScheduleTimeout.new(500.milliseconds, TimeoutType::IndirectPingReq, seq)
          end
        end
      when TimeoutType::IndirectPingReq
        if pending = @pending_pings.delete(seq)
          mark_suspect(pending.target_id)
        end

        @proxy_pings.delete(seq)
      end

      effects
    end

    private def next_seq : UInt64
      @seq_counter &+= 1_u64
      @seq_counter
    end

    private def mark_alive(id : String) : Nil
      if member = @members.get(id)
        apply_update(member.copy_with(state: State::Alive))
      end
    end

    private def mark_suspect(id : String) : Nil
      if member = @members.get(id)
        # We increase the incarnation number locally if we are declaring them suspect.
        # This allows the suspected node to refute the suspicion later by broadcasting a higher incarnation.
        updated_member = member.copy_with(state: State::Suspect)
        apply_update(updated_member)
      end
    end

    # Tries to apply the member to the list. If it's a genuine update (newer incarnation or worse state),
    # it adds it to the gossip queue so we spread the news.
    private def apply_update(member : Member) : Nil
      # Never accept state updates about ourselves from others that claim we are Dead/Suspect.
      # (In a fully extended SWIM implementation with Lifeguard, we would actually increment
      # our own incarnation number here and refute it, but we ignore it for now).
      return if member.id == @local_member.id && member.state != State::Alive

      if @members.update(member)
        @gossip_queue << member
      end
    end

    # Pulls up to N items from the queue to attach to a message.
    # In a mature system, elements are gossiped K times before removal.
    # For simplicity, we just shift them off the queue once.
    private def fetch_gossip : Array(Member)
      # Pull up to max_piggyback_size items from the front of the queue
      size_to_take = Math.min(@gossip_queue.size, @max_piggyback_size)
      @gossip_queue.shift(size_to_take)
    end
  end
end
