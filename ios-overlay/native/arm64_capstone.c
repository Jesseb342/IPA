#include <capstone/capstone.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>

#if defined(__GNUC__)
#define NXN_EXPORT __attribute__((visibility("default")))
#else
#define NXN_EXPORT
#endif

static uint32_t read_le32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int append_text(char *out, size_t capacity, size_t *used, const char *format, ...) {
    if (*used >= capacity) return -1;
    va_list args;
    va_start(args, format);
    int n = vsnprintf(out + *used, capacity - *used, format, args);
    va_end(args);
    if (n < 0 || (size_t)n >= capacity - *used) return -1;
    *used += (size_t)n;
    return 0;
}

// Input must be a rewritten, uncompressed NSO. The routine never modifies it.
NXN_EXPORT int32_t nxn_arm64_disassemble_nso(const uint8_t *file, size_t file_size,
                                              uint32_t max_instructions,
                                              char *output, size_t output_capacity) {
    if (!file || !output || output_capacity < 64) return -1;
    output[0] = '\0';
    if (file_size < 0x100 || memcmp(file, "NSO0", 4) != 0)
        return append_text(output, output_capacity, &(size_t){0}, "error|Input is not a complete NSO file.\n");
    uint32_t flags = read_le32(file + 0x0c);
    uint32_t text_offset = read_le32(file + 0x10);
    uint32_t text_size = read_le32(file + 0x18);
    if ((flags & 0x81u) != 0)
        return snprintf(output, output_capacity, "error|Main text segment is still compressed; rewrite the NSO first.") < (int)output_capacity ? 0 : -2;
    if (text_size == 0 || text_offset < 0x100 || (uint64_t)text_offset + text_size > file_size)
        return snprintf(output, output_capacity, "error|NSO text segment bounds are invalid.") < (int)output_capacity ? 0 : -2;
    if (max_instructions == 0 || max_instructions > 512) max_instructions = 96;

    csh handle;
    cs_err err = cs_open(CS_ARCH_ARM64, CS_MODE_ARM, &handle);
    if (err != CS_ERR_OK)
        return snprintf(output, output_capacity, "error|Capstone initialization failed: %s", cs_strerror(err)) < (int)output_capacity ? 0 : -2;
    cs_option(handle, CS_OPT_DETAIL, CS_OPT_ON);
    cs_insn *instructions = NULL;
    size_t count = cs_disasm(handle, file + text_offset, text_size, 0, max_instructions, &instructions);
    if (count == 0) {
        cs_close(&handle);
        return snprintf(output, output_capacity, "error|Capstone could not decode an instruction at the start of the main text segment.") < (int)output_capacity ? 0 : -2;
    }

    size_t used = 0;
    if (append_text(output, output_capacity, &used,
                    "summary|Capstone 5 AArch64 disassembly; %zu instruction(s) decoded from main text (showing up to %u).\n",
                    count, max_instructions) != 0) {
        cs_free(instructions, count); cs_close(&handle); return -2;
    }
    for (size_t i = 0; i < count; i++) {
        cs_insn *insn = &instructions[i];
        char bytes[24] = {0};
        size_t at = 0;
        for (uint8_t j = 0; j < insn->size && at + 3 < sizeof(bytes); j++)
            at += (size_t)snprintf(bytes + at, sizeof(bytes) - at, "%02x", insn->bytes[j]);
        if (append_text(output, output_capacity, &used, "insn|%08llx|%s|%s|%s\n",
                        (unsigned long long)insn->address, bytes, insn->mnemonic, insn->op_str) != 0) {
            cs_free(instructions, count); cs_close(&handle); return -2;
        }
    }
    cs_free(instructions, count);
    cs_close(&handle);
    return 0;
}
