require "spec"
require "../src/swim"

module SwimSpec
  def self.endpoint(host : String, port : Int32) : Swim::Endpoint
    Swim::Endpoint.parse("#{host}:#{port}")
  end

  def self.at(port : Int32) : Swim::Endpoint
    endpoint("10.0.0.1", port)
  end

  def self.core(port : Int32, *, now : Time::Instant, timeout : Time::Span = 100.milliseconds, tombstone : Time::Span = 24.hours, incarnation : UInt64 = 1_u64, seed : Int32 = 1) : Swim::Core
    Swim::Core.new(
      at(port),
      incarnation: incarnation,
      now: now,
      timeout: timeout,
      tombstone: tombstone,
      random: Random.new(seed),
    )
  end
end
