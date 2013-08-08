//
//  FLCodeInjector.m
//  FuelTracker
//
//  Created by Lombardo on 07/08/13.
//  Copyright (c) 2013 Lombardo. All rights reserved.
//

#import "FLCodeInjector.h"
#import <objc/runtime.h>
#import <objc/message.h>

// ignore the error on the performSelector from string
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

@interface FLCodeInjector ()

/**
 The main class associated with the instance
 */
@property (strong, nonatomic) Class mainClass;

/**
 A dictionary of blocks to be executed BEFORE the original method call
 */
@property (strong, nonatomic) NSMutableDictionary *dictionaryOfBlocksBefore;

/**
 A dictionary of blocks to be executed AFTER the original method call
 */
@property (strong, nonatomic) NSMutableDictionary *dictionaryOfBlocksAfter;

/**
 Expose these two methods to permit the functions to execute the blocks
 */
- (void)executeBlockBeforeSelector:(SEL)method;
- (void)executeBlockAfterSelector:(SEL)method;

@end

/**
 A static dictionary of classes, used to maintain a reference to all created instances
 */
static NSMutableDictionary *dictionaryOfClasses = nil;


@implementation FLCodeInjector

/**
 This method returns one different instance for each kind of class passed (semi-singleton)
 */
+ (FLCodeInjector *) injectorForClass:(Class)thisClass
{
    // create the dictionary if not exists
    // use a dispatch to avoid problems in case of concurrent calls
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!dictionaryOfClasses)
            dictionaryOfClasses = [[NSMutableDictionary alloc]init];
    });
    
    if (![dictionaryOfClasses objectForKey:NSStringFromClass(thisClass)])
    {
        id thisInjector = [[self alloc]initWithClass:thisClass];
        [dictionaryOfClasses setObject:thisInjector forKey:NSStringFromClass(thisClass)];
        return thisInjector;
    }
    else
        return [dictionaryOfClasses objectForKey:NSStringFromClass(thisClass)];
}

/**
 Private intializer
 */
- (id)initWithClass:(Class)thisClass
{
    self = [self initPrivate];
    if (self) {
        _mainClass = thisClass;
        _dictionaryOfBlocksBefore = [NSMutableDictionary dictionary];
        _dictionaryOfBlocksAfter = [NSMutableDictionary dictionary];
    }
    return self;
}

/**
 Private intializer
 */
- (id)initPrivate
{
    if (self = [super init]) {
        
    }
    return self;
}

/**
 Disabled
 */
- (id)init
{
    [NSException exceptionWithName:@"InvalidOperation" reason:@"Cannot invoke init. Use injectorForClass: method" userInfo:nil];
    return nil;
}


#pragma mark - Public methods

- (void)injectCodeBeforeSelector:(SEL)method code:(void (^)())completionBlock
{
    [self injectCodeBefore:YES selector:method code:completionBlock];
}

- (void)injectCodeAfterSelector:(SEL)method code:(void (^)())completionBlock
{
    [self injectCodeBefore:NO selector:method code:completionBlock];
}

- (void)injectCodeBefore:(BOOL)before selector:(SEL)method code:(void (^)())completionBlock
{
    // Initialize local variable
    BOOL shouldSwizzle = YES;
    
    // Get a string for the original selector and the swizzled one
    NSString *selectorString = NSStringFromSelector(method);
    NSString *swizzleSelectorString = [NSString stringWithFormat:@"SWZ%@", selectorString];
    

    // Enable swizzling only if the selector has not yet been added to the dictionary
    if ([self.dictionaryOfBlocksBefore objectForKey:selectorString] || [self.dictionaryOfBlocksAfter objectForKey:selectorString])
        shouldSwizzle = NO;
    
    // Add the code block to the before or after dictionary
    if (before)
        [self.dictionaryOfBlocksBefore setObject:completionBlock forKey:selectorString];
    else
        [self.dictionaryOfBlocksAfter setObject:completionBlock forKey:selectorString];

    
    
    // Now we add the new swizzled selector to the original class
    // Fist: obtain the Method from Class+Selector
    Method origMethod = class_getInstanceMethod(self.mainClass, method);
    
    // Get the encoding of the method. The encoding is a char like this: v@:@@@ --> this means:
    // v -> void return type
    // @ -> first parameter is an object (first hidden parameter of a method, self)
    // : -> second parameter is a selector (second hidden parameter of a method, cmd)
    // @@@ -> other 3 object parameters
    // other return type strings here:
    // https://developer.apple.com/library/mac/#documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtTypeEncodings.html
    const char *encoding = method_getTypeEncoding(origMethod);
    
    // Add the selector
    [self addSelector:NSSelectorFromString(swizzleSelectorString) toClass:self.mainClass originalSelector:method methodTypeEncoding:encoding];
    
    // Swizzle only if needed
    if (shouldSwizzle)
        SwizzleMe(self.mainClass, method, NSSelectorFromString(swizzleSelectorString));
}

