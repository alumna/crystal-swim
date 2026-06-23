require "./message"

module Swim
  enum TimeoutType
    DirectPing
    IndirectPingReq
  end

  alias Effect = SendMessage | ScheduleTimeout

  record SendMessage, address : String, message : Message
  record ScheduleTimeout, duration : Time::Span, type : TimeoutType, seq : UInt64
end
