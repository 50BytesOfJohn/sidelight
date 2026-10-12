// Read-only counters for one exact test app PID, sampled over a quiet interval.
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int pid = atoi(argv[1]);
    unsigned int seconds = (unsigned int)atoi(argv[2]);
    if (seconds == 0 || seconds > 60) return 2;
    struct rusage_info_v4 before = {0}, after = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&before) != 0) return 3;
    sleep(seconds);
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&after) != 0) return 3;
    double cpu = (double)(after.ri_user_time + after.ri_system_time - before.ri_user_time - before.ri_system_time) / 1e9;
    printf("{\"interval_seconds\":%u,\"cpu_seconds\":%.6f,\"one_core_cpu_percent\":%.4f,\"interrupt_wakeups\":%llu,\"package_idle_wakeups\":%llu,\"resident_bytes\":%llu}\n",
        seconds, cpu, cpu * 100 / seconds,
        after.ri_interrupt_wkups - before.ri_interrupt_wkups,
        after.ri_pkg_idle_wkups - before.ri_pkg_idle_wkups, after.ri_resident_size);
    return 0;
}
