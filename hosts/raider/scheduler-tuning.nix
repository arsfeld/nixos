# Scheduler tuning for better desktop interactivity during compilation
{...}: {
  # XanMod kernel already includes BORE scheduler
  # These sysctls tune it for better interactivity under load
  boot.kernel.sysctl = {
    # Reduce scheduler latency for better responsiveness
    "kernel.sched_latency_ns" = 1000000; # 1ms (default is usually 6-24ms)
    "kernel.sched_min_granularity_ns" = 100000; # 0.1ms (default is usually 0.75-3ms)
    "kernel.sched_wakeup_granularity_ns" = 500000; # 0.5ms (default is usually 1-4ms)

    # This is already set in gaming module but ensure it's on
    "kernel.sched_autogroup_enabled" = 1; # Groups processes by session for better desktop responsiveness
  };
}
