#include <CommonCrypto/CommonDigest.h>

#import "authenticator/BaseAuthenticator.h"
#import "AFNetworking.h"
#import "LauncherPreferences.h"
#import "LauncherViewController.h"
#import "MinecraftDownloader.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

/*
todo for now - might change anytime
- make the entire download work anyways
- cleanup later, before merging?
- possibility fix incorrect stuff

- Prevent download when account=local
- download Log4J patch (or use existing one?)
- download a vanilla version (tested)
- download a modded ver with inheritsFrom:
 + not downloaded
 + inherit version not found
 + no internet connection (?)
- download a modded ver without inheritsFrom
- SHA check:
 + client json (tested)
 + libraries (tested)
 + client jar (tested)
 + assets
- download assets
 + new structure
 + old structure (mapped)
*/  

@implementation MinecraftDownloader

static AFURLSessionManager* manager;

// Check if the account has permission to download
+ (BOOL)checkAccessWithDialog:(BOOL)show {
    // for now
    if ([BaseAuthenticator.current.authData[@"username"] hasPrefix:@"Demo."] || BaseAuthenticator.current.authData[@"xboxGamertag"] != nil) {
        return YES;
    } else {
        if (show) {
            showDialog(viewController, @"Error", @"Minecraft can't be legally installed when logged in with a local account. Please switch to an online account to continue.");
        }
        return NO;
    }
}

// Check SHA of the file
+ (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    if (sha == nil) {
        // When sha = skip, only check for file existence
        BOOL existence = [NSFileManager.defaultManager fileExistsAtPath:path];
        if (existence) {
            NSLog(@"[MCDL] Warning: couldn't find SHA for %@, have to assume it's good.", path);
        }
        return existence;
    }

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        NSLog(@"[MCDL] SHA1 checker: file doesn't exist: %@", path.lastPathComponent);
        return NO;
    }

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *localSHA = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [localSHA appendFormat:@"%02x", digest[i]];
    }

    BOOL check = [sha isEqualToString:localSHA];
    if (!check || [getPreference(@"debug_logging") boolValue]) {
        NSLog(@"[MCDL] SHA1 %@ for %@%@",
          (check ? @"passed" : @"failed"), 
          (altName ? altName : path.lastPathComponent),
          (check ? @"" : [NSString stringWithFormat:@" (expected: %@, got: %@)", sha, localSHA]));
    }
    return check;
}

+ (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    if ([getPreference(@"check_sha") boolValue]) {
        return [self checkSHAIgnorePref:sha forFile:path altName:altName];
    } else {
        return [NSFileManager.defaultManager fileExistsAtPath:path];
    }
}

+ (NSMutableDictionary *)readFromFile:(NSString *)version sha:(NSString *)sha {
    NSError *error;
    NSString *path = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), version, version];
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        NSLog(@"[MCDL] Error: couldn't read %@: %@", path, error.localizedDescription);
        showDialog(viewController, @"Error", [NSString stringWithFormat:@"Could not read %@: %@", path, error.localizedDescription]);
        return nil;
    }

    NSData* data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (![self checkSHAIgnorePref:sha forFile:path altName:nil] && error) {
        // If it gives an error, we check back SHA 
        NSLog(@"[MCDL] Error: parsing %@: %@", path, error.localizedDescription);
        showDialog(viewController, @"Error", [NSString stringWithFormat:@"Error parsing %@ (SHA mismatch, is file corrupted?): %@", path, error.localizedDescription]);
    } else if (error) {
        // This shouldn't happen
        NSLog(@"[MCDL] Fatal Error: parsing %@ (SHA Passed): %@", path, error.localizedDescription);
        abort();
    }
    return dict;
}

