#
# Usage:
#     $ bundle exec ruby --yjit examples/grayscale.rb \
#         --wasm-file path/to/grayscale.wasm \
#         --source tmp/source.png \
#         --dest tmp/result.png \
#         --width 660 --height 495
#
require "wardite"
require "base64"
require "optparse"
require "ostruct"

$options = OpenStruct.new

opt = OptionParser.new
opt.on('--wasm-file [FILE]') {|v| $options.wasm_file = v }
opt.on('--source [IMAGE]') {|v| $options.source = v }
opt.on('--dest [IMAGE]') {|v| $options.dest = v }
opt.on('--width [W]') {|v| $options.width = v.to_i }
opt.on('--height [H]') {|v| $options.height = v.to_i }
opt.parse!

f = File.open($options.wasm_file)
data = IO.read($options.source)
instance = Wardite::BinaryLoader::load_from_buffer(f);
instance.store.memories[0].grow(data.size / (64*1024) + 1)
orig = Base64.encode64(data).gsub(/(\r|\n)/, "")
data_url = "data:image/png;base64," + orig

start = instance.exports.__heap_base.value.value
instance.store.memories[0].data[start...(start+data_url.size)] = data_url

offset = 0
begin
  # pub fn grayscale(width: i32, height: i32, memory_offset: i32, length: i32) -> *const u8
  offset = instance.runtime.grayscale($options.width, $options.height, start, data_url.size)
rescue => e
  raise "failed to execute grayscale()" + e.message
end

len = 0
until instance.store.memories[0].data[offset.value+len] == "\0"
  len += 1
end

result_b64 = instance.store.memories[0].data[offset.value...(offset.value+len)]
result = Base64.decode64(result_b64)

dest = File.open($options.dest, "w")
dest.write result
dest.close

puts "created: #{$options.dest}"