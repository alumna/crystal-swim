require "json"
require "./member"

module Swim
  enum MessageType
    Ping
    Ack
    PingReq
  end

  record Message,
    type : MessageType,
    seq : UInt64,
    sender_id : String,
    sender_address : String,
    target_id : String? = nil,
    target_address : String? = nil,
    # This is the Piggybacked Gossip. Defaults to empty to save bytes.
    changes : Array(Member) = [] of Member do
    include JSON::Serializable
  end
end