// Handle inheritsFrom
+ (void)processVersion:(NSMutableDictionary *)json inheritsFrom:(id)object progress:(NSProgress *)mainProgress callback:(MDCallback)callback success:(void (^)(NSMutableDictionary *json))success {
    [self downloadClientJson:object progress:mainProgress callback:callback success:^(NSMutableDictionary *inheritsFrom){
        [self insertSafety:inheritsFrom from:json arr:@[
            @"assetIndex", @"assets", @"id",
            @"inheritsFrom",
            @"mainClass", @"minecraftArguments",
            @"optifineLib", @"releaseTime", @"time", @"type"
        ]];
        inheritsFrom[@"arguments"] = json[@"arguments"];

        for (NSMutableDictionary *lib in json[@"libraries"]) {
            NSString *libName = [lib[@"name"] substringToIndex:[lib[@"name"] rangeOfString:@":" options:NSBackwardsSearch].location];
            int i;
            for (i = 0; i < [inheritsFrom[@"libraries"] count]; i++) {
                NSMutableDictionary *libAdded = inheritsFrom[@"libraries"][i];
                NSString *libAddedName = [libAdded[@"name"] substringToIndex:[libAdded[@"name"] rangeOfString:@":" options:NSBackwardsSearch].location];

                if ([libAdded[@"name"] hasPrefix:libName]) {
                                //Log.d(APP_NAME, "Library " + libName + ": Replaced version " + 
                                    //libName.substring(libName.lastIndexOf(":") + 1) + " with " +
                                    //libAddedName.substring(libAddedName.lastIndexOf(":") + 1));
                    inheritsFrom[@"libraries"][i] = lib;
                    i = -1;
                    break;
                }
            }

            if (i != -1) {
                [inheritsFrom[@"libraries"] addObject:lib];
            }
        }
                    
        //inheritsFrom[@"inheritsFrom"] = nil;
        [self downloadClientJson:inheritsFrom[@"assetIndex"] progress:mainProgress callback:callback success:^(NSMutableDictionary *assetJson){
            inheritsFrom[@"assetIndexObj"] = assetJson;
            success(inheritsFrom);
        }];
    }];
}