/**
 Executes the code block checking if exists in the "before array"
 */
- (void)executeBlockBeforeSelector:(SEL)method
{
    void(^aBlock)() = [self.dictionaryOfBlocksBefore objectForKey:NSStringFromSelector(method)];
    
    if (aBlock)
        aBlock();
}

/**
 Executes the code block checking if exists in the "before array"
 */
- (void)executeBlockAfterSelector:(SEL)method
{
    void(^aBlock)() = [self.dictionaryOfBlocksAfter objectForKey:NSStringFromSelector(method)];
    
    if (aBlock)
        aBlock();
}

#pragma mark - Private methods


-(void)addSelector:(SEL)selector toClass:(Class)aClass originalSelector:(SEL)originalSel methodTypeEncoding:(const char *)encoding
{
    /**
     Discussion: it's not possible to create a function with a dynamic return type.
     To be more clear, you can't create a function like this:
     
     anytype functionName()
     { 
        ... some code
        return value; <-- where value can be id, int, long, or anything else
     }
     
     This is due to limitations of the runtime, look at these two SO posts for clarifications:
     
     1: http://stackoverflow.com/questions/18126999/a-function-that-can-return-an-object-or-a-primitive-type-is-it-possible
     2: http://stackoverflow.com/questions/18115237/swizzling-a-method-with-variable-arguments-and-forward-the-message-bad-access
     
     So, we need to implement a dedicated function for each return type.
     Then, we add this function and after enable the swizzle.
     
     Example:
     If we want to inject code in -(UIView *)inputView; method of UIView, the have to swizzle it with a new method that has a return type
     of kind "id". So, the implementation is the one contained in the "objectGenericFunction" method.
     If we want to inject code in -(int)someMethod, the swizzled function is intGenericFunction

     */
    
    // First of all, we need the method signature. We can create it because we have the encoding string
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding];
    
    // Then, we can obtain the return type (in alternative, we could have extract the first char of the encoding string)
    const char *type = [signature methodReturnType];
    
    // Declare implementation
    IMP implementation;
    
    
    // Set the correct implementation basing on the return type
    if (strcmp(@encode(id), type) == 0) {
        // the argument is an object
        implementation = objectGenericFunction;
    }
    else if (strcmp(@encode(int), type) == 0)
    {
        // the argument is an int
        implementation = (IMP)intGenericFunction;
    }
    else if (strcmp(@encode(long), type) == 0)
    {
        // the argument is a long
        implementation = (IMP)longGenericFunction;
    }
    else if (strcmp(@encode(double), type) == 0)
    {
        // the argument is double
        implementation = (IMP)doubleGenericFunction;
    }
    else if (strcmp(@encode(float), type) == 0)
    {
        // the argument is float
        implementation = (IMP)floatGenericFunction;
    }
    else
    {
        // the argument is char or others
        implementation = (IMP)intGenericFunction;
    }
    
    // add the method to the class
    class_addMethod(aClass,
                    selector,
                    implementation, encoding);
}

/**
 This function simply swizzle the method implementations
 */
