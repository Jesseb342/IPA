#!/usr/bin/env python3
"""Wire the IPA repository's import screen into the upstream iOS shell."""

from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_import_ui.py path/to/front_ios.m")

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")

replacements = [
    (
        'bool dm_show_launcher(void *view_controller, void (*done)(void));   // Launcher.swift: false = no launcher (no dm/launcher.json, or DM_LAUNCHER=0)\n',
        'bool dm_show_launcher(void *view_controller, void (*done)(void));   // Launcher.swift: false = no launcher (no dm/launcher.json, or DM_LAUNCHER=0)\n'
        'void dm_show_import_screen(void *view_controller);   // ImportScreen.swift: shown when no game has been packed into this shell yet\n',
    ),
    (
        '@property (nonatomic) BOOL launched;\n',
        '@property (nonatomic) BOOL launched;\n@property (nonatomic) BOOL importScreenShown;\n',
    ),
    (
        '    if (!front_ios_boot_ok()) {   // No game files: show a hint and do not start the host\n'
        '        const char *why = front_ios_boot_message();\n'
        '        [self showHint:why ? [NSString stringWithFormat:@"Game files unusable.\\n%s", why] : @"Game files not found.\\nPut the RomFS folder into this App\'s Documents as \\"romfs\\" (Files app), then restart."]; return;\n'
        '    }\n',
        '    if (!front_ios_boot_ok()) return;   // The import screen is presented in viewDidAppear.\n',
    ),
    (
        '    if (!front_ios_boot_ok() && front_ios_boot_message() && !self.presentedViewController) {   // a slim build whose game file image is missing or another version (main.m)\n'
        '        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Game files" message:@(front_ios_boot_message()) preferredStyle:UIAlertControllerStyleAlert];\n'
        '        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];\n'
        '        [self presentViewController:a animated:YES completion:nil];\n'
        '    }\n'
        '    if (self.launched || !front_ios_boot_ok()) return;\n',
        '    if (dm_shell_library_needed() || !front_ios_boot_ok()) {\n'
        '        if (!self.importScreenShown && !self.presentedViewController) {\n'
        '            self.importScreenShown = YES;\n'
        '            dm_show_import_screen((__bridge void *)self);\n'
        '        }\n'
        '        return;\n'
        '    }\n'
        '    if (self.launched) return;\n',
    ),
]

for old, new in replacements:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one patch anchor in {path}, found {count}: {old[:100]!r}")
    source = source.replace(old, new, 1)

path.write_text(source, encoding="utf-8")
print(f"Import screen wired into {path}")
