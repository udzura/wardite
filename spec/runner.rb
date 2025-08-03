require "json"
require "wardite"
require "test-unit"

json_path = ENV['JSON_PATH'] || File.expand_path("../i32.json", __FILE__)
testcase = JSON.load_file(json_path, symbolize_names: true)

$commands = testcase[:commands]

def parse_value(arg)
  case arg[:type]
  when "i32"
    return arg[:value]&.to_i
  when "i64"
    return arg[:value]&.to_i
  when "f32"
    return arg[:value]&.to_f
  when "f64"
    return arg[:value]&.to_f
  else
    raise "not yet supported: #{arg.inspect}"
  end
end

def parse_result(arg)
  case arg[:type]
  when "i32"
    if v = arg[:value]&.to_i
      I32(v)
    else
      nil
    end
  when "i64"
    if v = arg[:value]&.to_i
      I64(v)
    else
      nil
    end
  when "f32"
    if v = arg[:value]&.to_f
      F32(v)
    else
      nil
    end
  when "f64"
    if v = arg[:value]&.to_f
      F64(v)
    else
      nil
    end
  else
    raise "not yet supported: #{arg.inspect}"
  end
end

BEGIN {
  File.delete(File.expand_path("../skip.txt", __FILE__)) if File.exist?(File.expand_path("../skip.txt", __FILE__))
}

klass_name = File.basename(json_path, ".json").split("_").map(&:capitalize).join
eval "class Wardite#{klass_name}Test < Test::Unit::TestCase; end"
klass = Object.const_get("Wardite#{klass_name}Test")

klass.instance_eval do
  extend Wardite::ValueHelper
  current_wasm = nil

  $commands.each do |command|
    command_type = command[:type]
    case command_type
    when "module"
      command => {filename:}
      current_wasm = filename
    when "assert_return"
      command => {line:, action:, expected:}
      action => {type:, field:, args:}
      if ENV['FILTER_FIELD'] && ENV['FILTER_FIELD'] != field
        next
      end
      if type != "invoke"
        warning "not yet supported: #{command.inspect}"
        next
      end
      args_ = args.map{|v| parse_value(v)} 
      expected_ = expected.map{|v| parse_result(v)}
  
      test "#{command_type}: (#{"%4d" % line}) #{field}(#{args_.inspect}) -> #{expected_.inspect}" do
        instance = instance = Wardite::new(path: File.expand_path("../#{current_wasm}", __FILE__))
        ret = instance.runtime.call(field, args_)

        assert { ret == expected_[0] }
      end
    when "assert_trap"
      command => {line:, action:, expected:}
      action => {type:, field:, args:}
      if ENV['FILTER_FIELD'] && ENV['FILTER_FIELD'] != field
        next
      end

      if type != "invoke"
        warning "not yet supported: #{command.inspect}"
        next
      end
      args_ = args.map{|v| parse_value(v)} 
      expected_ = expected.map{|v| parse_result(v)}
  
      test "#{command_type}: (#{"%4d" % line}) #{field}(#{args_.inspect})" do
        instance = instance = Wardite::new(path: File.expand_path("../#{current_wasm}", __FILE__))
        command => {text:}
        trapped = false
        begin
          instance.runtime.call(field, args_)
        rescue => e
          assert "invoke expectedly failed: #{e.message}, expected msg: #{text}" do
            trapped = true
          end
        end
        assert "expected error: #{text}" do
          trapped
        end
      end
    when "assert_invalid", "assert_malformed"
      if ENV['VERBOSE']
        test "#{command_type}: #{command.inspect}" do
          omit "skip #{command_type}"
        end
      else
        IO.write(File.expand_path("../skip.txt", __FILE__), "#{command_type}: #{command.inspect}\n", mode: "a")
      end
    end
  end
end

