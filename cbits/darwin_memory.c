/* macOS のメモリ統計を sysctl で読む。memory_pressure コマンドを起動すると、
   PATH に /usr/bin がない環境（launchd や Nix のビルド環境）で失敗し、
   問い合わせのたびにプロセスを起動する重さもあるため。 */
#ifdef __APPLE__
#include <sys/types.h>
#include <sys/sysctl.h>
#include <stdint.h>
#include <string.h>

/* 4 バイトと 8 バイトのどちらの整数を返す名前でも読めるようにする */
static int pm36_sysctl_u64(const char *name, uint64_t *out)
{
  unsigned char buf[8] = {0};
  size_t len = sizeof(buf);
  if (sysctlbyname(name, buf, &len, NULL, 0) != 0)
    return -1;
  if (len == sizeof(uint32_t)) {
    uint32_t v32;
    memcpy(&v32, buf, sizeof(v32));
    *out = v32;
  } else if (len == sizeof(uint64_t)) {
    uint64_t v64;
    memcpy(&v64, buf, sizeof(v64));
    *out = v64;
  } else {
    return -1;
  }
  return 0;
}

/* 空きメモリと物理メモリの総量（バイト）。成功で 0、失敗で -1 */
int pm36DarwinMemoryStats(int64_t *freeBytes, int64_t *totalBytes)
{
  uint64_t total, freePages, pageSize;
  if (pm36_sysctl_u64("hw.memsize", &total) != 0
      || pm36_sysctl_u64("vm.page_free_count", &freePages) != 0
      || pm36_sysctl_u64("vm.pagesize", &pageSize) != 0)
    return -1;
  *freeBytes = (int64_t)(freePages * pageSize);
  *totalBytes = (int64_t)total;
  return 0;
}

/* memory_pressure が "System-wide memory free percentage" として出す値（0〜100）。
   失敗で -1 */
int pm36DarwinMemoryFreePercentage(void)
{
  uint64_t level;
  if (pm36_sysctl_u64("kern.memorystatus_level", &level) != 0)
    return -1;
  return (int)level;
}
#endif
