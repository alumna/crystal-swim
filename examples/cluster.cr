require "option_parser"
require "../src/swim"

# Start one node in each terminal.
# Terminal 1: crystal run examples/cluster.cr -- -p 5000
# Terminal 2: crystal run examples/cluster.cr -- -p 5001 -s 127.0.0.1:5000
# Terminal 3: crystal run examples/cluster.cr -- -p 5002 -s 127.0.0.1:5001
# Stop terminal 2. The other nodes move that peer to suspect, then to dead.

port = 5000
seeds = [] of String

OptionParser.parse do |parser|
  parser.banner = "Usage: crystal run examples/cluster.cr -- [arguments]"
  parser.on("-p PORT", "--port=PORT", "UDP port") { |value| port = value.to_i }
  parser.on("-s SEED", "--seed=SEED", "Peer address host:port") { |value| seeds << value }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
end

address = "127.0.0.1:#{port}"
puts "Swim node #{address}"

cluster = Swim.join(address, seeds: seeds, period: 1.second, timeout: 400.milliseconds)
at_exit { cluster.stop }

loop do
  sleep 3.seconds
  puts "--- #{address} ---"
  puts "Health: #{cluster.health}"
  cluster.each { |peer| puts peer }
end