// Download the client and assets index file
+ (void)downloadClientJson:(NSObject *)version progress:(NSProgress *)mainProgress callback:(MDCallback)callback success:(void (^)(NSMutableDictionary *json))success {
    ++mainProgress.totalUnitCount;

    BOOL isAssetIndex = NO;
    NSString *versionStr, *versionURL, *versionSHA;
    if ([version isKindOfClass:[NSDictionary class]]) {
        isAssetIndex = [version valueForKey:@"totalSize"] != nil;
        versionStr = [version valueForKey:@"id"];
        versionURL = [version valueForKey:@"url"];
        versionSHA = versionURL.stringByDeletingLastPathComponent.lastPathComponent;
    } else {
        versionStr = (NSString *)version;
        versionSHA = nil;
    }

    NSString *jsonPath;
    if (isAssetIndex) {
        versionStr = [NSString stringWithFormat:@"assets/indexes/%@", versionStr];
        jsonPath = [NSString stringWithFormat:@"%s/%@.json", getenv("POJAV_GAME_DIR"), versionStr];
    } else {
        jsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), versionStr, versionStr];
    }

    if (![self checkSHA:versionSHA forFile:jsonPath altName:nil]) {
        if (![self checkAccessWithDialog:YES]) {
            callback(nil, nil, nil);
            return;
        }

        NSString *verPath = jsonPath.stringByDeletingLastPathComponent;
        NSError *error;
        [NSFileManager.defaultManager createDirectoryAtPath:verPath withIntermediateDirectories:YES attributes:nil error:&error];
        if (error != nil) {
            NSString *errorStr = [NSString stringWithFormat:@"Failed to create directory %@: %@", verPath, error.localizedDescription];
            NSLog(@"[MCDL] Error: %@", errorStr);
            showDialog(viewController, @"Error", errorStr);
            callback(nil, nil, nil);
            return;
        }

        callback([NSString stringWithFormat:@"Downloading %@.json", versionStr], mainProgress, nil);
        NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:versionURL]];

        NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull progress){
            callback([NSString stringWithFormat:@"Downloading %@.json", versionStr], mainProgress, progress);
        } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) { 
            return [NSURL fileURLWithPath:jsonPath];
        } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
            if (error != nil) { // FIXME: correct?
                NSString *errorStr = [NSString stringWithFormat:@"Failed to download %@: %@", versionURL, error.localizedDescription];
                NSLog(@"[MCDL] Error: %@", errorStr);
                showDialog(viewController, @"Error", errorStr);
                callback(nil, nil, nil);
                return;
            } else {
                // A version from the offical server won't likely to have inheritsFrom, so return immediately
                if (![self checkSHA:versionSHA forFile:jsonPath altName:nil]) {
                    // Abort when a downloaded file's SHA mismatches
                    showDialog(viewController, @"Error", [NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", versionStr]);
                    callback(nil, nil, nil);
                    return;
                }
                ++mainProgress.completedUnitCount;

                NSMutableDictionary *json = parseJSONFromFile(jsonPath);
                if (isAssetIndex) {
                    success(json);
                    return;
                }

                [self downloadClientJson:json[@"assetIndex"] progress:mainProgress callback:callback success:^(NSMutableDictionary *assetJson){
                    json[@"assetIndexObj"] = assetJson;
                    success(json);
                }];
            }
        }];
        callback([NSString stringWithFormat:@"Downloading %@.json", versionStr], mainProgress, [manager downloadProgressForTask:downloadTask]);
        [downloadTask resume];
    } else {
        NSMutableDictionary *json = parseJSONFromFile(jsonPath);
        if (json == nil) {
            callback(nil, nil, nil);
            return;
        }
        if (isAssetIndex) {
            success(json);
            return;
        }
        if (json[@"inheritsFrom"] == nil) {
            ++mainProgress.completedUnitCount;
            [self downloadClientJson:json[@"assetIndex"] progress:mainProgress callback:callback success:^(NSMutableDictionary *assetJson){
                json[@"assetIndexObj"] = assetJson;
                success(json);
            }];
            return;
        }

        // Find the inheritsFrom
        for (id object in versionList) {
            NSString *iversionStr;
            if ([object isKindOfClass:[NSDictionary class]]) {
                iversionStr = [object valueForKey:@"id"];
            } else {
                iversionStr = (NSString *)object;
            }
            if ([iversionStr isEqualToString:json[@"inheritsFrom"]]) {
                [self processVersion:json inheritsFrom:object progress:mainProgress callback:callback success:success];
                return;
            }
        }

        // If the inheritsFrom is not found, return an error
        showDialog(viewController, @"Error", [NSString stringWithFormat:@"Could not find inheritsFrom=%@ for version %@", json[@"inheritsFrom"], versionStr]);
    }
}

+ (void)insertSafety:(NSMutableDictionary *)targetVer from:(NSDictionary *)fromVer arr:(NSArray *)arr {
    for (NSString *key in arr) {
        if (([fromVer[key] isKindOfClass:NSString.class] && [fromVer[key] length] > 0) || targetVer[key] == nil) {
            targetVer[key] = fromVer[key];
        } else {
            NSLog(@"[MCDL] insertSafety: how to insert %@?", key);
        }
    }
}

+ (void)tweakVersionJson:(NSMutableDictionary *)json {
    // Exclude some libraries
    for (NSMutableDictionary *library in json[@"libraries"]) {
        library[@"skip"] = @(
            // Exclude platform-dependant libraries
            library[@"downloads"][@"classifiers"] != nil ||
            // Exclude LWJGL libraries
            [library[@"name"] hasPrefix:@"org.lwjgl"]
        );
    }

    // Add the client as a library
    NSMutableDictionary *client = [[NSMutableDictionary alloc] init];
    client[@"downloads"] = [[NSMutableDictionary alloc] init];
    client[@"downloads"][@"artifact"] = json[@"downloads"][@"client"];
    client[@"downloads"][@"artifact"][@"path"] = [NSString stringWithFormat:@"../versions/%@/%@.jar", json[@"id"], json[@"id"]];
    client[@"name"] = [NSString stringWithFormat:@"%@.jar", json[@"id"]];
    [json[@"libraries"] addObject:client];
}

