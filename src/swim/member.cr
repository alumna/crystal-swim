require "json"

module Swim
  # Represents the known state of a node in the cluster.
  # The integer values map perfectly to SWIM precedence (Dead > Suspect > Alive).
  enum State
    Alive   = 0
    Suspect = 1
    Dead    = 2
  end

  # A functional representation of a cluster member.
  # Instances are immutable; state changes are handled by replacing the record.
  record Member, id : String, address : String, incarnation : UInt64, state : State do
    include JSON::Serializable

    # Determines if this member's state should overwrite an existing member's state,
    # following standard SWIM conflict resolution rules.
    def overrides?(other : Member) : Bool
      # 1. Higher incarnation always wins
      return true if self.incarnation > other.incarnation
      return false if self.incarnation < other.incarnation

      # 2. If incarnations are equal, state precedence applies: Dead > Suspect > Alive
      self.state.value > other.state.value
    end
  end
end
