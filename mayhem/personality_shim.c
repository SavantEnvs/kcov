/* LD_PRELOAD shim for running kcov's test suite inside docker builds.
 *
 * kcov disables ASLR in the child via personality(ADDR_NO_RANDOMIZE) and
 * aborts if that fails. Docker's default seccomp profile only permits a
 * whitelist of personality values that excludes ADDR_NO_RANDOMIZE, so every
 * ptrace-engine test would fail with EPERM before doing any real work.
 * Pretend the call succeeded: ASLR stays on, which kcov handles fine (it
 * computes load addresses from /proc/<pid>/maps).
 */
#include <errno.h>
#include <sys/personality.h>
#include <sys/syscall.h>
#include <unistd.h>

int personality(unsigned long persona)
{
	long ret = syscall(SYS_personality, persona);
	if (ret < 0 && (errno == EPERM || errno == EINVAL))
		return 0;
	return (int)ret;
}
