//
//  QSAppleScriptActions.m
//  Quicksilver
//
//  Created by Alcor on 7/30/04.
//  Copyright 2004 Blacktree. All rights reserved.
//

#import "QSAppleScriptActions.h"
#import "QSTaskController.h"
#import "QSObject_AEConversion.h"
#import "QSObject_PropertyList.h"
#import "QSObject_FileHandling.h"
#import "QSObject_StringHandling.h"
#import "QSTextProxy.h"
#import "QSTypes.h"
#import "QSExecutor.h"

#import "NSAppleScript_BLTRExtensions.h"

#import "NSAppleEventDescriptor+NDCoercion.h"

@implementation QSAppleScriptActions

- (QSAction *)scriptActionForPath:(NSString *)path {
	NSArray *handlers = [NSAppleScript validHandlersFromArray:[NSArray arrayWithObjects:@"aevtoapp", @"DAEDopnt", @"aevtodoc",@"DAEDopfl", nil] inScriptFile:path];

	NSMutableDictionary *actionDict = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                       NSStringFromClass([self class]),    kActionClass,
                                       self,    kActionProvider,
                                       path,    kActionScript,
                                       [NSNumber numberWithBool:YES],      kActionDisplaysResult,
                                       nil];
    
    // attempt to get the valid direct types from the AppleScript's 'get direct types' handler
    NSArray *validDirectTypes = [self validDirectTypesForScript:path];
    
    if ([handlers containsObject:@"aevtodoc"] || [handlers containsObject:@"DAEDopfl"]) {
        // Only set the type if the user hasn't specified any (i.e. hasn't set the 'get direct types' handler)
        if (!validDirectTypes) {
            validDirectTypes = [NSArray arrayWithObject:QSFilePathType];
        }
		[actionDict setObject:[handlers containsObject:@"DAEDopfl"] ? @"QSOpenFileWithEventPlaceholder" : @"QSOpenFileEventPlaceholder" forKey:kActionHandler];
        [actionDict setObject:[NSArray arrayWithObject:QSFilePathType] forKey:kActionIndirectTypes];
	}
	if ([handlers containsObject:@"DAEDopnt"] && ![handlers containsObject:@"DAEDopfl"]) {
        // Only set the type if the user hasn't specified any (i.e. hasn't set the 'get direct types' handler)
        if (!validDirectTypes) {
            validDirectTypes = [NSArray arrayWithObject:QSTextType];
        }
		[actionDict setObject:@"QSOpenTextEventPlaceholder" forKey:kActionHandler];
		[actionDict setObject:[NSArray arrayWithObject:QSTextType] forKey:kActionIndirectTypes];
	}
    if ([validDirectTypes count]) {
        [actionDict setObject:validDirectTypes forKey:kActionDirectTypes];
    }
    NSString *actionName = [[path lastPathComponent] stringByDeletingPathExtension];
    QSAction *action = [QSAction actionWithDictionary:actionDict identifier:[kAppleScriptActionIDPrefix stringByAppendingString:path]];
    [action setName:actionName];
	[action setObject:path forMeta:kQSObjectIconName];
	return action;
}

- (NSArray *)fileActionsFromPaths:(NSArray *)scripts {
	NSArray *paths = [scripts pathsMatchingExtensions:[NSArray arrayWithObjects:@"scpt", @"app", nil]];
    NSMutableArray *array = [NSMutableArray array]; 
	for (NSString *path in paths) {
		if (UTTypeConformsTo((CFStringRef)QSUTIOfFile(path), (CFStringRef)QSUTIForAnyTypeString(@"scpt"))) {
			[array addObject:[self scriptActionForPath:path]];
		}
	}
	return array;
}

- (NSString *)stringWithCorrectedLazyTell:(NSString *)string {
	NSArray *components = [string componentsSeparatedByString:@" "];
	if ([components count] <3 || ![[components objectAtIndex:0] isEqualToString:@"tell"] || ![[components objectAtIndex:1] isEqualToString:@"app"] || [[components objectAtIndex:2] hasPrefix:@"\""] || [[components objectAtIndex:2] hasSuffix:@"\""])
		return string;

	components = [components mutableCopy];
	[(NSMutableArray *)components replaceObjectAtIndex:2 withObject:[NSString stringWithFormat:@"\"%@\"", [components objectAtIndex:2]]];
	NSString *result = [components componentsJoinedByString:@" "];
	[components release];
	return result;
}

