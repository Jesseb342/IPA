#include <capstone/capstone.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
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
    // NSO text can begin with a MOD0 header, padding, or literal data before
    // executable instructions. Continue decoding after such bytes instead of
    // silently stopping at the first invalid word.
    cs_option(handle, CS_OPT_SKIPDATA, CS_OPT_ON);
    cs_insn *instructions = NULL;
    size_t count = cs_disasm(handle, file + text_offset, text_size, 0, max_instructions, &instructions);
    if (count == 0) {
        cs_close(&handle);
        return snprintf(output, output_capacity, "error|Capstone could not decode an instruction at the start of the main text segment.") < (int)output_capacity ? 0 : -2;
    }

    size_t used = 0;
    if (append_text(output, output_capacity, &used,
                    "summary|Capstone 5 AArch64 scan; %zu instruction/data record(s) from main text (showing up to %u). Data bytes are marked .byte; offsets are relative to the NSO text segment.\n",
                    count, max_instructions) != 0) {
        cs_free(instructions, count); cs_close(&handle); return -2;
    }
    for (size_t i = 0; i < count; i++) {
        cs_insn *insn = &instructions[i];
        char bytes[24] = {0};
        size_t at = 0;
        for (uint8_t j = 0; j < insn->size && at + 3 < sizeof(bytes); j++)
            at += (size_t)snprintf(bytes + at, sizeof(bytes) - at, "%02x", insn->bytes[j]);
        if (append_text(output, output_capacity, &used, "%s|%08llx|%s|%s|%s\n",
                        insn->id == 0 ? "data" : "insn", (unsigned long long)insn->address, bytes, insn->mnemonic, insn->op_str) != 0) {
            cs_free(instructions, count); cs_close(&handle); return -2;
        }
    }
    cs_free(instructions, count);
    cs_close(&handle);
    return 0;
}


// Analyze the complete main text segment in bounded chunks. This is read-only:
// it reports likely function prologues and direct call sites, never changes code.
NXN_EXPORT int32_t nxn_arm64_analyze_nso(const uint8_t *file, size_t file_size,
                                         char *output, size_t output_capacity) {
    if (!file || !output || output_capacity < 256) return -1;
    output[0] = '\0';
    if (file_size < 0x100 || memcmp(file, "NSO0", 4) != 0)
        return snprintf(output, output_capacity, "error|Input is not a complete NSO file.") < (int)output_capacity ? 0 : -2;

    uint32_t flags = read_le32(file + 0x0c);
    uint32_t text_offset = read_le32(file + 0x10);
    uint32_t text_size = read_le32(file + 0x18);
    if ((flags & 0x81u) != 0)
        return snprintf(output, output_capacity, "error|Main text segment is still compressed; rewrite the NSO first.") < (int)output_capacity ? 0 : -2;
    if (text_size == 0 || text_offset < 0x100 || (uint64_t)text_offset + text_size > file_size)
        return snprintf(output, output_capacity, "error|NSO text segment bounds are invalid.") < (int)output_capacity ? 0 : -2;

    csh handle;
    cs_err err = cs_open(CS_ARCH_ARM64, CS_MODE_ARM, &handle);
    if (err != CS_ERR_OK)
        return snprintf(output, output_capacity, "error|Capstone initialization failed: %s", cs_strerror(err)) < (int)output_capacity ? 0 : -2;
    cs_option(handle, CS_OPT_DETAIL, CS_OPT_ON);
    cs_option(handle, CS_OPT_SKIPDATA, CS_OPT_ON);

    size_t used = 0;
    uint64_t instruction_count = 0, data_count = 0, prologue_count = 0, call_count = 0;
    uint32_t prologues_reported = 0, calls_reported = 0;
    if (append_text(output, output_capacity, &used,
                    "analysis|Full main-text scan; offsets are relative to NSO text. This is heuristic discovery, not an automatic patch plan.\n") != 0) {
        cs_close(&handle); return -2;
    }

    const size_t chunk_size = 0x10000;
    for (size_t base = 0; base < text_size; base += chunk_size) {
        size_t length = text_size - base;
        if (length > chunk_size) length = chunk_size;
        cs_insn *items = NULL;
        size_t count = cs_disasm(handle, file + text_offset + base, length, (uint64_t)base, 0, &items);
        for (size_t i = 0; i < count; i++) {
            cs_insn *insn = &items[i];
            if (insn->id == 0) {
                data_count++;
                continue;
            }
            instruction_count++;

            if (strcmp(insn->mnemonic, "stp") == 0 &&
                strstr(insn->op_str, "x29, x30, [sp") != NULL) {
                prologue_count++;
                if (prologues_reported < 128) {
                    char bytes[24] = {0};
                    size_t at = 0;
                    for (uint8_t j = 0; j < insn->size && at + 3 < sizeof(bytes); j++)
                        at += (size_t)snprintf(bytes + at, sizeof(bytes) - at, "%02x", insn->bytes[j]);
                    if (append_text(output, output_capacity, &used, "prologue|%08llx|%s|%s\n",
                                    (unsigned long long)insn->address, bytes, insn->op_str) != 0) {
                        cs_free(items, count); cs_close(&handle); return -2;
                    }
                    prologues_reported++;
                }
            }

            if (strcmp(insn->mnemonic, "bl") == 0) {
                call_count++;
                if (calls_reported < 128) {
                    unsigned long long target = 0;
                    const char *hash = strchr(insn->op_str, '#');
                    if (hash) target = strtoull(hash + 1, NULL, 0);
                    if (append_text(output, output_capacity, &used, "call|%08llx|%08llx\n",
                                    (unsigned long long)insn->address, target) != 0) {
                        cs_free(items, count); cs_close(&handle); return -2;
                    }
                    calls_reported++;
                }
            }
        }
        cs_free(items, count);
    }

    int result = append_text(output, output_capacity, &used,
        "summary|text_bytes=%u|instructions=%llu|data_records=%llu|likely_prologues=%llu|calls=%llu|prologues_listed=%u|calls_listed=%u\n",
        text_size, (unsigned long long)instruction_count, (unsigned long long)data_count,
        (unsigned long long)prologue_count, (unsigned long long)call_count,
        prologues_reported, calls_reported);
    cs_close(&handle);
    return result == 0 ? 0 : -2;
}


