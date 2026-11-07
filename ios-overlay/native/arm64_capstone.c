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


// Parse the immediate operand printed by Capstone (for example "#0x1234").
static int parse_hash_immediate(const char *text, uint64_t *value) {
    if (!text || !value) return 0;
    const char *hash = strchr(text, '#');
    if (!hash) return 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(hash + 1, &end, 0);
    if (end == hash + 1) return 0;
    *value = (uint64_t)parsed;
    return 1;
}

static int find_instruction_at(const cs_insn *items, size_t count, uint64_t address) {
    for (size_t i = 0; i < count; i++)
        if (items[i].address == address) return (int)i;
    return -1;
}

static int is_conditional_branch(const char *mnemonic) {
    return (strncmp(mnemonic, "b.", 2) == 0 ||
            strcmp(mnemonic, "cbz") == 0 || strcmp(mnemonic, "cbnz") == 0 ||
            strcmp(mnemonic, "tbz") == 0 || strcmp(mnemonic, "tbnz") == 0);
}

static int is_direct_branch(const char *mnemonic) {
    return strcmp(mnemonic, "b") == 0 || is_conditional_branch(mnemonic);
}

static int map_nso_va_to_file(const uint8_t *file, size_t file_size,
                              uint64_t address, size_t required,
                              size_t *file_offset) {
    // NSO segment triples begin at 0x10: file offset, memory offset, size.
    for (size_t segment = 0; segment < 3; segment++) {
        size_t header = 0x10 + segment * 0x10;
        uint32_t segment_file = read_le32(file + header);
        uint32_t segment_mem = read_le32(file + header + 4);
        uint32_t segment_size = read_le32(file + header + 8);
        if (address < segment_mem) continue;
        uint64_t delta = address - segment_mem;
        if (delta > segment_size || required > (uint64_t)segment_size - delta) continue;
        uint64_t absolute = (uint64_t)segment_file + delta;
        if (absolute > file_size || required > file_size - absolute) continue;
        *file_offset = (size_t)absolute;
        return 1;
    }
    return 0;
}



// Decode one address and identify either supported linker trampoline form.
// The returned offset includes the optional x16/x30 save instruction.
static int resolve_linker_stub_at(csh handle, const uint8_t *file, size_t file_size,
                                  uint32_t text_file_offset, uint32_t text_size,
                                  uint64_t offset, uint64_t *stub_start,
                                  uint64_t *slot_va, uint64_t *raw_pointer,
                                  size_t *slot_file_offset, int *has_save) {
    if (offset >= text_size || (offset & 3u) != 0) return 0;
    uint64_t decode_start = offset;
    size_t available = text_size - (size_t)offset;
    if (available > 20) available = 20;
    cs_insn *items = NULL;
    size_t count = cs_disasm(handle, file + text_file_offset + offset,
                             available, offset, 5, &items);
    int begins_with_save = count >= 5 &&
        strcmp(items[0].mnemonic, "stp") == 0 &&
        strstr(items[0].op_str, "x16, x30, [sp, #-0x10]!") != NULL;
    if (begins_with_save) {
        *has_save = 1;
    } else {
        *has_save = 0;
        if (items) cs_free(items, count);
        items = NULL;
        count = 0;
        if (offset < 4) return 0;
        cs_insn *prior = NULL;
        size_t prior_count = cs_disasm(handle, file + text_file_offset + offset - 4,
                                       4, offset - 4, 1, &prior);
        int prior_save = prior_count == 1 &&
            strcmp(prior[0].mnemonic, "stp") == 0 &&
            strstr(prior[0].op_str, "x16, x30, [sp, #-0x10]!") != NULL;
        if (prior) cs_free(prior, prior_count);
        if (prior_save) {
            *has_save = 1;
            decode_start = offset - 4;
            available = text_size - (size_t)decode_start;
            if (available > 20) available = 20;
            count = cs_disasm(handle, file + text_file_offset + decode_start,
                              available, decode_start, 5, &items);
        } else {
            available = text_size - (size_t)offset;
            if (available > 16) available = 16;
            count = cs_disasm(handle, file + text_file_offset + offset,
                              available, offset, 4, &items);
        }
    }
    size_t first = *has_save ? 1 : 0;
    int matched = count >= first + 4 &&
        strcmp(items[first + 0].mnemonic, "adrp") == 0 &&
        strcmp(items[first + 1].mnemonic, "ldr") == 0 &&
        strcmp(items[first + 2].mnemonic, "add") == 0 &&
        strcmp(items[first + 3].mnemonic, "br") == 0 &&
        strstr(items[first + 0].op_str, "x16,") != NULL &&
        strstr(items[first + 1].op_str, "x17, [x16") != NULL &&
        strstr(items[first + 2].op_str, "x16, x16") != NULL &&
        strstr(items[first + 3].op_str, "x17") != NULL;
    uint64_t page = 0, delta = 0;
    if (matched)
        matched = parse_hash_immediate(items[first + 0].op_str, &page) &&
                  parse_hash_immediate(items[first + 1].op_str, &delta);
    if (matched) {
        *stub_start = decode_start;
        *slot_va = page + delta;
        *slot_file_offset = SIZE_MAX;
        *raw_pointer = 0;
        if (map_nso_va_to_file(file, file_size, *slot_va, 8, slot_file_offset)) {
            for (size_t b = 0; b < 8; b++)
                *raw_pointer |= (uint64_t)file[*slot_file_offset + b] << (b * 8);
        }
    }
    if (items) cs_free(items, count);
    return matched;
}

