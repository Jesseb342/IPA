#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
#include "spirv_cross_c.h"

#if defined(__APPLE__)
#define NXN_EXPORT __attribute__((visibility("default")))
#else
#define NXN_EXPORT
#endif

extern "C" NXN_EXPORT int nxn_spirv_to_msl_file(
    const char *input_path, const char *output_path, const char *diagnostic_path)
{
    if (!input_path || !output_path || !diagnostic_path) return 10;
    spvc_context context = nullptr;
    spvc_result result = spvc_context_create(&context);
    if (result != SPVC_SUCCESS || !context) return 11;

    auto fail = [&](int code, const char *message) {
        std::ofstream log(diagnostic_path, std::ios::binary);
        if (log) log << (message ? message : "unknown SPIRV-Cross error") << "\n";
        spvc_context_destroy(context);
        return code;
    };

    std::ifstream input(input_path, std::ios::binary);
    if (!input) return fail(12, "Could not open SPIR-V input.");
    std::vector<uint32_t> words((std::istreambuf_iterator<char>(input)), {});
    if (words.empty() || (words.size() * sizeof(uint32_t)) % 4 != 0 || words[0] != 0x07230203)
        return fail(13, "Input is not a valid little-endian SPIR-V module.");

    spvc_parsed_ir ir = nullptr;
    result = spvc_context_parse_spirv(context, words.data(), words.size(), &ir);
    if (result != SPVC_SUCCESS) return fail(14, spvc_context_get_last_error_string(context));

    spvc_compiler compiler = nullptr;
    result = spvc_context_create_compiler(context, SPVC_BACKEND_MSL, ir,
        SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler);
    if (result != SPVC_SUCCESS) return fail(15, spvc_context_get_last_error_string(context));

    spvc_compiler_options options = nullptr;
    result = spvc_compiler_create_compiler_options(compiler, &options);
    if (result != SPVC_SUCCESS) return fail(16, spvc_context_get_last_error_string(context));

    result = spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_VERSION, 23000);
    if (result != SPVC_SUCCESS) return fail(17, spvc_context_get_last_error_string(context));
    result = spvc_compiler_install_compiler_options(compiler, options);
    if (result != SPVC_SUCCESS) return fail(18, spvc_context_get_last_error_string(context));

    const char *msl = nullptr;
    result = spvc_compiler_compile(compiler, &msl);
    if (result != SPVC_SUCCESS || !msl) return fail(19, spvc_context_get_last_error_string(context));

    std::ofstream output(output_path, std::ios::binary);
    if (!output) return fail(20, "Could not create MSL output.");
    output << msl;
    if (!output.good()) return fail(21, "Writing MSL output failed.");

    std::ofstream log(diagnostic_path, std::ios::binary);
    if (log) {
        unsigned major = 0, minor = 0, patch = 0;
        spvc_get_version(&major, &minor, &patch);
        log << "status|msl_generated\n"
            << "spirv_cross_version|" << major << "." << minor << "." << patch << "\n"
            << "backend|MSL\n"
            << "msl_version|2.3.0\n"
            << "input_bytes|" << words.size() * sizeof(uint32_t) << "\n";
    }
    spvc_context_destroy(context);
    return 0;
}
