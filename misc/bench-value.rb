require "benchmark"
require "wardite"

N = 1000000

i32_100 = Wardite::I32.new(100)
i32_200 = Wardite::I32.new(200)
$RES = {}
$RES2 = {}

Benchmark.bmbm do |x|
  x.report("add via value") do
    N.times do |i|
      res = Wardite::I32.new(i32_100.value + i32_200.value)
      $RES[i%10] = res # avoid optimization
    end
  end

  x.report("add immediate") do
    N.times do |i|
      res = 100 + 200
      $RES2[i%10] = res
    end
  end
end