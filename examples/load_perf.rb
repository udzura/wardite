require "wardite"
require "optparse"
require "ostruct"

$options = OpenStruct.new

opt = OptionParser.new
opt.on('--wasm-file [FILE]') {|v| $options.wasm_file = v }
opt.parse!

f = File.open($options.wasm_file)

require "vernier"
RubyVM::YJIT.enable
puts "YJIT enabled: #{RubyVM::YJIT.enabled?}"

Vernier.profile(out: "./tmp/load_perf.json") do
  start = Time.now
  _instance = Wardite::BinaryLoader::load_from_buffer(f);
  puts "Profile saved to ./tmp/load_perf.json"
  puts "Load time: #{Time.now.to_f - start.to_f} seconds"
end

p "OK"