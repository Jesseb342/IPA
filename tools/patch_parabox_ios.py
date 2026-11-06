from pathlib import Path
import sys

root = Path(sys.argv[1])
front = root / "dm/ios/Sources/front_ios.m"
build = root / "dm/ios/tools/build_ipa.sh"

source = front.read_text()
source = source.replace(
    "#import <AVFAudio/AVFAudio.h>",
    "#import <AVFAudio/AVFAudio.h>\n#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>",
    1,
)
source = source.replace(
    "@interface DmRootVC : UIViewController",
    "@interface DmRootVC : UIViewController <UIDocumentPickerDelegate>",
    1,
)
source = source.replace(
    "@property (nonatomic, strong) UILabel *fps;",
    "@property (nonatomic, strong) UILabel *fps;\n"
    "@property (nonatomic, strong) UILabel *importStatus;\n"
    "@property (nonatomic, strong) UIButton *importButton;",
    1,
)

old = '''        lb.text = @"Game files not found.\\nPut the RomFS folder into this App's Documents as \\"romfs\\" (Files app), then restart.";
        [self.view addSubview:lb]; return;'''
new = '''        lb.text = @"First launch: select your Parabox base NSP and prod.keys. The game data will be extracted on this iPhone.";
        self.importStatus = lb;
        [self.view addSubview:lb];

        self.importButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.importButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.importButton setTitle:@"Import NSP + prod.keys" forState:UIControlStateNormal];
        self.importButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        self.importButton.backgroundColor = UIColor.whiteColor;
        [self.importButton setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
        self.importButton.layer.cornerRadius = 12;
        self.importButton.contentEdgeInsets = UIEdgeInsetsMake(14, 24, 14, 24);
        [self.importButton addTarget:self action:@selector(dm_chooseGameFiles) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.importButton];
        [NSLayoutConstraint activateConstraints:@[
            [self.importButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [self.importButton.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:100]
        ]];
        return;'''
if old not in source:
    raise SystemExit("Could not find the exact missing-game UI block; refusing to patch.")
source = source.replace(old, new, 1)

anchor = "- (void)viewDidLayoutSubviews {"
methods = r'''- (void)dm_chooseGameFiles {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *nspURL = nil;
    NSURL *keysURL = nil;
    for (NSURL *url in urls) {
        NSString *name = url.lastPathComponent.lowercaseString;
        if ([name hasSuffix:@".nsp"]) nspURL = url;
        else if ([name isEqualToString:@"prod.keys"] || [name hasSuffix:@".keys"]) keysURL = url;
    }
    if (!nspURL || !keysURL) {
        self.importStatus.text = @"Select exactly one .nsp file and your prod.keys file together.";
        return;
    }

    self.importButton.enabled = NO;
    self.importStatus.text = @"Preparing files for extraction…";
    NSString *workPath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *nspPath = [workPath stringByAppendingPathComponent:@"base.nsp"];
    NSString *keysPath = [workPath stringByAppendingPathComponent:@"prod.keys"];
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *romfsPath = [documents stringByAppendingPathComponent:@"romfs"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *error = nil;
        [fm createDirectoryAtPath:workPath withIntermediateDirectories:YES attributes:nil error:&error];

        NSArray<NSURL *> *sources = @[nspURL, keysURL];
        NSArray<NSString *> *destinations = @[nspPath, keysPath];
        for (NSUInteger i = 0; !error && i < sources.count; i++) {
            NSURL *source = sources[i];
            BOOL scoped = [source startAccessingSecurityScopedResource];
            [fm copyItemAtURL:source toURL:[NSURL fileURLWithPath:destinations[i]] error:&error];
            if (scoped) [source stopAccessingSecurityScopedResource];
        }

        int result = 1;
        char errorText[1024] = {0};
        if (!error) {
            result = parabox_extract_base_romfs(
                keysPath.fileSystemRepresentation,
                nspPath.fileSystemRepresentation,
                romfsPath.fileSystemRepresentation,
                errorText,
                (int)sizeof(errorText));
        }

        [fm removeItemAtPath:workPath error:nil];
        NSString *message = error ? error.localizedDescription :
            (result == 0 ? @"RomFS imported successfully. Fully close this app, then reopen it to start Parabox."
                         : [NSString stringWithUTF8String:errorText[0] ? errorText : "The extractor returned an unknown error."]);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.importStatus.text = message;
            self.importButton.enabled = YES;
        });
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
}
'''
if source.count(anchor) != 1:
    raise SystemExit("Could not find the iOS view layout insertion point.")
source = source.replace(anchor, methods + "\n" + anchor, 1)
source = source.replace(
    '#include "dm.h"',
    '#include "dm.h"\nextern int parabox_extract_base_romfs(const char *keysPath, const char *nspPath, const char *destinationPath, char *errorText, int errorCapacity);',
    1,
)
front.write_text(source)

build_source = build.read_text()
old_line = 'echo "OTHER_LDFLAGS = \\$(inherited) \\$(DM_FRAMEWORKS) $F" >> Gen/dm.xcconfig'
new_line = old_line + '''
if [ -n "${DM_LIBHAC_AOT_LIB:-}" ]; then
  [ -s "$DM_LIBHAC_AOT_LIB" ] || die "NativeAOT LibHac library missing: $DM_LIBHAC_AOT_LIB"
  echo "OTHER_LDFLAGS = \\$(inherited) -force_load $DM_LIBHAC_AOT_LIB -Wl,-u,_NativeAOT_StaticInitialization -framework CoreFoundation -framework CryptoKit -framework Foundation -framework Network -framework Security -framework GSS -lobjc -lswiftCore -lswiftFoundation -licucore -lz -lm -L/usr/lib/swift" >> Gen/dm.xcconfig
  t "linked LibHac iOS extractor: $DM_LIBHAC_AOT_LIB"
fi'''
if build_source.count(old_line) != 1:
    raise SystemExit("Could not find unique linker-flags insertion point in build_ipa.sh.")
build.write_text(build_source.replace(old_line, new_line, 1))
print("Patched the iOS first-launch NSP/keys importer and NativeAOT linker integration.")
