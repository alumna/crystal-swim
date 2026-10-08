require "./swim/cluster"

module Swim
  VERSION = "0.2.1"

  # Joins a cluster. `advertise` is the address other nodes use, in `host:port` form.
  # `seeds` are known peers. Call `Cluster#stop` when this process leaves.
  def self.join(
    advertise : String,
    *,
    bind bind_address : String? = nil,
    seeds : Enumerable(String)? = nil,
    key : String? = nil,
    period : Time::Span = 1.second,
    timeout : Time::Span = 500.milliseconds,
    tombstone : Time::Span = 24.hours,
  ) : Cluster
    raise ArgumentError.new("Period must be positive") unless period > Time::Span.zero
    raise ArgumentError.new("Timeout must be positive") unless timeout > Time::Span.zero

    known = [] of Endpoint
    if seeds
      seeds.each { |seed| known << Endpoint.parse(seed) }
    end

    advertised = Endpoint.parse(advertise)
    bound = bind_address ? Endpoint.parse(bind_address) : advertised
    family = bound.v6? ? Socket::Family::INET6 : Socket::Family::INET
    socket = UDPSocket.new(family)
    bind_port = bound.port == 0 ? advertised.port.to_i : bound.port.to_i
    socket.bind(bound.host, bind_port)

    local_ip = socket.local_address.as?(Socket::IPAddress)
    raise Socket::Error.new("Expected an IP address") unless local_ip
    advertised = advertised.with_port(local_ip.port.to_u16) if advertised.port == 0

    now = Time.instant
    incarnation = Time.utc.to_unix_ms.to_u64
    core = Core.new(advertised, incarnation: incarnation, now: now, timeout: timeout, tombstone: tombstone)
    known.each { |seed| core.add(seed, 0_u64, Status::Alive, now) }

    seal = key ? Seal.new(key) : nil
    Cluster.new(socket, core, seal, period, local_ip.port)
  end

  # Joins a cluster and stops it when the block ends.
  def self.join(
    advertise : String,
    *,
    bind bind_address : String? = nil,
    seeds : Enumerable(String)? = nil,
    key : String? = nil,
    period : Time::Span = 1.second,
    timeout : Time::Span = 500.milliseconds,
    tombstone : Time::Span = 24.hours,
    & : Cluster ->
  ) : Nil
    cluster = join(advertise, bind: bind_address, seeds: seeds, key: key, period: period, timeout: timeout, tombstone: tombstone)
    begin
      yield cluster
    ensure
      cluster.stop
    end
  end
end
