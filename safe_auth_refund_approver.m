#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

static NSString *const kBundle = @"com.safecoin.app";
static NSString *const kTitle = @"汇信 - 总后台 - 金融卡四方退款";
static NSString *const kType = @"金融卡四方退款(44)";

static BOOL isSafeAuth(NSRunningApplication *candidate) {
    return [[candidate bundleIdentifier] isEqualToString:kBundle] ||
           [[candidate localizedName] isEqualToString:@"Safe Auth"];
}

static id attribute(AXUIElementRef element, CFStringRef name) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static NSString *label(AXUIElementRef element) {
    for (NSString *key in @[(__bridge NSString *)kAXDescriptionAttribute,
                            (__bridge NSString *)kAXTitleAttribute,
                            (__bridge NSString *)kAXValueAttribute]) {
        id value = attribute(element, (__bridge CFStringRef)key);
        if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    }
    return @"";
}

static void collect(AXUIElementRef element, NSMutableArray *result, NSUInteger depth) {
    if (depth > 25) return;
    [result addObject:(__bridge id)element];
    NSArray *children = attribute(element, kAXChildrenAttribute);
    for (id child in children) collect((__bridge AXUIElementRef)child, result, depth + 1);
}

static NSArray *snapshot(AXUIElementRef window) {
    NSMutableArray *result = [NSMutableArray array];
    collect(window, result, 0);
    return result;
}

static id elementNamed(NSArray *elements, NSString *name) {
    for (id element in elements) {
        if ([label((__bridge AXUIElementRef)element) isEqualToString:name]) return element;
    }
    return nil;
}

static BOOL match(NSString *string, NSString *pattern) {
    return [string rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

static NSString *taskID(NSString *row) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"任务ID\\s*([0-9]+)" options:0 error:nil];
    NSTextCheckingResult *found = [regex firstMatchInString:row options:0 range:NSMakeRange(0, row.length)];
    return found ? [row substringWithRange:[found rangeAtIndex:1]] : nil;
}

static NSArray<NSDictionary *> *visibleTasks(NSArray *elements, NSSet *processed) {
    NSMutableArray *tasks = [NSMutableArray array];
    for (id element in elements) {
        NSString *row = label((__bridge AXUIElementRef)element);
        if (![row containsString:kTitle]) continue;
        NSString *identifier = taskID(row);
        if (identifier && ![processed containsObject:identifier]) {
            [tasks addObject:@{@"id": identifier, @"element": element}];
        }
    }
    return tasks;
}

static CGPoint centerOf(AXUIElementRef element) {
    id position = attribute(element, kAXPositionAttribute);
    id size = attribute(element, kAXSizeAttribute);
    CGPoint origin = CGPointZero;
    CGSize dimensions = CGSizeZero;
    if (position && CFGetTypeID((__bridge CFTypeRef)position) == AXValueGetTypeID()) {
        AXValueGetValue((__bridge AXValueRef)position, kAXValueCGPointType, &origin);
    }
    if (size && CFGetTypeID((__bridge CFTypeRef)size) == AXValueGetTypeID()) {
        AXValueGetValue((__bridge AXValueRef)size, kAXValueCGSizeType, &dimensions);
    }
    return CGPointMake(origin.x + dimensions.width / 2, origin.y + dimensions.height / 2);
}

static BOOL click(AXUIElementRef element, NSRunningApplication *app) {
    [app activateWithOptions:0];
    usleep(100000);
    if (AXUIElementPerformAction(element, kAXPressAction) == kAXErrorSuccess) return YES;
    CGPoint point = centerOf(element);
    if (point.x <= 0 || point.y <= 0) return NO;
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
    if (!down || !up) {
        if (down) CFRelease(down);
        if (up) CFRelease(up);
        return NO;
    }
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    return YES;
}

static NSArray *waitFor(AXUIElementRef window, NSString *name, NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        NSArray *elements = snapshot(window);
        if (elementNamed(elements, name)) return elements;
        usleep(200000);
    } while ([deadline timeIntervalSinceNow] > 0);
    return nil;
}

static BOOL waitForApprovalResult(AXUIElementRef window, NSString *identifier, NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    NSInteger absentObservations = 0;
    do {
        NSArray *elements = snapshot(window);
        BOOL onList = elementNamed(elements, @"当前任务") &&
                      !elementNamed(elements, kType) &&
                      !elementNamed(elements, @"是否同意");
        BOOL taskPresent = NO;
        if (onList) {
            for (NSDictionary *row in visibleTasks(elements, [NSSet set])) {
                if ([row[@"id"] isEqualToString:identifier]) {
                    taskPresent = YES;
                    break;
                }
            }
        }
        absentObservations = onList && !taskPresent ? absentObservations + 1 : 0;
        if (absentObservations >= 3) return YES;
        usleep(300000);
    } while ([deadline timeIntervalSinceNow] > 0);
    return NO;
}