- (QSObject *)doAppleScriptRunTextAction:(QSObject *)dObject {
	NSDictionary *errorDict = nil;
    id returnObj = nil;
	NSAppleScript *script = [[NSAppleScript alloc] initWithSource:[self stringWithCorrectedLazyTell:[dObject objectForType:QSTextType]]];
	if([script compileAndReturnError:&errorDict]) {
		returnObj = [[script executeAndReturnError:&errorDict] stringValue];
		if (returnObj)
			returnObj = [QSObject objectWithString:returnObj];
	}
	[script release];
	return returnObj;
}

- (QSObject *)doAppleScriptRunAction:(QSObject *)dObject withArguments:(QSObject *)iObject {
    NSString *path = [dObject singleFilePath];
    if (path) {
        [self runAppleScript:[dObject singleFilePath] withArguments:iObject];
    }
	return nil;
}

- (QSObject *)doAppleScriptRunWithArgumentsAction:(QSObject *)dObject withArguments:(QSObject *)iObject {
    NSString *path = [dObject singleFilePath];
    if (path) {
        [self runAppleScript:[dObject singleFilePath] withArguments:iObject];
    }
	return nil;
}

- (QSObject *)doAppleScriptRunAction:(QSObject *)dObject {
    NSString *path = [dObject singleFilePath];
    if (path) {
        [self runAppleScript:[dObject singleFilePath] withArguments:nil];
    }
	return nil;
}

