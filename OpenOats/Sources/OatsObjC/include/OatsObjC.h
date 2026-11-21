#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns an Objective-C exception it raised as an NSError (description: the reason; userInfo
/// "name": the exception name), or nil. Swift can't catch NSExceptions; AVFAudio raises them for bad arguments.
NSError * _Nullable OatsCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
