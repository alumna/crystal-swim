require "./membership_list"
require "./message"
require "./effect"

module Swim
  class Protocol
    MAX_PIGGYBACK_SIZE          =  5
    MAX_LOCAL_HEALTH_MULTIPLIER =  5
    GC_TICK_INTERVAL            = 60

    getter local_member : Member
    getter members : MembershipList

    @seq_counter : UInt64 = 0_u64
    @tick_counter : UInt64 = 0_u64

    record PendingPing, target_id : String
    @pending_pings = Hash(UInt64, PendingPing).new

    record ProxyPing, origin_address : String, origin_seq : UInt64, target_id : String
    @proxy_pings = Hash(UInt64, ProxyPing).new

    # Lifeguard: Local Health Awareness
    getter local_health_multiplier : Int32 = 0
    @base_timeout : Time::Span
    @tombstone_ttl : Time::Span

    def initialize(
      @local_member : Member,
      @members : MembershipList,
      @ping_req_group_size : Int32 = 3,
      @base_timeout : Time::Span = 500.milliseconds,
      @tombstone_ttl : Time::Span = 24.hours,
    )
      @members.update(@local_member)
    end

    def on_tick : Array(Effect)
      effects = [] of Effect

      @tick_counter &+= 1_u64
      if (@tick_counter % GC_TICK_INTERVAL) == 0
        @members.cleanup_tombstones(@tombstone_ttl)
      end

      targets = @members.sample(1, exclude_ids: [@local_member.id], exclude_dead: true)

      return effects if targets.empty?

      target = targets.first
      seq = next_seq

      @pending_pings[seq] = PendingPing.new(target.id)

      msg = Message.new(MessageType::Ping, seq, @local_member.id, @local_member.address, changes: fetch_gossip)
      effects << SendMessage.new(target.address, msg)

      effects << ScheduleTimeout.new(dynamic_timeout, TimeoutType::DirectPing, seq)

      effects
    end

    def on_message(msg : Message) : Array(Effect)
      effects = [] of Effect

      msg.changes.each do |gossiped_member|
        apply_update(gossiped_member)
      end

      # Exhaustive matching: Compiler errors if a MessageType is added and not handled
      case msg.type
      in .ping?
        ack = Message.new(MessageType::Ack, msg.seq, @local_member.id, @local_member.address, changes: fetch_gossip)
        effects << SendMessage.new(msg.sender_address, ack)
      in .ack?
        if pending = @pending_pings.delete(msg.seq)
          mark_as(pending.target_id, State::Alive)
          improve_local_health
        end

        if proxy = @proxy_pings.delete(msg.seq)
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
      in .ping_req?
        if (target_id = msg.target_id) && (target_addr = msg.target_address)
          seq = next_seq
          @proxy_pings[seq] = ProxyPing.new(msg.sender_address, msg.seq, target_id)

          proxy_ping = Message.new(MessageType::Ping, seq, @local_member.id, @local_member.address, changes: fetch_gossip)
          effects << SendMessage.new(target_addr, proxy_ping)

          effects << ScheduleTimeout.new(dynamic_timeout, TimeoutType::IndirectPingReq, seq)
        end
      end

      effects
    end

    def on_timeout(seq : UInt64, type : TimeoutType) : Array(Effect)
      effects = [] of Effect

      # Exhaustive matching for TimeoutType
      case type
      in .direct_ping?
        if pending = @pending_pings[seq]?
          target = @members.get(pending.target_id)

          if target
            helpers = @members.sample(@ping_req_group_size, exclude_ids: [@local_member.id, target.id], exclude_dead: true)

            helpers.each do |helper|
              req = Message.new(
                type: MessageType::PingReq,
                seq: seq,
                sender_id: @local_member.id,
                sender_address: @local_member.address,
                target_id: target.id,
                target_address: target.address,
                changes: fetch_gossip
              )
              effects << SendMessage.new(helper.address, req)
            end

            effects << ScheduleTimeout.new(dynamic_timeout, TimeoutType::IndirectPingReq, seq)
          end
        end
      in .indirect_ping_req?
        if pending = @pending_pings.delete(seq)
          target = @members.get(pending.target_id)

          if target && target.state == State::Suspect
            mark_as(pending.target_id, State::Dead)
          else
            mark_as(pending.target_id, State::Suspect)
          end

          degrade_local_health
        end

        @proxy_pings.delete(seq)
      end

      effects
    end

    private def next_seq : UInt64
      @seq_counter &+= 1_u64
      @seq_counter
    end

    private def mark_as(id : String, state : State) : Nil
      if member = @members.get(id)
        # Skip unnecessary allocations and list updates if the state is already correct
        return if member.state == state
        apply_update(member.copy_with(state: state))
      end
    end

    private def apply_update(member : Member) : Nil
      if member.id == @local_member.id
        if member.state.suspect? || member.state.dead?
          new_incarnation = @local_member.incarnation + 1_u64
          @local_member = @local_member.copy_with(incarnation: new_incarnation, state: State::Alive)
          @members.update(@local_member)
        end
        return
      end

      @members.update(member)
    end

    private def fetch_gossip : Array(Member)
      gossip = @members.sample(MAX_PIGGYBACK_SIZE - 1, exclude_ids: [@local_member.id])
      gossip << @local_member
      gossip
    end

    private def dynamic_timeout : Time::Span
      @base_timeout * (1 + @local_health_multiplier)
    end

    private def improve_local_health : Nil
      @local_health_multiplier = (@local_health_multiplier - 1).clamp(0, MAX_LOCAL_HEALTH_MULTIPLIER)
    end

    private def degrade_local_health : Nil
      @local_health_multiplier = (@local_health_multiplier + 1).clamp(0, MAX_LOCAL_HEALTH_MULTIPLIER)
    end
  end
end