- (QSObject*)runAppleScript:(NSString *)scriptPath withArguments:(QSObject *)iObject {
	NSDictionary *errorDict = nil;
    NSAppleEventDescriptor * returnDesc = nil;

	[[QSTaskController sharedInstance] updateTask:@"Run AppleScript" status:@"Loading Script" progress:-1];
	NSAppleScript *script = [[NSAppleScript alloc] initWithContentsOfURL:[NSURL fileURLWithPath:scriptPath] error:&errorDict];
	[[QSTaskController sharedInstance] updateTask:@"Run AppleScript" status:@"Running Script" progress:-1];

	if (errorDict) {
		NSLog(@"Load Script: %@", [errorDict objectForKey:@"NSAppleScriptErrorMessage"]);
        [script release];
		return nil;
	}

	if (!iObject) {
		[script executeAndReturnError:&errorDict];
	} else {
		NSArray *files = [iObject arrayForType:QSFilePathType];

		NSAppleEventDescriptor* event;
		NSDictionary *errorInfo = nil;
		int pid = [[NSProcessInfo processInfo] processIdentifier];
		NSAppleEventDescriptor* targetAddress = [[NSAppleEventDescriptor alloc] initWithDescriptorType:typeKernelProcessID bytes:&pid length:sizeof(pid)];
		if (files) {
			event = [[NSAppleEventDescriptor alloc] initWithEventClass:kCoreEventClass eventID:kAEOpenDocuments targetDescriptor:targetAddress returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
			[event setParamDescriptor:[NSAppleEventDescriptor aliasListDescriptorWithArray:files] forKeyword:keyDirectObject];
		} else if([iObject AEDescriptor]) {
            event = [[NSAppleEventDescriptor alloc] initWithEventClass:kCoreEventClass eventID:kAEOpenDocuments targetDescriptor:targetAddress returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
			[event setParamDescriptor:[iObject AEDescriptor] forKeyword:keyDirectObject];
        } else {
			event = [[NSAppleEventDescriptor alloc] initWithEventClass:kQSScriptSuite eventID:kQSOpenTextScriptCommand targetDescriptor:targetAddress returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
			[event setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:[iObject stringValue]] forKeyword:keyDirectObject];
			[event setDescriptor:[NSAppleEventDescriptor descriptorWithString:@""] forKeyword:kQSIndirectParameter];
		}
		[targetAddress release];
		returnDesc = [script executeAppleEvent:event error:&errorInfo];
		[event release];
		//NSLog(@"%@", errorInfo);
	}
	if (errorDict) NSLog(@"Run Script: %@", [errorDict objectForKey:@"NSAppleScriptErrorMessage"]);
	[script storeInFile:@"scriptPath"];
	[[QSTaskController sharedInstance] removeTask:@"Run AppleScript"];
	[script release];
	return iObject?[QSObject objectWithAEDescriptor:returnDesc]:nil;
}

- (QSObject *)objectForDescriptor:(NSAppleEventDescriptor *)desc {
	QSObject *object = [desc objectValue];
	if ([object isKindOfClass:[NSArray class]] && [object count])
		return [QSObject fileObjectWithArray:[object valueForKey:@"path"]];
	else if ([object isKindOfClass:[NSURL class]])
		return [QSObject fileObjectWithPath:[(NSURL *)object path]];
	else if ([object isKindOfClass:[NSString class]])
		return [QSObject objectWithString:(NSString *)object];
	else
		return nil;
}

-(NSAppleEventDescriptor *)eventDescriptorForObject:(QSObject *)object {
    NSArray *paths = [object validPaths];
    NSAppleEventDescriptor *objectDescriptor = nil;
    if ([paths count] > 0) {
        objectDescriptor = [NSAppleEventDescriptor aliasListDescriptorWithArray:paths];
    } else {
        objectDescriptor = [NSAppleEventDescriptor descriptorWithString:[object stringValue]];
    }
    return objectDescriptor;
}

- (QSObject *)performAction:(QSAction *)action directObject:(QSObject *)dObject indirectObject:(QSObject *)iObject {
	NSDictionary *dict = [action objectForType:QSActionType];
	NSString *scriptPath = [dict objectForKey:kActionScript];
	NSString *handler = [dict objectForKey:kActionHandler];
	if (!handler) {
		NSLog(@"AppleScript Action: No handler? Aborting...");
		return nil;
	}
	if ([scriptPath hasPrefix:@"/"] || [scriptPath hasPrefix:@"~"])
		scriptPath = [scriptPath stringByStandardizingPath];
	else
		scriptPath = [[action bundle] pathForResource:[scriptPath stringByDeletingPathExtension] ofType:[scriptPath pathExtension]];

	NSAppleEventDescriptor *event;
	int pid = [[NSProcessInfo processInfo] processIdentifier];
	NSAppleEventDescriptor* targetAddress = [[NSAppleEventDescriptor alloc] initWithDescriptorType:typeKernelProcessID bytes:&pid length:sizeof(pid)];

	NSDictionary *errorDict = nil;
	NSAppleScript *script = [[NSAppleScript alloc] initWithContentsOfURL:[NSURL fileURLWithPath:scriptPath] error:&errorDict];

	if ([handler isEqualToString:@"QSOpenFileEventPlaceholder"] || [handler isEqualToString:@"QSOpenFileWithEventPlaceholder"]) {
        event = [[NSAppleEventDescriptor alloc] initWithEventClass:[handler isEqualToString:@"QSOpenFileEventPlaceholder"] ? kCoreEventClass :kQSScriptSuite
                                                           eventID:[handler isEqualToString:@"QSOpenFileEventPlaceholder"] ? kAEOpenDocuments : kQSOpenFileScriptCommand
                                                  targetDescriptor:targetAddress
                                                          returnID:kAutoGenerateReturnID
                                                     transactionID:kAnyTransactionID];
		NSArray *files = [dObject validPaths];
		[event setParamDescriptor:[NSAppleEventDescriptor aliasListDescriptorWithArray:files] forKeyword:keyDirectObject];
        if(iObject && ![[iObject primaryType] isEqualToString:QSTextProxyType]) {
            NSAppleEventDescriptor *iObjectDescriptor = [self eventDescriptorForObject:iObject];
            [event setDescriptor:iObjectDescriptor forKeyword:kQSIndirectParameter];
        }
        
	} else if ([handler isEqualToString:@"QSOpenTextEventPlaceholder"]) {
    event = [[NSAppleEventDescriptor alloc] initWithEventClass:kQSScriptSuite
                                                       eventID:kQSOpenTextScriptCommand
                                              targetDescriptor:targetAddress
                                                      returnID:kAutoGenerateReturnID
                                                 transactionID:kAnyTransactionID];
		[event setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:[dObject stringValue]] forKeyword:keyDirectObject];
        NSAppleEventDescriptor *iObjectDescriptor = [self eventDescriptorForObject:iObject];
		[event setDescriptor:iObjectDescriptor forKeyword:kQSIndirectParameter];
	} else {
		id object;
		NSArray *types = [action directTypes];
		NSString *type = ([types count]) ? [types objectAtIndex:0] : [dObject primaryType];
		object = [dObject arrayForType:type];
		object = ([type isEqual:QSFilePathType] ? [NSAppleEventDescriptor aliasListDescriptorWithArray:object] : [NSAppleEventDescriptor descriptorWithObject:object]);
        
		event = [[NSAppleEventDescriptor alloc] initWithSubroutineName:handler argumentsArray:[NSArray arrayWithObject:object]];
	}

	id result = [self objectForDescriptor:[script executeAppleEvent:event error:&errorDict]];
    [event release];
	[targetAddress release];
	[script release];
	if (errorDict) NSLog(@"Perform AppleScript Action Error: %@", [errorDict descriptionInStringsFileFormat]);
	return result;
}

- (NSArray *)validActionsForDirectObject:(QSObject *)dObject indirectObject:(QSObject *)iObject {
	if ([dObject objectForType:QSFilePathType]) {
		NSArray *handlers = [NSAppleScript validHandlersFromArray:[NSArray arrayWithObjects:@"aevtoapp", @"DAEDopnt", @"aevtodoc", nil] inScriptFile:[dObject singleFilePath]];
		//  **** store this information in metadata
		NSMutableArray *array = [NSMutableArray array];
		if ([handlers containsObject:@"aevtoapp"] || ![handlers count])
			[array addObject:kAppleScriptRunAction];
		if ([handlers containsObject:@"DAEDopnt"])
			[array addObject:kAppleScriptOpenTextAction];
		if ([handlers containsObject:@"aevtodoc"])
			[array addObject:kAppleScriptOpenFilesAction];
		return array;
	} else if ([[dObject primaryType] isEqualToString:QSTextType]) {
		return [NSArray arrayWithObjects:kAppleScriptRunTextAction, nil];
	}
	return nil;
}


-(NSArray *)validDirectTypesForScript:(NSString *)path {
    return [self typeArrayForScript:path forHandler:@"DAEDgdob"];
}

- (NSArray *)validIndirectObjectsForAction:(NSString *)action directObject:(QSObject *)dObject {
	if ([action isEqualToString:kAppleScriptOpenTextAction]) {
        return [NSArray arrayWithObject:[QSObject textProxyObjectWithDefaultValue:@""]];
    } else if ([action isEqualToString:kAppleScriptOpenFilesAction]) {
        return [QSLib arrayForType:QSFilePathType];
    };
    if ([action rangeOfString:kAppleScriptActionIDPrefix].location != NSNotFound) {
        // Applescript action, so attempt to get the valid types from the file itself ('get indirect types' handler)
        return [self validIndirectObjectsForAppleScript:action directObject:dObject];
    }
    return nil;
}

-(NSArray *)validIndirectObjectsForAppleScript:(NSString *)script directObject:(QSObject *)dObject {
    NSString *scriptPath = [script substringFromIndex:[kAppleScriptActionIDPrefix length]];
    
    id indirectTypes = [self typeArrayForScript:scriptPath forHandler:@"DAEDgiob"];
    if (indirectTypes) {
        NSMutableArray *indirectObjects = [NSMutableArray array];
        for (NSString *type in indirectTypes) {
            [indirectObjects addObjectsFromArray:[QSLib arrayForType:type]];
        }
        return [[indirectObjects copy] autorelease];
    }
    return nil;
}
                             
- (NSInteger)argumentCountForAction:(NSString *)actionId {
    NSInteger argumentCount = 1;
    QSAction *action = [QSAction actionWithIdentifier:actionId];
	NSString *scriptPath = [action objectForKey:kActionScript];
    
    if ([actionId isEqualToString:kAppleScriptOpenTextAction] || [actionId isEqualToString:kAppleScriptOpenFilesAction])
        argumentCount = 2;
    
    // TODO: figure out why all this code is here - scriptPath always seems to be nil

	if (!scriptPath)
		return argumentCount;

	if ([scriptPath hasPrefix:@"/"] || [scriptPath hasPrefix:@"~"])
		scriptPath = [scriptPath stringByStandardizingPath];
	else
		scriptPath = [[action bundle] pathForResource:[scriptPath stringByDeletingPathExtension] ofType:[scriptPath pathExtension]];

    NSArray *handlers = [NSAppleScript validHandlersFromArray:[NSArray arrayWithObject:@"DAEDgarc"] inScriptFile:scriptPath];
    if( handlers != nil && [handlers count] != 0 ) {
        NSAppleEventDescriptor *event;
        int pid = [[NSProcessInfo processInfo] processIdentifier];
        NSAppleEventDescriptor* targetAddress = [[NSAppleEventDescriptor alloc] initWithDescriptorType:typeKernelProcessID bytes:&pid length:sizeof(pid)];
        
        NSDictionary *errorDict = nil;
        NSAppleScript *script = [[NSAppleScript alloc] initWithContentsOfURL:[NSURL fileURLWithPath:scriptPath] error:&errorDict];
        
		event = [[NSAppleEventDescriptor alloc] initWithEventClass:kQSScriptSuite eventID:kQSGetArgumentCountCommand targetDescriptor:targetAddress returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
        
        NSAppleEventDescriptor *result = [script executeAppleEvent:event error:&errorDict];
        if( result ) {
            argumentCount = (NSInteger)[result int32Value];
        } else if( errorDict != nil )
            NSLog(@"error %@", errorDict);
        
        [event release];
        [targetAddress release];
        [script release];
        
    }

#ifdef DEBUG
	NSLog(@"argument count for %@ is %ld", actionId, (long)argumentCount);
#endif
    
    return argumentCount;
}
                             

// Retrieves an array of types from either the 'get direct types' or 'get indirect types' AppleScript handlers (depending on the input parameter 'handler')
-(NSArray *)typeArrayForScript:(NSString *)scriptPath forHandler:(NSString *)handler {
    id types = nil;
    NSArray *handlers = [NSAppleScript validHandlersFromArray:[NSArray arrayWithObject:handler] inScriptFile:scriptPath];
    if( handlers != nil && [handlers count] != 0 ) {
        NSAppleEventDescriptor *event;
        int pid = [[NSProcessInfo processInfo] processIdentifier];
        NSAppleEventDescriptor* targetAddress = [[NSAppleEventDescriptor alloc] initWithDescriptorType:typeKernelProcessID bytes:&pid length:sizeof(pid)];
        
        NSDictionary *errorDict = nil;
        NSAppleScript *script = [[NSAppleScript alloc] initWithContentsOfURL:[NSURL fileURLWithPath:scriptPath] error:&errorDict];
        
		event = [[NSAppleEventDescriptor alloc] initWithEventClass:kQSScriptSuite eventID:[handler isEqualToString:@"DAEDgdob"] ? kQSGetDirectObjectTypesCommand : kQSGetIndirectObjectTypesCommand targetDescriptor:targetAddress returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
        
        NSAppleEventDescriptor *result = [script executeAppleEvent:event error:&errorDict];
        if( result ) {
            // Convert the AS list type to an array
            types = (NSArray *)[result arrayValue];
        } else if( errorDict != nil )
            NSLog(@"error %@", errorDict);
        [event release];
        [targetAddress release];
        [script release];
    }
    return types;
}
                             
@end
