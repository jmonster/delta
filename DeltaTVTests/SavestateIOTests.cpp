// Checked native melonDS I/O regression tests. No ROM or firmware input.
#include "Savestate.h"
#include <cassert>
#include <cerrno>
#include <cstring>
#include <string>

static int fault = 0, closes = 0;
struct MemoryFile { unsigned char data[4096] = {}; fpos_t position = 0; };
static int writeMemory(void* context, const char* data, int size) {
    if (fault == 1) { errno = ENOSPC; return -1; }
    auto* memory = static_cast<MemoryFile*>(context);
    if (size < 0 || memory->position < 0 || memory->position + size > sizeof(memory->data)) return -1;
    memcpy(memory->data + memory->position, data, size); memory->position += size; return size;
}
static fpos_t seekMemory(void* context, fpos_t position, int origin) {
    auto* memory = static_cast<MemoryFile*>(context);
    memory->position = origin == SEEK_CUR ? memory->position + position : position;
    return memory->position;
}
static int closeMemory(void* context) { delete static_cast<MemoryFile*>(context); ++closes; return fault == 2 ? EOF : 0; }
namespace Platform {
FILE* OpenFile(std::string path, std::string mode, bool) { return fopen(path.c_str(), mode.c_str()); }
FILE* OpenLocalFile(std::string path, std::string mode) {
    if (fault) return funopen(new MemoryFile(), nullptr, writeMemory, seekMemory, closeMemory);
    return fopen(path.c_str(), mode.c_str());
}
}
int main(int argc, char** argv) {
    assert(argc == 2);
    std::string path = argv[1]; u32 value = 0x12345678;
    { Savestate save(path, true); save.Section("TEST"); save.Var32(&value); assert(save.Finish()); }
    { Savestate load(path, false); load.Section("TEST"); u32 actual = 0; load.Var32(&actual); assert(actual == value && load.Finish()); }
    { Savestate load(path, false); load.Section("TEST"); u64 tooLong = 0; load.Var64(&tooLong); assert(load.Error && !load.Finish()); }
    { Savestate load(path, false); load.Section("NONE"); assert(load.Error && !load.Finish()); }
    for (fault = 1; fault <= 2; ++fault) {
        int before = closes;
        Savestate save(path, true); save.Section("TEST"); save.Var32(&value);
        assert(!save.Finish() && save.Error); assert(closes == before + 1);
        assert(!save.Finish() && closes == before + 1);
    }
    remove(path.c_str());
    puts("Native state I/O checks passed: roundtrip, short read, missing section, short write, close failure, idempotent close");
}
