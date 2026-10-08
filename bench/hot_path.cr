require "../src/swim"

# Release-mode measurements for the hot path.
# Build: crystal build bench/hot_path.cr -o bin/hot_path --release
# Run:   ./bin/hot_path wire|cipher|sample|memory|peak-wire|peak-cipher|peak-sample
#
# Baseline 0.2.1 on the same host, 20000 iterations:
# wire   0.157333 s, 127119 ops/s, 7727 bytes/op, heap 1052672, VmHWM 7740 KiB
# cipher 0.068440 s, 292226 ops/s, 1380 bytes/op, heap 524288, VmHWM 10096 KiB
# sample 0.349297 s, 57257 ops/s, 80240 bytes/op, heap 1867776, VmHWM 8452 KiB
# memory 1000 peers and 5000 ticks: heap 2629632, VmHWM 9280 KiB

ITERATIONS = 20_000

def hwm_kb : UInt64
  File.read("/proc/self/status").each_line do |line|
    if line.starts_with?("VmHWM:")
      return line.split[1].to_u64
    end
  end
  0_u64
end

def time_ops(iterations : Int32, &) : {Time::Span, Int64}
  iterations.times { yield }
  GC.collect
  started = Time.instant
  iterations.times { yield }
  elapsed = started.elapsed
  {elapsed, (iterations / elapsed.total_seconds).to_i64}
end

def alloc_bytes(iterations : Int32, &) : Int64
  iterations.times { yield }
  GC.collect
  GC.disable
  before = GC.stats.total_bytes
  iterations.times { yield }
  after = GC.stats.total_bytes
  GC.enable
  (after &- before).to_i64
end

def report(name : String, iterations : Int32, &) : Nil
  elapsed, ops = time_ops(iterations) { yield }
  bytes = alloc_bytes(iterations) { yield }
  GC.collect
  puts "#{name}\t#{iterations}\t#{elapsed.total_seconds.round(6)}\t#{ops}\t#{bytes}\t#{(bytes / iterations).to_i64}\t#{GC.stats.heap_size}\t#{hwm_kb}"
end

def build_pair : {Swim::Core, Swim::Core, Time::Instant}
  now = Time.instant
  left_endpoint = Swim::Endpoint.parse("10.0.0.1:5000")
  right_endpoint = Swim::Endpoint.parse("10.0.0.2:5000")
  left = Swim::Core.new(left_endpoint, now: now, random: Random.new(1))
  right = Swim::Core.new(right_endpoint, now: now, random: Random.new(2))
  left.add(right_endpoint, 1_u64, Swim::Status::Alive, now)
  right.add(left_endpoint, 1_u64, Swim::Status::Alive, now)
  {left, right, now}
end

def wire_cycle(left : Swim::Core, right : Swim::Core, now : Time::Instant) : Nil
  left.tick(now) do |_, bytes|
    right.receive(bytes, now) do |_, reply|
      left.receive(reply, now) { }
    end
  end
end

def build_table : {Swim::Table, Swim::Endpoint}
  now = Time.instant
  table = Swim::Table.new(Random.new(1))
  1000.times do |index|
    endpoint = Swim::Endpoint.parse("10.0.#{index // 250}.#{index % 250}:#{10000 + index}")
    table.put(Swim::Peer.new(endpoint, 1_u64, Swim::Status::Alive, now, endpoint.to_ip))
  end
  {table, Swim::Endpoint.parse("10.0.0.0:10000")}
end

case ARGV[0]?
when "wire"
  left, right, now = build_pair
  report("wire_round_trip", ITERATIONS) { wire_cycle(left, right, now) }
when "cipher"
  seal = Swim::Seal.new("cluster-secret")
  plain = Bytes.new(160)
  cipher = Bytes.new(plain.size + Swim::Seal::PREFIX)
  dest = Bytes.new(plain.size)
  report("cipher_round_trip", ITERATIONS) do
    size = seal.encrypt(plain, cipher)
    seal.decrypt(cipher[0, size], dest)
  end
when "sample"
  table, exclude = build_table
  report("sample_5_of_1000", ITERATIONS) do
    table.sample(5, false, exclude) { }
  end
when "peak-wire"
  left, right, now = build_pair
  ITERATIONS.times { wire_cycle(left, right, now) }
  GC.collect
  puts "peak_wire\t#{ITERATIONS}\t0\t0\t0\t0\t#{GC.stats.heap_size}\t#{hwm_kb}"
when "peak-cipher"
  seal = Swim::Seal.new("cluster-secret")
  plain = Bytes.new(160)
  cipher = Bytes.new(plain.size + Swim::Seal::PREFIX)
  dest = Bytes.new(plain.size)
  ITERATIONS.times do
    size = seal.encrypt(plain, cipher)
    seal.decrypt(cipher[0, size], dest)
  end
  GC.collect
  puts "peak_cipher\t#{ITERATIONS}\t0\t0\t0\t0\t#{GC.stats.heap_size}\t#{hwm_kb}"
when "peak-sample"
  table, exclude = build_table
  ITERATIONS.times { table.sample(5, false, exclude) { } }
  GC.collect
  puts "peak_sample\t#{ITERATIONS}\t0\t0\t0\t0\t#{GC.stats.heap_size}\t#{hwm_kb}"
when "memory"
  now = Time.instant
  local = Swim::Endpoint.parse("10.0.0.1:5000")
  core = Swim::Core.new(local, now: now, random: Random.new(1))
  1000.times do |index|
    endpoint = Swim::Endpoint.parse("10.0.#{index // 250}.#{index % 250}:#{10000 + index}")
    core.add(endpoint, 1_u64, Swim::Status::Alive, now)
  end
  5000.times { core.tick(now) { } }
  GC.collect
  puts "memory_1000_members\t5000\t0\t0\t0\t0\t#{GC.stats.heap_size}\t#{hwm_kb}"
else
  STDERR.puts "usage: hot_path <wire|cipher|sample|memory|peak-wire|peak-cipher|peak-sample>"
  exit 1
end
