#import "OatsObjC.h"

NSError *OatsCatchException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:NSGenericException code:0 userInfo:@{
            NSLocalizedDescriptionKey: exception.reason ?: exception.name,
            @"name": exception.name,
        }];
    }
}
