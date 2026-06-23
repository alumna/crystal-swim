require "option_parser"
require "../src/swim"

# ** How to test this example: **
# Open three terminals.
# Terminal 1: `crystal run examples/cluster.cr -- -p 5000`
# Terminal 2: `crystal run examples/cluster.cr -- -p 5001 -s 127.0.0.1:5000`
# Terminal 3: `crystal run examples/cluster.cr -- -p 5002 -s 127.0.0.1:5001`
# You will watch them instantly discover each other. If you `Ctrl+C` Terminal 2, you will watch Terminals 1 and 3 transition Node 5001 to `SUSPECT` and then `DEAD`!

port = 5000
seed : String? = nil

OptionParser.parse do |parser|
  parser.banner = "Usage: crystal run examples/cluster.cr -- [arguments]"
  parser.on("-p PORT", "--port=PORT", "Port to bind UDP socket to") { |p| port = p.to_i }
  parser.on("-s SEED", "--seed=SEED", "Seed node to join (e.g. 127.0.0.1:5000)") { |s| seed = s }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
end

id = "node-#{port}"
address = "127.0.0.1:#{port}"

puts "Booting Swim Node: #{id} at #{address}"

local = Swim::Member.new(id, address, 1_u64, Swim::State::Alive)
members = Swim::MembershipList.new
protocol = Swim::Protocol.new(local, members)

if seed_addr = seed
  puts "Joining cluster via seed: #{seed_addr}"
  # We use a temporary placeholder. Once real gossip arrives, the true ID takes over.
  seed_member = Swim::Member.new("seed_placeholder", seed_addr, 0_u64, Swim::State::Alive)
  members.update(seed_member)
end

node = Swim::Node.new(protocol, "127.0.0.1", port)
node.start(tick_interval: 1.second)

spawn do
  loop do
    sleep 3.seconds

    # Clean up the placeholder if we have discovered the real nodes
    if members.size > 2 && members.get("seed_placeholder")
      members.remove("seed_placeholder")
    end

    puts "\n--- Cluster State [#{id}] ---"
    puts "Health Multiplier: #{protocol.local_health_multiplier}"

    members.all.sort_by(&.id).each do |m|
      status = m.state.to_s.upcase
      puts " - #{m.id} (#{m.address}) : #{status} (Inc: #{m.incarnation})"
    end
    puts "-----------------------------\n"
  end
end

sleep