// Whole-main-text linker-stub discovery with bounded pointer-chain tracing.
// It is read-only and deliberately labels zero/runtime pointers unresolved.
NXN_EXPORT int32_t nxn_arm64_discover_linker_stubs(const uint8_t *file, size_t file_size,
                                                    char *output, size_t output_capacity) {
    if (!file || !output || output_capacity < 512) return -1;
    output[0] = '\0';
    if (file_size < 0x100 || memcmp(file, "NSO0", 4) != 0)
        return snprintf(output, output_capacity, "error|Input is not a complete NSO file.") < (int)output_capacity ? 0 : -2;
    uint32_t flags = read_le32(file + 0x0c);
    uint32_t text_file_offset = read_le32(file + 0x10);
    uint32_t text_size = read_le32(file + 0x18);
    if ((flags & 0x81u) != 0)
        return snprintf(output, output_capacity, "error|Main text segment is still compressed; rewrite the NSO first.") < (int)output_capacity ? 0 : -2;
    if (!text_size || text_file_offset < 0x100 ||
        (uint64_t)text_file_offset + text_size > file_size)
        return snprintf(output, output_capacity, "error|NSO text segment bounds are invalid.") < (int)output_capacity ? 0 : -2;

    csh handle;
    cs_err err = cs_open(CS_ARCH_ARM64, CS_MODE_ARM, &handle);
    if (err != CS_ERR_OK)
        return snprintf(output, output_capacity, "error|Capstone initialization failed: %s", cs_strerror(err)) < (int)output_capacity ? 0 : -2;
    cs_option(handle, CS_OPT_DETAIL, CS_OPT_ON);
    cs_option(handle, CS_OPT_SKIPDATA, CS_OPT_ON);

    size_t used = 0;
    uint64_t scanned_records = 0;
    uint32_t stubs = 0, resolved = 0, unresolved = 0, chains = 0;
    uint64_t last_stub = UINT64_MAX;
    if (append_text(output, output_capacity, &used,
                    "discovery|main-text linker-stub scan; static pointer chains are followed up to 8 levels; no code is modified.\\n") != 0) {
        cs_close(&handle); return -2;
    }

    const size_t chunk_size = 0x10000;
    for (size_t base = 0; base < text_size; base += chunk_size) {
        size_t length = text_size - base;
        if (length > chunk_size) length = chunk_size;
        // A 16-byte overlap ensures a trampoline straddling a chunk boundary
        // remains visible in full; duplicate starts are filtered below.
        if (base + length < text_size && length <= SIZE_MAX - 20) length += 20;
        cs_insn *items = NULL;
        size_t count = cs_disasm(handle, file + text_file_offset + base, length,
                                 (uint64_t)base, 0, &items);
        scanned_records += count;
        for (size_t i = 0; i + 3 < count; i++) {
            if (strcmp(items[i].mnemonic, "adrp") != 0 ||
                strcmp(items[i + 1].mnemonic, "ldr") != 0 ||
                strcmp(items[i + 2].mnemonic, "add") != 0 ||
                strcmp(items[i + 3].mnemonic, "br") != 0) continue;
            uint64_t start = items[i].address;
            uint64_t slot = 0, raw = 0;
            size_t slot_file = SIZE_MAX;
            int has_save = 0;
            if (!resolve_linker_stub_at(handle, file, file_size, text_file_offset,
                                        text_size, start, &start, &slot, &raw,
                                        &slot_file, &has_save)) continue;
            if (start == last_stub) continue;
            last_stub = start;
            if (stubs >= 512) continue;

            if (append_text(output, output_capacity, &used,
                            "stub|offset=%08llx|type=%sadrp-ldr-add-br|slot_va=%08llx|",
                            (unsigned long long)start, has_save ? "save-x16-x30+" : "",
                            (unsigned long long)slot) != 0) {
                cs_free(items, count); cs_close(&handle); return -2;
            }
            if (slot_file == SIZE_MAX) {
                if (append_text(output, output_capacity, &used, "resolution=slot-not-file-backed\\n") != 0) {
                    cs_free(items, count); cs_close(&handle); return -2;
                }
                unresolved++;
            } else {
                if (append_text(output, output_capacity, &used,
                                "slot_file_offset=%08llx|raw_pointer=%016llx\\n",
                                (unsigned long long)slot_file, (unsigned long long)raw) != 0) {
                    cs_free(items, count); cs_close(&handle); return -2;
                }
                if (raw == 0) {
                    if (append_text(output, output_capacity, &used,
                                    "resolution|stub=%08llx|null-or-unresolved\\n",
                                    (unsigned long long)start) != 0) {
                        cs_free(items, count); cs_close(&handle); return -2;
                    }
                    unresolved++;
                } else {
                    uint32_t text_mem = read_le32(file + 0x14);
                    if (raw >= text_mem && raw - text_mem < text_size) {
                        if (append_text(output, output_capacity, &used,
                                        "resolution|stub=%08llx|text_offset=%08llx|static-pointer-in-text\\n",
                                        (unsigned long long)start,
                                        (unsigned long long)(raw - text_mem)) != 0) {
                            cs_free(items, count); cs_close(&handle); return -2;
                        }
                        resolved++;
                        uint64_t chain_from = start;
                        uint64_t target_offset = raw - text_mem;
                        uint64_t visited[8] = {0};
                        size_t visited_count = 0;
                        while (visited_count < 8) {
                            int seen = 0;
                            for (size_t v = 0; v < visited_count; v++)
                                if (visited[v] == target_offset) seen = 1;
                            if (seen) {
                                if (append_text(output, output_capacity, &used,
                                                "chain|from=%08llx|to=%08llx|cycle\\n",
                                                (unsigned long long)chain_from,
                                                (unsigned long long)target_offset) != 0) {
                                    cs_free(items, count); cs_close(&handle); return -2;
                                }
                                break;
                            }
                            visited[visited_count++] = target_offset;
                            uint64_t next_start = 0, next_slot = 0, next_raw = 0;
                            size_t next_file = SIZE_MAX;
                            int next_save = 0;
                            if (!resolve_linker_stub_at(handle, file, file_size,
                                                        text_file_offset, text_size,
                                                        target_offset, &next_start,
                                                        &next_slot, &next_raw,
                                                        &next_file, &next_save)) {
                                if (append_text(output, output_capacity, &used,
                                                "chain|from=%08llx|to=%08llx|terminal=non-stub\\n",
                                                (unsigned long long)chain_from,
                                                (unsigned long long)target_offset) != 0) {
                                    cs_free(items, count); cs_close(&handle); return -2;
                                }
                                break;
                            }
                            if (append_text(output, output_capacity, &used,
                                            "chain|from=%08llx|to=%08llx|stub=%08llx|slot_va=%08llx|raw_pointer=%016llx\\n",
                                            (unsigned long long)chain_from,
                                            (unsigned long long)target_offset,
                                            (unsigned long long)next_start,
                                            (unsigned long long)next_slot,
                                            (unsigned long long)next_raw) != 0) {
                                cs_free(items, count); cs_close(&handle); return -2;
                            }
                            chains++;
                            if (next_raw == 0) {
                                if (append_text(output, output_capacity, &used,
                                                "chain_resolution|stub=%08llx|null-or-unresolved\\n",
                                                (unsigned long long)next_start) != 0) {
                                    cs_free(items, count); cs_close(&handle); return -2;
                                }
                                unresolved++;
                                break;
                            }
                            if (next_raw < text_mem || next_raw - text_mem >= text_size) {
                                if (append_text(output, output_capacity, &used,
                                                "chain_resolution|stub=%08llx|not-a-static-text-address\\n",
                                                (unsigned long long)next_start) != 0) {
                                    cs_free(items, count); cs_close(&handle); return -2;
                                }
                                unresolved++;
                                break;
                            }
                            chain_from = next_start;
                            target_offset = next_raw - text_mem;
                        }
                    } else {
                        if (append_text(output, output_capacity, &used,
                                        "resolution|stub=%08llx|not-a-static-text-address\\n",
                                        (unsigned long long)start) != 0) {
                            cs_free(items, count); cs_close(&handle); return -2;
                        }
                        unresolved++;
                    }
                }
            }
            stubs++;
        }
        cs_free(items, count);
        if (used + 2048 >= output_capacity) {
            cs_close(&handle);
            return append_text(output, output_capacity, &used,
                               "warning|Output limit reached; increase output capacity or reduce report limit.\\n") == 0 ? 0 : -2;
        }
    }
    int result = append_text(output, output_capacity, &used,
        "summary|text_bytes=%u|decoded_records=%llu|linker_stubs=%u|static_text_targets=%u|unresolved=%u|traced_chain_edges=%u\\n",
        text_size, (unsigned long long)scanned_records, stubs, resolved, unresolved, chains);
    cs_close(&handle);
    return result == 0 ? 0 : -2;
}

