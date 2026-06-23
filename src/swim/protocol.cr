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

    @max_piggyback_size : Int32 = 5

    # Lifeguard: Local Health Awareness
    getter local_health_multiplier : Int32 = 0
    @max_local_health_multiplier : Int32 = 5
    @base_timeout : Time::Span = 500.milliseconds

    def initialize(@local_member : Member, @members : MembershipList, @ping_req_group_size : Int32 = 3)
      @members.update(@local_member)
    end

    def on_tick : Array(Effect)
      effects = [] of Effect

      # We do not ping ourselves, and we do not waste network traffic pinging DEAD nodes
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

      case msg.type
      when MessageType::Ping
        ack = Message.new(MessageType::Ack, msg.seq, @local_member.id, @local_member.address, changes: fetch_gossip)
        effects << SendMessage.new(msg.sender_address, ack)
      when MessageType::Ack
        if pending = @pending_pings.delete(msg.seq)
          mark_alive(pending.target_id)
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
      when MessageType::PingReq
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

      case type
      when TimeoutType::DirectPing
        if pending = @pending_pings[seq]?
          target = @members.get(pending.target_id)

          if target
            # Do not ask dead nodes to help us proxy pings
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
      when TimeoutType::IndirectPingReq
        if pending = @pending_pings.delete(seq)
          target = @members.get(pending.target_id)

          # The transition: If they were already Suspect and failed again, they are Dead.
          if target && target.state == State::Suspect
            mark_dead(pending.target_id)
          else
            mark_suspect(pending.target_id)
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

    private def mark_alive(id : String) : Nil
      if member = @members.get(id)
        apply_update(member.copy_with(state: State::Alive))
      end
    end

    private def mark_suspect(id : String) : Nil
      if member = @members.get(id)
        updated_member = member.copy_with(state: State::Suspect)
        apply_update(updated_member)
      end
    end

    private def mark_dead(id : String) : Nil
      if member = @members.get(id)
        updated_member = member.copy_with(state: State::Dead)
        apply_update(updated_member)
      end
    end

    private def apply_update(member : Member) : Nil
      if member.id == @local_member.id
        if member.state == State::Suspect
          new_incarnation = @local_member.incarnation + 1_u64
          @local_member = @local_member.copy_with(incarnation: new_incarnation, state: State::Alive)
          @members.update(@local_member)
        end
        return
      end

      @members.update(member)
    end

    # Randomized Gossip: Simply grab random members from our list.
    # Note: exclude_dead is false, so we DO gossip tombstones to ensure the cluster learns of deaths.
    private def fetch_gossip : Array(Member)
      @members.sample(@max_piggyback_size)
    end

    private def dynamic_timeout : Time::Span
      @base_timeout * (1 + @local_health_multiplier)
    end

    private def improve_local_health : Nil
      @local_health_multiplier -= 1 unless @local_health_multiplier == 0
    end

    private def degrade_local_health : Nil
      @local_health_multiplier += 1 unless @local_health_multiplier >= @max_local_health_multiplier
    end
  end
end
