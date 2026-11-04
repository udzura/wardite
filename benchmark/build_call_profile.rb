# frozen_string_literal: true

# Ask the installed compiler for its runtime, package objects, defines and C
# flags. Compile the saved C ourselves, keeping C source locations in DWARF.
require "fileutils"
require "json"
require "open3"
require "shellwords"

Dir.chdir(File.expand_path("..", __dir__))
output = File.expand_path(ENV.fetch("PROFILE_DIR", "build/benchmark/call-cost/profile"))
FileUtils.mkdir_p(output)
compiler = Shellwords.split(ENV.fetch("SPINEL", "spinel"))
source = "#{output}/worker.c"
binary = "#{output}/worker"
command = [*compiler, "-Ilib", "--strict-require", "-O2", "--profile", "--no-line-map",
  "-c", "--force", "benchmark/call_cost_worker.rb", "-o", source, "--print-build"]
stdout, stderr, status = Open3.capture3(*command)
File.write("#{output}/spinel.log", stderr)
abort "Spinel failed; see #{output}/spinel.log" unless status.success?
File.write("#{output}/ingredients.txt", stdout)
ingredients = stdout.lines.map { |line| line.strip.split(" ", 2) }
raise "Spinel did not preserve the requested C file" unless File.exist?(source) && ingredients.include?(["source", source])
known = %w[cflag include define source link runtime lib]
raise "Unknown build ingredient" unless ingredients.all? { |kind, value| known.include?(kind) && value }
cflags = ingredients.filter_map do |kind, value|
  kind == "include" ? "-I#{value}" : (%w[cflag define].include?(kind) ? value : nil)
end
links = ingredients.filter_map { |kind, value| value if %w[link runtime lib].include?(kind) }
cc = Shellwords.split(ENV.fetch("CC", "clang"))
object = "#{output}/worker.o"
compile = [*cc, "-O2", "-g", "-fno-omit-frame-pointer", *cflags, "-c", source, "-o", object]
link = [*cc, "-g", object, *links, "-o", binary]
File.write("#{output}/compile-command.json", JSON.pretty_generate({compile: compile, link: link}) + "\n")
abort "C compilation failed; see #{output}/clang.log" unless system(*compile, out: "#{output}/clang.log", err: [:child, :out])
abort "C link failed; see #{output}/link.log" unless system(*link, out: "#{output}/link.log", err: [:child, :out])
if RUBY_PLATFORM.include?("darwin")
  # Keep worker.o: Mach-O's debug map points into it until dsymutil bundles DWARF.
  FileUtils.rm_rf("#{binary}.dSYM")
  abort "dsymutil failed" unless system("dsymutil", binary, out: "#{output}/dsymutil.log", err: [:child, :out])
end
puts "Saved generated C, build ingredients, compile command and debug binary in #{output}"