// Inspect a selected NSO text-relative address. A bounded control-flow walk
// estimates the reachable function body; direct calls, tail branches, and
// linker-style indirect jump stubs are reported separately. Read-only.
NXN_EXPORT int32_t nxn_arm64_inspect_function(const uint8_t *file, size_t file_size,
                                               uint64_t function_offset,
                                               char *output, size_t output_capacity) {
    if (!file || !output || output_capacity < 512) return -1;
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
    if (function_offset >= text_size || (function_offset & 3u) != 0)
        return snprintf(output, output_capacity, "error|Offset must be a 4-byte-aligned position inside the NSO text segment.") < (int)output_capacity ? 0 : -2;

    csh handle;
    cs_err err = cs_open(CS_ARCH_ARM64, CS_MODE_ARM, &handle);
    if (err != CS_ERR_OK)
        return snprintf(output, output_capacity, "error|Capstone initialization failed: %s", cs_strerror(err)) < (int)output_capacity ? 0 : -2;
    cs_option(handle, CS_OPT_DETAIL, CS_OPT_ON);
    cs_option(handle, CS_OPT_SKIPDATA, CS_OPT_ON);

    size_t used = 0;
    uint64_t window_end = function_offset + 0x600;
    if (window_end > text_size) window_end = text_size;
    size_t window_length = (size_t)(window_end - function_offset);
    cs_insn *region = NULL;
    size_t region_count = cs_disasm(handle, file + text_offset + function_offset,
                                    window_length, function_offset, 0, &region);
    if (region_count == 0) {
        cs_close(&handle);
        return snprintf(output, output_capacity, "error|Capstone could not decode at the selected offset.") < (int)output_capacity ? 0 : -2;
    }

    // Linker stubs may optionally save x16/x30 before the ADRP/LDR/ADD/BR
    // sequence. Recognize both layouts without mistaking an arbitrary STP for
    // part of the stub.
    int is_linker_stub = 0;
    int stub_has_save_prologue = 0;
    size_t stub_sequence_start = 0;
    uint64_t slot_va = 0;
    if (region_count >= 5 &&
        strcmp(region[0].mnemonic, "stp") == 0 &&
        strstr(region[0].op_str, "x16, x30, [sp, #-0x10]!") != NULL) {
        stub_has_save_prologue = 1;
        stub_sequence_start = 1;
    }
    if (region_count >= stub_sequence_start + 4 &&
        strcmp(region[stub_sequence_start + 0].mnemonic, "adrp") == 0 &&
        strcmp(region[stub_sequence_start + 1].mnemonic, "ldr") == 0 &&
        strcmp(region[stub_sequence_start + 2].mnemonic, "add") == 0 &&
        strcmp(region[stub_sequence_start + 3].mnemonic, "br") == 0 &&
        strstr(region[stub_sequence_start + 0].op_str, "x16,") != NULL &&
        strstr(region[stub_sequence_start + 1].op_str, "x17, [x16") != NULL &&
        strstr(region[stub_sequence_start + 2].op_str, "x16, x16") != NULL &&
        strstr(region[stub_sequence_start + 3].op_str, "x17") != NULL) {
        uint64_t page = 0, load_delta = 0;
        if (parse_hash_immediate(region[stub_sequence_start + 0].op_str, &page) &&
            parse_hash_immediate(region[stub_sequence_start + 1].op_str, &load_delta)) {
            slot_va = page + load_delta;
            is_linker_stub = 1;
        }
    }

    // Walk reachable control flow from the selected entry. Conditional branches
    // retain their fallthrough edge; direct B follows only its target; RET/BR
    // terminate a path. BL/BLR are calls and continue at the next instruction.
    enum { MAX_REGION_INSNS = 512 };
    uint8_t reachable[MAX_REGION_INSNS] = {0};
    int queue[MAX_REGION_INSNS];
    size_t queue_head = 0, queue_tail = 0;
    uint64_t estimated_end = function_offset;
    uint32_t reachable_count = 0, return_count = 0, tail_branch_count = 0;
    if (region_count > MAX_REGION_INSNS) region_count = MAX_REGION_INSNS;
    reachable[0] = 1;
    queue[queue_tail++] = 0;
    while (queue_head < queue_tail) {
        int index = queue[queue_head++];
        cs_insn *insn = &region[index];
        uint64_t next = insn->address + insn->size;
        if (next > estimated_end) estimated_end = next;
        reachable_count++;

        if (strcmp(insn->mnemonic, "ret") == 0) {
            return_count++;
            continue;
        }
        if (strcmp(insn->mnemonic, "br") == 0) {
            tail_branch_count++;
            continue;
        }
        if (is_direct_branch(insn->mnemonic)) {
            uint64_t target = 0;
            int has_target = parse_hash_immediate(insn->op_str, &target);
            int target_index = has_target ? find_instruction_at(region, region_count, target) : -1;
            if (target_index >= 0 && !reachable[target_index]) {
                reachable[target_index] = 1;
                if (queue_tail < MAX_REGION_INSNS) queue[queue_tail++] = target_index;
            } else if (target_index < 0) {
                tail_branch_count++;
            }
            if (is_conditional_branch(insn->mnemonic)) {
                int fallthrough = find_instruction_at(region, region_count, next);
                if (fallthrough >= 0 && !reachable[fallthrough]) {
                    reachable[fallthrough] = 1;
                    if (queue_tail < MAX_REGION_INSNS) queue[queue_tail++] = fallthrough;
                }
            }
            continue;
        }
        int fallthrough = find_instruction_at(region, region_count, next);
        if (fallthrough >= 0 && !reachable[fallthrough]) {
            reachable[fallthrough] = 1;
            if (queue_tail < MAX_REGION_INSNS) queue[queue_tail++] = fallthrough;
        }
    }

    const char *kind = is_linker_stub ? "linker-stub" : "code";
    if (append_text(output, output_capacity, &used,
                    "function|offset=%08llx|estimated_end=%08llx|bytes=%llu|kind=%s|reachable_instructions=%u\n",
                    (unsigned long long)function_offset, (unsigned long long)estimated_end,
                    (unsigned long long)(estimated_end - function_offset), kind, reachable_count) != 0) {
        cs_free(region, region_count); cs_close(&handle); return -2;
    }

    if (is_linker_stub) {
        size_t pointer_file_offset = 0;
        if (map_nso_va_to_file(file, file_size, slot_va, 8, &pointer_file_offset)) {
            uint64_t raw_target = 0;
            for (size_t b = 0; b < 8; b++) raw_target |= (uint64_t)file[pointer_file_offset + b] << (b * 8);
            if (append_text(output, output_capacity, &used,
                            "stub|type=%sadrp-ldr-add-br|slot_va=%08llx|slot_file_offset=%08llx|raw_pointer=%016llx\n",
                            stub_has_save_prologue ? "save-x16-x30+" : "",
                            (unsigned long long)slot_va, (unsigned long long)pointer_file_offset,
                            (unsigned long long)raw_target) != 0) {
                cs_free(region, region_count); cs_close(&handle); return -2;
            }
            if (raw_target == 0) {
                if (append_text(output, output_capacity, &used,
                                "stub_target|resolution=null-or-unresolved\n") != 0) {
                    cs_free(region, region_count); cs_close(&handle); return -2;
                }
            } else {
                uint32_t text_mem = read_le32(file + 0x14);
                if (raw_target >= text_mem && raw_target - text_mem < text_size) {
                    if (append_text(output, output_capacity, &used,
                                    "stub_target|text_offset=%08llx|resolution=static-pointer-in-text\n",
                                    (unsigned long long)(raw_target - text_mem)) != 0) {
                        cs_free(region, region_count); cs_close(&handle); return -2;
                    }
                } else {
                    if (append_text(output, output_capacity, &used,
                                    "stub_target|resolution=not-a-static-text-address\n") != 0) {
                        cs_free(region, region_count); cs_close(&handle); return -2;
                    }
                }
            }
        } else if (append_text(output, output_capacity, &used,
                               "stub|type=adrp-ldr-add-br|slot_va=%08llx|resolution=slot-not-file-backed\n",
                               (unsigned long long)slot_va) != 0) {
            cs_free(region, region_count); cs_close(&handle); return -2;
        }
    }

    uint32_t direct_callees = 0;
    for (size_t i = 0; i < region_count; i++) {
        if (!reachable[i]) continue;
        cs_insn *insn = &region[i];
        if (append_text(output, output_capacity, &used, "insn|%08llx|%s|%s\n",
                        (unsigned long long)insn->address, insn->mnemonic, insn->op_str) != 0) {
            cs_free(region, region_count); cs_close(&handle); return -2;
        }
        if (strcmp(insn->mnemonic, "bl") == 0) {
            uint64_t target = 0;
            if (parse_hash_immediate(insn->op_str, &target)) {
                if (append_text(output, output_capacity, &used, "callee|%08llx|%08llx\n",
                                (unsigned long long)insn->address,
                                (unsigned long long)target) != 0) {
                    cs_free(region, region_count); cs_close(&handle); return -2;
                }
                direct_callees++;
            }
        } else if (strcmp(insn->mnemonic, "b") == 0) {
            uint64_t target = 0;
            if (parse_hash_immediate(insn->op_str, &target) &&
                (target < function_offset || target >= estimated_end)) {
                if (append_text(output, output_capacity, &used, "tail_call|%08llx|%08llx\n",
                                (unsigned long long)insn->address,
                                (unsigned long long)target) != 0) {
                    cs_free(region, region_count); cs_close(&handle); return -2;
                }
            }
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
                uint64_t target = 0;
                if (parse_hash_immediate(insn->op_str, &target) &&
                    target == function_offset && callers < 64) {
                    if (append_text(output, output_capacity, &used, "caller|%08llx\n",
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
                    "summary|caller_sites_listed=%u|caller_limit=64|direct_callees=%u|returns=%u|tail_or_indirect_exits=%u|boundary=reachable-control-flow\n",
                    callers, direct_callees, return_count, tail_branch_count) != 0) {
        cs_close(&handle); return -2;
    }
    cs_close(&handle);
    return 0;
}