+ (BOOL)downloadClientLibraries:(NSArray *)libraries progress:(NSProgress *)mainProgress callback:(void (^)(NSString *stage, NSProgress *progress))callback {
    callback(@"Begin: download libraries", nil);

    __block BOOL cancel = NO;

    dispatch_group_t group = dispatch_group_create();

    for (NSDictionary *library in libraries) {
        if (cancel) {
            NSLog(@"[MCDL] Task download libraries is cancelled");
            return NO;
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        NSString *name = library[@"name"];

        NSMutableDictionary *artifact = library[@"downloads"][@"artifact"];
        if (artifact == nil && [name containsString:@":"]) {
            NSLog(@"[MCDL] Unknown artifact object for %@, attempting to generate one", name);
            artifact = [[NSMutableDictionary alloc] init];
            NSString *prefix = library[@"url"] == nil ? @"https://libraries.minecraft.net/" : [library[@"url"] stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
            NSArray *libParts = [name componentsSeparatedByString:@":"];
            artifact[@"path"] = [NSString stringWithFormat:@"%1$@/%2$@/%3$@/%2$@-%3$@.jar", [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"], libParts[1], libParts[2]];
            artifact[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifact[@"path"]];
            artifact[@"sha1"] = library[@"checksums"][0];
        }

        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), artifact[@"path"]];
        NSString *sha1 = artifact[@"sha1"];
        NSString *url = artifact[@"url"];
        if ([library[@"skip"] boolValue]) {
            callback([NSString stringWithFormat:@"Skipped library %@", name], nil);
            ++mainProgress.completedUnitCount;
            continue;
        } else if ([self checkSHA:sha1 forFile:path altName:nil]) { 
            ++mainProgress.completedUnitCount;
            continue;
        }

        if (![self checkAccessWithDialog:YES]) {
            callback(nil, nil);
            cancel = YES;
            continue;
        }

        dispatch_group_enter(group);
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        callback([NSString stringWithFormat:@"Downloading library %@", name], nil); 
        NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
        NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull progress){
            callback([NSString stringWithFormat:@"Downloading library %@", name], progress);
        } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            return [NSURL fileURLWithPath:path];
        } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
            if (error != nil) {
                cancel = YES;
                NSString *errorStr = [NSString stringWithFormat:@"Failed to download %@: %@", url, error.localizedDescription];
                NSLog(@"[MCDL] Error: %@", errorStr);
                showDialog(viewController, @"Error", errorStr);
                callback(nil, nil);
            } else if (![self checkSHA:sha1 forFile:path altName:nil]) {
                // Abort when a downloaded file's SHA mismatches
                cancel = YES;
                showDialog(viewController, @"Error", [NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]);
                callback(nil, nil);
            }
            dispatch_group_leave(group);
            ++mainProgress.completedUnitCount;
        }];
        callback([NSString stringWithFormat:@"Downloading library %@", name], [manager downloadProgressForTask:downloadTask]);
        [downloadTask resume];
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    callback(@"Finished: download libraries", nil);
    return !cancel;
}

