// The offline pages' content rule list (web_apple.m OFFLINE_RULES: every http(s) and ws(s) load blocked) and a page's end at its callback URL (http://localhost/ by default):
// WebKit asks the navigation delegate about a main-frame navigation before the content blocker applies to it, so a page still ends with the list attached. web_apple.m's
// own list (read from the file given, as written there) is compiled and attached as front_web_open does; a dmweb:// page then ends four ways (location.href, a link, a form,
// location.replace), and each must reach decidePolicyForNavigationAction. A Mac with a window session: make -C dm/host/tests web-rules
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface Probe : NSObject <WKURLSchemeHandler, WKNavigationDelegate>
@property (copy) NSString *how; @property int asked, finished;
@end
@implementation Probe
- (void)webView:(WKWebView *)w startURLSchemeTask:(id<WKURLSchemeTask>)t {
    (void)w;
    NSString *page = [NSString stringWithFormat:@"<html><body><a id=a href='http://localhost/?end=link'>end</a><form id=f action='http://localhost/' method=get><input name=end value=form></form>"
                      "<script>setTimeout(function(){ %@ }, 200);</script></body></html>", self.how];
    NSData *d = [page dataUsingEncoding:NSUTF8StringEncoding];
    [t didReceiveResponse:[[NSURLResponse alloc] initWithURL:t.request.URL MIMEType:@"text/html" expectedContentLength:(NSInteger)d.length textEncodingName:@"utf-8"]];
    [t didReceiveData:d]; [t didFinish];
}
- (void)webView:(WKWebView *)w stopURLSchemeTask:(id<WKURLSchemeTask>)t { (void)w; (void)t; }
- (void)webView:(WKWebView *)w decidePolicyForNavigationAction:(WKNavigationAction *)a decisionHandler:(void (^)(WKNavigationActionPolicy))done {
    (void)w; NSString *u = a.request.URL.absoluteString;
    if ([u hasPrefix:@"http://localhost/"] && a.targetFrame.isMainFrame) { self.asked = 1; done(WKNavigationActionPolicyCancel); return; }   // web_apple.m: the page's end
    done([u hasPrefix:@"dmweb:"] ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)webView:(WKWebView *)w didFinishNavigation:(WKNavigation *)n { (void)w; (void)n; self.finished = 1; }
@end

// OFFLINE_RULES as web_apple.m writes it: the C string pieces after "OFFLINE_RULES = @", up to the ';', joined, with \" unescaped
static NSString *rules_from(NSString *path) {
    NSString *src = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSRange at = src ? [src rangeOfString:@"OFFLINE_RULES = @"] : (NSRange){NSNotFound, 0};
    if (at.location == NSNotFound) return nil;
    NSString *rest = [src substringFromIndex:NSMaxRange(at)];
    NSRange end = [rest rangeOfString:@"\";"]; if (end.location == NSNotFound) return nil;
    NSString *lit = [rest substringToIndex:end.location + 1];
    NSMutableString *out = [NSMutableString string];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\"((?:[^\"\\\\]|\\\\.)*)\"" options:0 error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:lit options:0 range:NSMakeRange(0, lit.length)])
        [out appendString:[[lit substringWithRange:[m rangeAtIndex:1]] stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""]];
    return out.length ? out : nil;
}

int main(int argc, char **argv) { @autoreleasepool {
    NSString *json = argc > 1 ? rules_from(@(argv[1])) : nil;
    if (!json) { printf("✗ web_apple.m's OFFLINE_RULES not found (give its path)\n== web rules: 1 checks, 1 failed ==\n"); return 1; }
    [NSApplication sharedApplication];
    __block WKContentRuleList *rl = nil; __block int done = 0;
    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:@"dm-offline-pages-t" encodedContentRuleList:json completionHandler:^(WKContentRuleList *l, NSError *e) { (void)e; rl = l; done = 1; }];
    for (NSDate *until = [NSDate dateWithTimeIntervalSinceNow:20]; !done && until.timeIntervalSinceNow > 0; ) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    int checks = 1, fails = !rl;
    printf("%s web_apple.m's rule list compiles\n", rl ? "✓" : "✗");
    for (NSString *how in rl ? @[@"location.href='http://localhost/?end=js';", @"document.getElementById('a').click();", @"document.getElementById('f').submit();", @"location.replace('http://localhost/');"] : @[]) {
        Probe *p = [Probe new]; p.how = how;
        WKWebViewConfiguration *c = [WKWebViewConfiguration new];
        [c setURLSchemeHandler:p forURLScheme:@"dmweb"];
        [c.userContentController addContentRuleList:rl];   // before the first load, as front_web_open's offline_rules
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 240) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        WKWebView *w = [[WKWebView alloc] initWithFrame:win.contentView.bounds configuration:c]; w.navigationDelegate = p; [win.contentView addSubview:w];
        [w loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"dmweb://doc/index.html"]]];
        for (NSDate *until = [NSDate dateWithTimeIntervalSinceNow:10]; !p.asked && until.timeIntervalSinceNow > 0; ) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        checks++; fails += !(p.finished && p.asked);
        printf("%s a page that ends with %s reaches the navigation delegate with the list attached\n", p.finished && p.asked ? "✓" : "✗", how.UTF8String);
        [w stopLoading]; w.navigationDelegate = nil;
    }
    done = 0;
    [WKContentRuleListStore.defaultStore removeContentRuleListForIdentifier:@"dm-offline-pages-t" completionHandler:^(NSError *e) { (void)e; done = 1; }];
    for (NSDate *until = [NSDate dateWithTimeIntervalSinceNow:5]; !done && until.timeIntervalSinceNow > 0; ) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    printf("== web rules: %d checks, %d failed ==\n", checks, fails);
    return fails != 0;
} }
