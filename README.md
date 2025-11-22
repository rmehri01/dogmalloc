# dogmalloc

dogmalloc is a general purpose Zig allocator that is designed as a drop-in replacement for
`std.heap.smp_allocator` (i.e. for ReleaseFast with multi-threading) and is inspired by
[mimalloc](https://github.com/microsoft/mimalloc). It's relatively small at around 600 lines
but seems to do well across a range of workloads (see [performance](#performance)). Note that 
in many cases a special purpose allocator will be better and Zig makes that easy with the 
`Allocator` interface!

> [!WARNING]  
> This is still a work in progress and hasn't been thoroughly tested or optimized.
> Additionally it does not implement many of the security and debugging features of other allocators.
> Contributions are always welcome!

## Performance

### Versus Others

This comparison is using [mimalloc-bench](https://github.com/daanx/mimalloc-bench) and includes
[jdz_allocator](https://github.com/joadnacer/jdz_allocator) as well as several popular C allocators.
Note that this is only for benchmarks that don't make allocations above our huge page size
so that we avoid the overhead of the C library mentioned in [when using from C](#from-c) so
it isn't perfect but still gives a rough comparison. Also, many of the C allocators rely on using
thread locals and thread destructors which can be more efficient since they don't require as much locking
but we explicitly don't do this (see [Design](#design)). A more detailed Zig-specific benchmark
is provided in [Versus SmpAllocator](#versus-smpallocator).

#### Time (log scale):

<img width="3711" height="1599" src="https://github.com/user-attachments/assets/936e8be8-d6ea-4533-a7b2-3ec8a4a4f53a" />
<img width="3711" height="1599" src="https://github.com/user-attachments/assets/b0762d1d-4ac7-411c-82bd-a10efe77884f" />

#### Memory (log scale):

<img width="3711" height="1599" src="https://github.com/user-attachments/assets/252a7dbf-5d25-446f-9dff-75c092e0e161" />
<img width="3711" height="1599" src="https://github.com/user-attachments/assets/901692c8-8c39-4b6a-91f5-51ed8afa5748" />

### Versus SmpAllocator

This run of mimalloc-bench should be relatively accurate since they both incur the same overhead
of using the shared library interface:

#### Time (log scale):

<img width="3703" height="1510" alt="image" src="https://github.com/user-attachments/assets/91792274-19e7-4082-875c-53cdcfedaaee" />

#### Memory (log scale):

<img width="3711" height="1599" alt="image" src="https://github.com/user-attachments/assets/a15e2962-e161-403b-a3cb-8eac8125f9c5" />

#### Zig Compiler

When compiling the Zig compiler, dogmalloc is pretty competitive with SmpAllocator but uses less memory:

```
Benchmark 1 (3 runs): stage4/bin/zig build -p trash -Dno-lib --cache-dir $(mktemp -d)
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          12.4s  ± 68.2ms    12.4s  … 12.5s           0 ( 0%)        0%
  peak_rss           1.38GB ± 3.12MB    1.37GB … 1.38GB          0 ( 0%)        0%
  cpu_cycles          112G  ±  321M      112G  …  113G           0 ( 0%)        0%
  instructions        257G  ± 1.39M      257G  …  257G           0 ( 0%)        0%
  cache_references   9.17G  ± 35.1M     9.12G  … 9.19G           0 ( 0%)        0%
  cache_misses        385M  ± 5.25M      379M  …  390M           0 ( 0%)        0%
  branch_misses       438M  ± 1.51M      436M  …  439M           0 ( 0%)        0%
Benchmark 2 (3 runs): stage4dog/bin/zig build -p trash -Dno-lib --cache-dir $(mktemp -d)
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          12.6s  ±  392ms    12.3s  … 13.0s           0 ( 0%)          +  1.1% ±  5.1%
  peak_rss           1.31GB ± 1.95MB    1.31GB … 1.31GB          0 ( 0%)        ⚡-  4.9% ±  0.4%
  cpu_cycles          116G  ± 6.07G      112G  …  123G           0 ( 0%)          +  3.0% ±  8.7%
  instructions        265G  ± 11.2G      258G  …  277G           0 ( 0%)          +  2.8% ±  7.0%
  cache_references   9.77G  ±  550M     9.44G  … 10.4G           0 ( 0%)          +  6.6% ±  9.6%
  cache_misses        436M  ± 74.0M      389M  …  521M           0 ( 0%)          + 13.2% ± 30.9%
  branch_misses       476M  ± 61.2M      441M  …  547M           0 ( 0%)          +  8.8% ± 22.4%
```

When running a subset of the tests we get similar results but the time was much more variable:

```
Benchmark 1 (3 runs): stage4/bin/zig build test -Dskip-non-native -Dskip-release -Denable-llvm --cache-dir $(mktemp -d)
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           103s  ± 28.0s     79.7s  …  134s           0 ( 0%)        0%
  peak_rss           2.89GB ± 29.8MB    2.86GB … 2.91GB          0 ( 0%)        0%
  cpu_cycles         7.04T  ±  870G     6.28T  … 7.99T           0 ( 0%)        0%
  instructions       10.5T  ± 1.24T     9.74T  … 11.9T           0 ( 0%)        0%
  cache_references    571G  ± 77.0G      509G  …  657G           0 ( 0%)        0%
  cache_misses       62.8G  ± 10.6G     54.2G  … 74.6G           0 ( 0%)        0%
  branch_misses      34.0G  ± 6.79G     29.5G  … 41.8G           0 ( 0%)        0%
Benchmark 2 (3 runs): stage4dog/bin/zig build test -Dskip-non-native -Dskip-release -Denable-llvm --cache-dir $(mktemp -d)
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           103s  ± 10.7s     95.9s  …  115s           0 ( 0%)          -  0.4% ± 46.5%
  peak_rss           2.63GB ± 11.7MB    2.62GB … 2.64GB          0 ( 0%)        ⚡-  9.0% ±  1.8%
  cpu_cycles         6.83T  ±  816G     6.18T  … 7.75T           0 ( 0%)          -  3.0% ± 27.2%
  instructions       10.5T  ± 1.26T     9.76T  … 12.0T           0 ( 0%)          +  0.2% ± 27.0%
  cache_references    564G  ± 71.2G      515G  …  646G           0 ( 0%)          -  1.3% ± 29.4%
  cache_misses       61.5G  ± 10.2G     54.2G  … 73.2G           0 ( 0%)          -  2.1% ± 37.6%
  branch_misses      33.7G  ± 6.67G     29.7G  … 41.4G           0 ( 0%)          -  0.9% ± 44.9%
```

#### Carmen's Playground

Additionally, there are some smaller benchmarks in [Carmen's Playground](https://github.com/andrewrk/CarmensPlayground)
that are pretty interesting:

Symmetric:

```
Benchmark 1 (38 runs): zig-out/bin/symmetric smp
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           132ms ± 4.76ms     126ms …  152ms          2 ( 5%)        0%
  peak_rss            364MB ± 6.44MB     354MB …  380MB          0 ( 0%)        0%
  cpu_cycles         9.57G  ±  218M     9.02G  … 9.96G           0 ( 0%)        0%
  instructions       17.4G  ±  929K     17.4G  … 17.4G           0 ( 0%)        0%
  cache_references   75.4M  ± 2.53M     70.3M  … 81.4M           0 ( 0%)        0%
  cache_misses       19.6M  ±  984K     17.6M  … 21.8M           0 ( 0%)        0%
  branch_misses      2.71M  ±  128K     2.47M  … 3.01M           0 ( 0%)        0%
Benchmark 2 (50 runs): zig-out/bin/symmetric dog
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           101ms ± 2.99ms    95.7ms …  108ms          0 ( 0%)        ⚡- 23.4% ±  1.3%
  peak_rss            322MB ±  252KB     322MB …  323MB          0 ( 0%)        ⚡- 11.5% ±  0.5%
  cpu_cycles         6.74G  ± 92.0M     6.49G  … 6.98G           0 ( 0%)        ⚡- 29.5% ±  0.7%
  instructions       19.7G  ±  216K     19.7G  … 19.7G           5 (10%)        💩+ 13.5% ±  0.0%
  cache_references   47.9M  ±  681K     46.8M  … 51.9M           4 ( 8%)        ⚡- 36.5% ±  1.0%
  cache_misses       1.21M  ± 54.3K     1.08M  … 1.33M           0 ( 0%)        ⚡- 93.9% ±  1.4%
  branch_misses      1.37M  ±  229K     1.24M  … 2.46M           3 ( 6%)        ⚡- 49.2% ±  3.0%
```

Asymmetric:

```
Benchmark 1 (4 runs): zig-out/bin/asymmetric smp
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.34s  ± 38.6ms    1.32s  … 1.40s           0 ( 0%)        0%
  peak_rss            112MB ± 18.8MB    84.4MB …  124MB          1 (25%)        0%
  cpu_cycles         6.85G  ± 22.5M     6.82G  … 6.88G           0 ( 0%)        0%
  instructions       12.5G  ± 5.96M     12.5G  … 12.5G           0 ( 0%)        0%
  cache_references   84.5M  ± 1.84M     83.0M  … 86.6M           0 ( 0%)        0%
  cache_misses       37.3M  ±  362K     36.9M  … 37.7M           0 ( 0%)        0%
  branch_misses      11.3M  ±  265K     11.1M  … 11.7M           0 ( 0%)        0%
Benchmark 2 (4 runs): zig-out/bin/asymmetric dog
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          1.25s  ± 13.0ms    1.23s  … 1.26s           0 ( 0%)        ⚡-  6.8% ±  3.7%
  peak_rss           2.27MB ±  334KB    1.90MB … 2.65MB          0 ( 0%)        ⚡- 98.0% ± 20.5%
  cpu_cycles         7.42G  ±  115M     7.25G  … 7.52G           1 (25%)        💩+  8.3% ±  2.1%
  instructions       13.7G  ± 11.1M     13.7G  … 13.7G           0 ( 0%)        💩+ 10.0% ±  0.1%
  cache_references   76.5M  ± 1.34M     74.9M  … 78.0M           0 ( 0%)        ⚡-  9.5% ±  3.3%
  cache_misses       55.8M  ±  920K     54.6M  … 56.9M           0 ( 0%)        💩+ 49.7% ±  3.2%
  branch_misses      11.8M  ±  826K     10.8M  … 12.8M           0 ( 0%)          +  4.5% ±  9.4%
```

dogmalloc has the added benefit that memory usage stays constant in the `mpsc` test, whereas
SmpAllocator's memory usage continues to grow:

```
$ zig-out/bin/mpsc dog
$ ps x -o time,rss,command | grep 'mpsc'
00:00:10  2352 zig-out/bin/mpsc dog
$ ps x -o time,rss,command | grep 'mpsc'
00:00:30  2352 zig-out/bin/mpsc dog
$ ps x -o time,rss,command | grep 'mpsc'
00:01:01  2384 zig-out/bin/mpsc dog
$ ps x -o time,rss,command | grep 'mpsc'
00:02:17  2384 zig-out/bin/mpsc dog

$ zig-out/bin/mpsc smp
$ ps x -o time,rss,command | grep 'mpsc'
00:00:03 22340 zig-out/bin/mpsc smp
$ ps x -o time,rss,command | grep 'mpsc'
00:00:28 202868 zig-out/bin/mpsc smp
$ ps x -o time,rss,command | grep 'mpsc'
00:00:59 288940 zig-out/bin/mpsc smp
$ ps x -o time,rss,command | grep 'mpsc'
00:01:41 335940 zig-out/bin/mpsc smp
```

## Usage

### From Zig

Add `dogmalloc` to your dependencies:

```
zig fetch --save git+https://github.com/rmehri01/dogmalloc
```

Make it usable in your `build.zig`:

```zig
const dogmalloc = b.dependency("dogmalloc", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("dogmalloc", dogmalloc.module("dogmalloc"));
```

Then you can use `dogmalloc.allocator` anywhere that you need an allocator since it's thread-safe
and doesn't require any extra cleanup when threads terminate. For example, you can put something
like this in your main function:

```zig
const std = @import("std");
const builtin = @import("builtin");

const dogmalloc = @import("dogmalloc");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ dogmalloc.allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };
}
```

### From C

Note that the C library is not intended for production use and in many cases is significantly slower
than when used from Zig. Since the Zig allocation interface provides size information on free (unlike
in C), we don't need to keep around as much metadata, specifically for when we delegate huge pages
to the `PageAllocator`, while for the C interface we need to stash this away somewhere. If you still
want to use it, you can build it with:

```
zig build -Doptimize=ReleaseFast -Dlibs
```

And then:

```
LD_PRELOAD=zig-out/lib/libdogmalloc.so myprogram
```

## Design

I highly recommend checking out the [mimalloc paper](https://www.microsoft.com/en-us/research/wp-content/uploads/2019/06/mimalloc-tr-v1.pdf)
and the source code as well, both are very readable.

Instead of having one large free list throughout the entire heap, we break up the heap into 512
KiB pages (unrelated to OS pages) which have some metadata and then data blocks of a fixed size.
This both increases the spatial locality of allocations and allows us to find the metadata for
a page easily (since it is stored at the head of the page). If an allocation is bigger than
around 64 KiB, it is considered "huge" and just defer to `std.heap.page_allocator`.

Each page has a local and thread free list for local and non-local frees respectively. With local
frees, no extra coordination is required but for non-local frees, we instead atomically push
to the thread free list which reduces contention and batches the collection of non-local freed blocks.

While using thread locals for the heap state would provide a significant performance increase, it
would require some way to clean up the thread's allocator state when it terminates, which would either
mean modifying all existing thread spawns or adding a destructor hook similar to the one provided
by `pthread_key_create`, both of which are not ideal for use in Zig. Instead, we take a similar
approach to SmpAllocator and have a number of heaps that are shared between all threads, where each
thread tries to lock a heap before allocating or moves on to the next one if it would have blocked.