+ (BOOL)downloadClientAssets:(NSDictionary *)assets progress:(NSProgress *)mainProgress callback:(void (^)(NSString *stage, NSProgress *progress))callback {
    callback(@"Begin: download assets", nil);

    dispatch_group_t group = dispatch_group_create();
    int downloadIndex = -1;
    __block int jobsAvailable = 20;
    for (NSString *name in assets[@"objects"]) {
        if (jobsAvailable < 0) {
            break;
        } else if (jobsAvailable == 0) {
            dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        }

        /* Special case for 1.19+
         * Since 1.19-pre1, setting the window icon on macOS goes through ObjC.
         * However, if an IOException occurrs, it won't try to set.
         * We skip downloading the icon file to trigger this. */
        if ([name isEqualToString:@"icons/minecraft.icns"]) continue;

        --jobsAvailable;
        dispatch_group_enter(group);
        NSString *hash = assets[@"objects"][name][@"hash"];
        NSString *pathname = [NSString stringWithFormat:@"%@/%@", [hash substringToIndex:2], hash];
        NSString *path;
        if ([assets[@"map_to_resources"] boolValue]) {
            path = [NSString stringWithFormat:@"%s/resources/%@", getenv("POJAV_GAME_DIR"), name];
        } else {
            path = [NSString stringWithFormat:@"%s/assets/objects/%@", getenv("POJAV_GAME_DIR"), pathname];
        }
        if ([self checkSHA:hash forFile:path altName:name]) { 
            ++mainProgress.completedUnitCount;
            ++jobsAvailable;
            dispatch_group_leave(group);
            usleep(1000);
            continue;
        }

        if (![self checkAccessWithDialog:NO]) {
            dispatch_group_leave(group);
            break;
        }

        NSError *err;
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&err];
        NSLog(@"path %@ err %@", path, err);
        callback([NSString stringWithFormat:@"Downloading %@", name], nil);
        NSString *url = [NSString stringWithFormat:@"https://resources.download.minecraft.net/%@", pathname];
        NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
        NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:^(NSProgress * _Nonnull progress){
            callback([NSString stringWithFormat:@"Downloading %@", name], progress);
        } destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
            return [NSURL fileURLWithPath:path];
        } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
            if (error != nil) {
                if (jobsAvailable < 0) {
                    dispatch_group_leave(group);
                    return;
                }
                jobsAvailable = -3;
                NSString *errorStr = [NSString stringWithFormat:@"Failed to download %@: %@", url, error.localizedDescription];
                NSLog(@"[MCDL] Error: %@", errorStr);
                showDialog(viewController, @"Error", errorStr);
                callback(nil, nil);
            } else if (![self checkSHA:hash forFile:path altName:name]) {
                // Abort when a downloaded file's SHA mismatches
                if (jobsAvailable < 0) {
                    dispatch_group_leave(group);
                    return;
                }
                jobsAvailable = -2;
                showDialog(viewController, @"Error", [NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]);
                callback(nil, nil);
            }
            ++jobsAvailable;
            ++mainProgress.completedUnitCount;
            dispatch_group_leave(group);
        }];
        callback([NSString stringWithFormat:@"Downloading %@", name], [manager downloadProgressForTask:downloadTask]);
        [downloadTask resume];
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    callback(@"Finished: download assets", nil);
    return jobsAvailable != -1;
}

+ (void)start:(NSObject *)version callback:(MDCallback)callback {
    manager = [[AFURLSessionManager alloc] init];
    NSProgress *mainProgress = [NSProgress progressWithTotalUnitCount:0];
    [self downloadClientJson:version progress:mainProgress callback:callback success:^(NSMutableDictionary *json) {
        [self tweakVersionJson:json];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL success;

            mainProgress.totalUnitCount = [json[@"libraries"] count] + [json[@"assetIndexObj"][@"objects"] count];
            id wrappedCallback = ^(NSString *s, NSProgress *p) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    callback(s, mainProgress, p);
                });
            };

            success = [self downloadClientLibraries:json[@"libraries"] progress:mainProgress callback:wrappedCallback];
            if (!success) return;

            success = [self downloadClientAssets:json[@"assetIndexObj"] progress:mainProgress callback:wrappedCallback];
            if (!success) return;

            isUseStackQueueCall = json[@"arguments"] != nil;

            dispatch_async(dispatch_get_main_queue(), ^{
                callback(nil, mainProgress, nil);
            });
        });
    }];
}

@end