void SwizzleMe(Class c, SEL orig, SEL new)
{
    Method origMethod = class_getInstanceMethod(c, orig);
    Method newMethod = class_getInstanceMethod(c, new);
    if(class_addMethod(c, orig, method_getImplementation(newMethod), method_getTypeEncoding(newMethod)))
        class_replaceMethod(c, new, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    else
        method_exchangeImplementations(origMethod, newMethod);
}


#pragma mark - entry point function for different types

/**
 All the following functions are specific to different types, but the code is identical
 You will find comment only in the first (float) and in the object (id)
 */

float floatGenericFunction(id self, SEL cmd, ...) {
    
    // Obtain a reference to the code injector for this class
    FLCodeInjector *injector = [FLCodeInjector injectorForClass:[self class]];
    
    // This call executes the code block to inject
    [injector executeBlockBeforeSelector:cmd];
    

    // Pass self, cmd and the arg list to the main function: getReturnValue
    // This function forward the invocation with all arguments, then
    // returns a generic pointer: it could be a pointer to an integer, to an object, to anything
    // The important thing is that it's ALWAYS a pointer, but this function must return
    // a pointer only in the object case. In other case, we need to access to the pointed value
    va_list arguments;
    va_start ( arguments, cmd );
    void * returnValue = getReturnValue(self, cmd, arguments);
    va_end(arguments);
    
    // Execute the after block
    [injector executeBlockAfterSelector:cmd];
    
    // Find the pointed float value and return it
    float returnedFloat = *(float *)returnValue;
    return returnedFloat;
}

int intGenericFunction(id self, SEL cmd, ...) {
    
    FLCodeInjector *injector = [FLCodeInjector injectorForClass:[self class]];
    [injector executeBlockBeforeSelector:cmd];
    
    va_list arguments;
    va_start ( arguments, cmd );
    void * returnValue = getReturnValue(self, cmd, arguments);
    va_end(arguments);
    
    [injector executeBlockAfterSelector:cmd];
    
    int returnedInt = *(int *)returnValue;
    return returnedInt;
}

double doubleGenericFunction(id self, SEL cmd, ...) {
    
    FLCodeInjector *injector = [FLCodeInjector injectorForClass:[self class]];
    [injector executeBlockBeforeSelector:cmd];
    
    va_list arguments;
    va_start ( arguments, cmd );
    void * returnValue = getReturnValue(self, cmd, arguments);
    va_end(arguments);
    
    [injector executeBlockAfterSelector:cmd];
    
    double returnedDouble = *(double *)returnValue;
    return returnedDouble;
}

long longGenericFunction(id self, SEL cmd, ...) {
    
    FLCodeInjector *injector = [FLCodeInjector injectorForClass:[self class]];
    [injector executeBlockBeforeSelector:cmd];
    
    va_list arguments;
    va_start ( arguments, cmd );
    void * returnValue = getReturnValue(self, cmd, arguments);
    va_end(arguments);
    
    [injector executeBlockAfterSelector:cmd];
    
    double returnedLong = *(long *)returnValue;
    return returnedLong;
}

id objectGenericFunction(id self, SEL cmd, ...) {
    
    FLCodeInjector *injector = [FLCodeInjector injectorForClass:[self class]];
    [injector executeBlockBeforeSelector:cmd];
    
    va_list arguments;
    va_start ( arguments, cmd );
    void * returnValue = getReturnValue(self, cmd, arguments);
    va_end(arguments);
    
    [injector executeBlockAfterSelector:cmd];
    
    // Since the returnedValue is a pointer itself, we need only to bridge cast it
    id returnedObject = (__bridge id)returnValue;
    return returnedObject;
}

/**
 This function forward the original invocation, then returns a generic pointer
 to the return value (that can be of any type)
 */
void * getReturnValue(id self, SEL cmd, va_list argumentsToCopy) {
    
    // Copy the variable argument list into another va_list
    // Why? read this: http://julipedia.meroh.net/2011/09/using-vacopy-to-safely-pass-ap.html
    va_list arguments;
    va_copy(arguments, argumentsToCopy);
    
    // Obtain the method signature and the relative number of arguments of the selector
    NSMethodSignature *signature = [self methodSignatureForSelector:cmd];
    int numberOfArguments = [signature numberOfArguments];
    
    // Prepare the invocation with variable number of arguments
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    
    // Set the target of the invocation
    [invocation setTarget:self];
    
    // Set the selector. Since the swizzling is enabled, the right selector has SWZ prefix
    NSString *swizzleSelector = [NSString stringWithFormat:@"SWZ%@", NSStringFromSelector(cmd)];
    SEL selectorToExecute = NSSelectorFromString(swizzleSelector);
    [invocation setSelector:selectorToExecute];
    
    // Get the return value size for later use
    NSUInteger sizeOfReturnValue = [signature methodReturnLength];

    

    // Now we start a loop through all arguments, to add them to the invocation
    // We use numberOfArguments-2 because of the first two arguments (self and cmd) are the
    // hidden arguments, and are not present in the va_list
    for ( int x = 0; x < numberOfArguments - 2; x++ )
    {
        
        // Set the index for cleaner code
        int idx = x+2;
        
        // The type of the argument at this index
        const char *type = [signature getArgumentTypeAtIndex:idx];
        
        // An if-elseif to find the correct argument type
        // Extendend comments only in the first two cases
        if (strcmp(@encode(id), type) == 0) {
            
            // The argument is an object
            // We obtain a pointer to the argument through va_arg, the second parameter is the lenght of the argument
            // va_arg return the pointer and then move it's pointer to the next item
            id argument = va_arg(arguments, id);
            
            // Set the argument. The method wants a pointer to the pointer
            [invocation setArgument:&argument atIndex:idx];
        }
        else if (strcmp(@encode(int), type) == 0)
        {
            // the argument is an int
            int anInt = va_arg(arguments, int);
            [invocation setArgument:&anInt atIndex:idx];
        }
        else if (strcmp(@encode(long), type) == 0)
        {
            // the argument is a long
            long aLong = va_arg(arguments, long);
            [invocation setArgument:&aLong atIndex:idx];
        }
        else if ((strcmp(@encode(double), type) == 0) || (strcmp(@encode(float), type) == 0))
        {
            // the argument is float or double
            double aDouble = va_arg(arguments, double);
            [invocation setArgument:&aDouble atIndex:idx];
        }
        else
        {
            // the argument is char or others
            int anInt = va_arg(arguments, int);
            [invocation setArgument:&anInt atIndex:idx];
        }
    }
    
    // Invoke the invocation
    [invocation invoke];
    
    // End the variable arguments
    va_end ( arguments );
    
    // Now we get the expected method return type...
    const char *returnType = [signature methodReturnType];
    
    // ... and prepare a generic void pointer to store the pointer to the final value
    void *finalValue = nil;
    
    
    // Again, we must use different code depending on the return type
    if (strcmp(@encode(id), returnType) == 0) {
        // the return value is an object
        if (sizeOfReturnValue != 0)
        {
            // Create a new pointer to object
            id anObject;
            
            // Put the return value (that is a pointer to object) at the memory address indicated: the pointer to the anObject pointer.
            [invocation getReturnValue:&anObject];
            
            // return a generic void * pointer to anObject. We are returing a pointer to a pointer:
            // finalValue points to anObject that points to the real object on the heap
            finalValue = (__bridge void *)anObject;
        }
    }
    else if (strcmp(@encode(int), returnType) == 0)
    {
        // the return value is an int
        if (sizeOfReturnValue != 0)
        {
            int anInt;
            [invocation getReturnValue:&anInt];
            
            // in this case, we are returnig a generic pointer that points to an int
            finalValue = &anInt;
        }

    }
    else if (strcmp(@encode(long), returnType) == 0)
    {
        // the return value is a long
        if (sizeOfReturnValue != 0)
        {
            long aLong;
            [invocation getReturnValue:&aLong];
            finalValue = &aLong;
        }
    }
    else if (strcmp(@encode(float), returnType) == 0)
    {
        // the return value is float
        if (sizeOfReturnValue != 0)
        {
            float aFloat;
            [invocation getReturnValue:&aFloat];
            finalValue = &aFloat;
        }
    }
    else if (strcmp(@encode(double), returnType) == 0)
    {
        // the return value is double
        if (sizeOfReturnValue != 0)
        {
            double aDouble;
            [invocation getReturnValue:&aDouble];
            finalValue = &aDouble;
        }
    }
    else
    {
        // the return value is something different
        if (sizeOfReturnValue != 0)
        {
            int anInt;
            [invocation getReturnValue:&anInt];
            finalValue = &anInt;
        }
    }
    
    
    // final value è un puntatore ad un float in questo caso
    // se scrivo *(float *)finalValue è come scrivere *finalValue (fammi vedere il valore puntato da finalValue)
    // solo che in mezzo ci aggiungo un cast
    return finalValue;
}



@end