static NSArray<NSString *> *refundAmounts(NSArray *details, NSString *identifier) {
    if (!elementNamed(details, kType) || !elementNamed(details, identifier)) return nil;
    NSMutableArray<NSString *> *money = [NSMutableArray array];
    BOOL hasOrderNumber = NO;
    for (id element in details) {
        NSString *value = label((__bridge AXUIElementRef)element);
        if (match(value, @"^[0-9,]+\\.[0-9]{2} [A-Z]{3,5}$")) [money addObject:value];
        if (match(value, @"^[0-9]{12,}$") && ![value isEqualToString:identifier]) hasOrderNumber = YES;
    }
    if (!hasOrderNumber || money.count < 3) return nil;
    NSString *merchant = money[money.count - 2];
    NSString *manual = money[money.count - 1];
    return @[merchant, manual];
}

static void writeLog(NSURL *url, NSString *identifier, NSString *outcome, NSString *amount, BOOL requireMatch) {
    [[NSFileManager defaultManager] createDirectoryAtURL:[url URLByDeletingLastPathComponent]
                           withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *entry = @{
        @"time": [[NSDate date] descriptionWithLocale:nil],
        @"task_id": identifier,
        @"outcome": outcome,
        @"refund_amount": amount ?: @"",
        @"amount_check": requireMatch ? @"required" : @"bypassed"
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:NSJSONWritingSortedKeys error:nil];
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        [[NSFileManager defaultManager] createFileAtPath:url.path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:nil];
    if (!handle) @throw [NSException exceptionWithName:@"LogError" reason:@"Cannot open audit log" userInfo:nil];
    [handle seekToEndOfFile];
    [handle writeData:line];
    [handle closeFile];
}

static NSMutableSet *processedIDs(NSURL *url) {
    NSMutableSet *result = [NSMutableSet set];
    NSString *log = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [log componentsSeparatedByString:@"\n"]) {
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) continue;
        NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([entry isKindOfClass:[NSDictionary class]] &&
            [@[@"attempted", @"approved"] containsObject:entry[@"outcome"]] && entry[@"task_id"]) {
            [result addObject:entry[@"task_id"]];
        }
    }
    return result;
}

static void fail(NSString *message) {
    fprintf(stderr, "Stopped: %s\n", message.UTF8String);
    exit(1);
}