// Inspect a selected function by NSO-text-relative offset. The end is estimated
// from the next common frame-pointer prologue within a bounded search window.
// Callers are discovered by scanning direct BL targets across the full text.
NXN_EXPORT int32_t nxn_arm64_inspect_function(const uint8_t *file, size_t file_size,
                                               uint64_t function_offset,
                                               char *output, size_t output_capacity) {
    if (!file || !output || output_capacity < 512) return -1;
    output[0] = '\\0';
    if (file_size < 0x100 || memcmp(file, "NSO0", 4) != 0)
        return snprintf(output, output_capacity, "error|Input is not a complete NSO file.") < (int)output_capacity ? 0 : -2;
    uint32_t flags = read_le32(file + 0x0c);
    uint32_t text_offset = read_le32(file + 0x10);
    uint32_t text_size = read_le32(file + 0x18);
    if ((flags & 0x81u) != 0)
        return snprintf(output, output_capacity, "error|Main text segment is still compressed; rewrite the NSO first.") < (int)output_capacity ? 0 : -2;
    if (text_size == 0 || text_offset < 0x100 || (uint64_t)text_offset + text_size > file_size)
        return snprintf(output, output_capacity, "error|NSO text segment bounds are invalid.") < (int)output_capacity ? 0 : -2;
    if (function_offset >= text_size || (function_offset & 3u) != 0)
        return snprintf(output, output_capacity, "error|Offset must be a 4-byte-aligned position inside the NSO text segment.") < (int)output_capacity ? 0 : -2;

    csh handle;
    cs_err err = cs_open(CS_ARCH_ARM64, CS_MODE_ARM, &handle);
    if (err != CS_ERR_OK)
        return snprintf(output, output_capacity, "error|Capstone initialization failed: %s", cs_strerror(err)) < (int)output_capacity ? 0 : -2;
    cs_option(handle, CS_OPT_DETAIL, CS_OPT_ON);
    cs_option(handle, CS_OPT_SKIPDATA, CS_OPT_ON);

    size_t used = 0;
    uint64_t end = function_offset + 0x600;
    if (end > text_size) end = text_size;
    size_t scan_length = (size_t)(end - function_offset);
    cs_insn *region = NULL;
    size_t region_count = cs_disasm(handle, file + text_offset + function_offset,
                                    scan_length, function_offset, 0, &region);
    if (region_count == 0) {
        cs_close(&handle);
        return snprintf(output, output_capacity, "error|Capstone could not decode at the selected offset.") < (int)output_capacity ? 0 : -2;
    }
    for (size_t i = 4; i < region_count; i++) {
        cs_insn *insn = &region[i];
        if (strcmp(insn->mnemonic, "stp") == 0 &&
            strstr(insn->op_str, "x29, x30, [sp") != NULL) {
            end = insn->address;
            break;
        }
    }
    cs_free(region, region_count);
    scan_length = (size_t)(end - function_offset);
    region = NULL;
    region_count = cs_disasm(handle, file + text_offset + function_offset,
                             scan_length, function_offset, 0, &region);
    if (append_text(output, output_capacity, &used,
                    "function|offset=%08llx|estimated_end=%08llx|bytes=%llu\\n",
                    (unsigned long long)function_offset, (unsigned long long)end,
                    (unsigned long long)(end - function_offset)) != 0) {
        if (region) cs_free(region, region_count);
        cs_close(&handle); return -2;
    }
    for (size_t i = 0; i < region_count; i++) {
        cs_insn *insn = &region[i];
        if (append_text(output, output_capacity, &used, "insn|%08llx|%s|%s\\n",
                        (unsigned long long)insn->address, insn->mnemonic, insn->op_str) != 0) {
            cs_free(region, region_count); cs_close(&handle); return -2;
        }
    }
    cs_free(region, region_count);

    uint32_t callers = 0;
    const size_t chunk_size = 0x10000;
    for (size_t base = 0; base < text_size; base += chunk_size) {
        size_t length = text_size - base;
        if (length > chunk_size) length = chunk_size;
        cs_insn *items = NULL;
        size_t count = cs_disasm(handle, file + text_offset + base, length, (uint64_t)base, 0, &items);
        for (size_t i = 0; i < count; i++) {
            cs_insn *insn = &items[i];
            if (strcmp(insn->mnemonic, "bl") == 0) {
                const char *hash = strchr(insn->op_str, '#');
                if (hash && strtoull(hash + 1, NULL, 0) == function_offset && callers < 64) {
                    if (append_text(output, output_capacity, &used, "caller|%08llx\\n",
                                    (unsigned long long)insn->address) != 0) {
                        cs_free(items, count); cs_close(&handle); return -2;
                    }
                    callers++;
                }
            }
        }
        cs_free(items, count);
    }
    if (append_text(output, output_capacity, &used,
                    "summary|caller_sites_listed=%u|caller_limit=64|boundary=next-prologue-or-0x600-byte-window\\n",
                    callers) != 0) {
        cs_close(&handle); return -2;
    }
    cs_close(&handle);
    return 0;
}