static BOOL askRequireMatch(void) {
    while (YES) {
        fputs("审批前要求两笔退款金额一致吗？Y=要求一致，N=跳过相等比较 [Y/N]: ", stdout);
        fflush(stdout);
        char *line = NULL;
        size_t capacity = 0;
        ssize_t length = getline(&line, &capacity, stdin);
        if (length < 0) {
            free(line);
            fail(@"No amount-check choice received; no approval started");
        }
        NSString *answer = [[NSString alloc] initWithBytes:line length:(NSUInteger)length encoding:NSUTF8StringEncoding];
        free(line);
        answer = [[answer stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
        if ([answer isEqualToString:@"Y"]) return YES;
        if ([answer isEqualToString:@"N"]) return NO;
        puts("请输入 Y 或 N；尚未开始审批。");
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL approve = NO, watch = NO, inspectFirst = NO, diagnose = NO;
        NSInteger maxApprovals = NSIntegerMax;
        for (int i = 1; i < argc; i++) {
            NSString *argument = [NSString stringWithUTF8String:argv[i]];
            if ([argument isEqualToString:@"--approve"]) approve = YES;
            else if ([argument isEqualToString:@"--watch"]) watch = YES;
            else if ([argument isEqualToString:@"--inspect-first"]) inspectFirst = YES;
            else if ([argument isEqualToString:@"--diagnose"]) diagnose = YES;
            else if ([argument isEqualToString:@"--max"] && i + 1 < argc) maxApprovals = MAX(1, atoi(argv[++i]));
            else fail([@"Unknown argument: " stringByAppendingString:argument]);
        }
        if (diagnose && approve) fail(@"--diagnose cannot be combined with --approve");
        BOOL requireMatch = YES;
        if (approve) {
            requireMatch = askRequireMatch();
            printf("金额一致校验：%s\n", requireMatch ? "开启" : "关闭");
        }
        if (!AXIsProcessTrusted()) fail(@"Grant Accessibility access to the terminal, then retry");

        NSRunningApplication *app = nil;
        AXUIElementRef window = NULL;
        NSInteger candidates = 0;
        for (NSInteger attempt = 0; attempt < (diagnose ? 1 : 50) && !window; attempt++) {
            candidates = 0;
            for (NSRunningApplication *candidate in [[NSWorkspace sharedWorkspace] runningApplications]) {
                if (!isSafeAuth(candidate)) continue;
                candidates++;
                AXUIElementRef root = AXUIElementCreateApplication(candidate.processIdentifier);
                CFTypeRef rawWindows = NULL;
                AXError windowError = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute, &rawWindows);
                NSArray *windows = CFBridgingRelease(rawWindows);
                if (diagnose) {
                    printf("Safe Auth candidate: pid=%d name=%s bundle=%s AXWindows=%d count=%lu\n",
                           candidate.processIdentifier,
                           (candidate.localizedName ?: @"").UTF8String,
                           (candidate.bundleIdentifier ?: @"").UTF8String,
                           windowError, (unsigned long)windows.count);
                }
                for (id possibleWindow in windows) {
                    NSArray *elements = snapshot((__bridge AXUIElementRef)possibleWindow);
                    BOOL currentTasks = elementNamed(elements, @"当前任务") != nil;
                    if (diagnose) {
                        printf("  window: title=%s elements=%lu current_tasks=%s\n",
                               [label((__bridge AXUIElementRef)possibleWindow) UTF8String],
                               (unsigned long)elements.count, currentTasks ? "yes" : "no");
                    }
                    if (currentTasks) {
                        app = candidate;
                        window = CFRetain((__bridge AXUIElementRef)possibleWindow);
                        break;
                    }
                }
                CFRelease(root);
                if (window) break;
            }
            if (!window && !diagnose) usleep(200000);
        }
        if (!window) {
            fprintf(stderr, "Safe Auth candidates found: %ld\n", (long)candidates);
            fail(@"Could not read Safe Auth Current Tasks window; run --diagnose");
        }
        if (diagnose) {
            puts("Current Tasks window detected. No task was opened or approved.");
            CFRelease(window);
            return 0;
        }

        NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
        NSURL *logURL = [NSURL fileURLWithPath:[cwd stringByAppendingPathComponent:@"outputs/safe_auth_refund_approvals.jsonl"]];
        NSMutableSet *processed = processedIDs(logURL);
        NSInteger count = 0;
        while (count < maxApprovals) {
            NSArray *elements = snapshot(window);
            if (!elementNamed(elements, @"当前任务")) fail(@"Current Tasks page changed");
            NSArray<NSDictionary *> *tasks = visibleTasks(elements, processed);
            if (!approve) {
                for (NSDictionary *task in tasks) printf("Pending four-party refund: %s\n", [task[@"id"] UTF8String]);
                if (inspectFirst && tasks.count) {
                    NSDictionary *first = tasks[0];
                    NSString *identifier = first[@"id"];
                    if (!click((__bridge AXUIElementRef)first[@"element"], app)) fail(@"Cannot open first task");
                    NSArray *details = waitFor(window, kType, 5);
                    NSArray<NSString *> *amounts = details ? refundAmounts(details, identifier) : nil;
                    id back = elementNamed(details, @"Back");
                    if (!back || !click((__bridge AXUIElementRef)back, app) || !waitFor(window, @"当前任务", 5)) {
                        fail(@"Could not return to task list");
                    }
                    if (!amounts) fail([@"Detail validation failed: " stringByAppendingString:identifier]);
                    printf("Detail verified %s: merchant %s; manual %s\n",
                           identifier.UTF8String, amounts[0].UTF8String, amounts[1].UTF8String);
                }
                break;
            }
            if (tasks.count == 0) {
                if (!watch) break;
                sleep(10);
                continue;
            }
            NSDictionary *task = tasks[0];
            NSString *identifier = task[@"id"];
            if (!click((__bridge AXUIElementRef)task[@"element"], app)) fail(@"Cannot open refund task");
            NSArray *details = waitFor(window, kType, 5);
            NSArray<NSString *> *amounts = details ? refundAmounts(details, identifier) : nil;
            if (!amounts) fail([@"Task ID, order number, or refund amount check failed: " stringByAppendingString:identifier]);
            NSString *amountSummary = [NSString stringWithFormat:@"merchant %@; manual %@", amounts[0], amounts[1]];
            if (requireMatch && ![amounts[0] isEqualToString:amounts[1]]) {
                writeLog(logURL, identifier, @"skipped_mismatch", amountSummary, requireMatch);
                [processed addObject:identifier];
                id back = elementNamed(details, @"Back");
                if (!back || !click((__bridge AXUIElementRef)back, app) || !waitFor(window, @"当前任务", 5)) {
                    fail(@"Could not return to task list after skipping mismatch");
                }
                printf("Skipped mismatch %s: %s\n", identifier.UTF8String, amountSummary.UTF8String);
                continue;
            }
            id pass = elementNamed(details, @"通过");
            if (!pass || !click((__bridge AXUIElementRef)pass, app)) fail(@"Cannot click Pass");
            NSArray *confirmation = waitFor(window, @"是否同意", 5);
            id agree = confirmation ? elementNamed(confirmation, @"同意") : nil;
            if (!agree) fail(@"Confirmation dialog missing");
            writeLog(logURL, identifier, @"attempted", amountSummary, requireMatch);
            [processed addObject:identifier];
            if (!click((__bridge AXUIElementRef)agree, app)) fail(@"Cannot click Agree; inspect task before retrying");
            if (!waitForApprovalResult(window, identifier, 15)) {
                fail(@"Approval outcome unclear after 15 seconds; inspect Safe Auth before retrying");
            }
            writeLog(logURL, identifier, @"approved", amountSummary, requireMatch);
            printf("Approved %s: %s\n", identifier.UTF8String, amountSummary.UTF8String);
            count++;
        }
        printf("Finished; approved %ld task(s).\n", (long)count);
        CFRelease(window);
    }
    return 0;
}
