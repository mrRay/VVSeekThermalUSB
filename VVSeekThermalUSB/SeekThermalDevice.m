#import "SeekThermalDevice.h"




NSString * const kSeekThermalDeviceAddedNotification = @"kSeekThermalDeviceAddedNotification";
NSString * const kSeekThermalDeviceRemovedNotification = @"kSeekThermalDeviceRemovedNotification";
OSSpinLock _seekThermalGlobalArrayLock;
NSMutableArray *_seekThermalGlobalArray = nil;




@interface SeekThermalDevice ()

- (id) initWithService:(io_service_t)usbDevice;

//- (BOOL) openDevice;
//- (void) closeDevice;
- (void) setDefaultConfiguration;
- (BOOL) openInterface;
- (void) closeInterface;
- (void) customSetup;
- (void) customTeardown;


- (void) sendMsg:(UInt8)bmRequestType :(UInt8)bRequest :(UInt16)wValue :(UInt16)wIndex :(UInt16)wLength :(void *)pData;
- (NSData *) rcvMsg:(UInt8)bmRequestType :(UInt8)bRequest :(UInt16)wValue :(UInt16)wIndex :(UInt16)expectedLength;

- (void) pullFrame;

@end




@implementation SeekThermalDevice


+ (void) load	{
	//NSLog(@"%s",__func__);
	_seekThermalGlobalArrayLock = OS_SPINLOCK_INIT;
	_seekThermalGlobalArray = [[NSMutableArray arrayWithCapacity:0] retain];
}
+ (void) initialize	{
	//NSLog(@"%s",__func__);
	//NSLog(@"\t\tglobal array is %@",_seekThermalGlobalArray);
	kern_return_t		kr;
	//	create a master port for communicating with the I/O Kit
	mach_port_t			masterPort = MACH_PORT_NULL;
	kr = IOMasterPort(MACH_PORT_NULL, &masterPort);
	if (kr!=kIOReturnSuccess || !masterPort)	{
		NSLog(@"\t\terr: %X couldnt create master IOKit port, %s",kr,__func__);
		return;
	}
	
	//	assemble a dictionary that describes the seek thermal devices- we find the cameras by looking for devices that match this
	CFMutableDictionaryRef		matchDict = IOServiceMatching(kIOUSBDeviceClassName);
	SInt32						usbVendor = 0x289D;
	SInt32						usbProduct = 0x0010;
	CFDictionarySetValue(matchDict, CFSTR(kUSBVendorName), CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usbVendor));
	CFDictionarySetValue(matchDict, CFSTR(kUSBProductName), CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usbProduct));
	
	//	set up to receive notifications that USB devices matching the dict have been inserted
	{
		//	make a notification port
		IONotificationPortRef	nPort = IONotificationPortCreate(masterPort);
		if (nPort == NULL)	{
			NSLog(@"\t\terr: couldn't create IONotificationPort, %s",__func__);
			return;
		}
		//	get a runloop source for the notification port, install it on the current run loop
		CFRunLoopSourceRef		rl = IONotificationPortGetRunLoopSource(nPort);
		if (rl == NULL)	{
			NSLog(@"\t\terr: runloop source null, %s",__func__);
			return;
		}
		CFRunLoopAddSource(CFRunLoopGetCurrent(), rl, kCFRunLoopDefaultMode);
	
		//	install a notification request for new IOServices that match a dictionary describing this device
		CFMutableDictionaryRef		matchDict = IOServiceMatching(kIOUSBDeviceClassName);
		SInt32						usbVendor = 0x289D;
		SInt32						usbProduct = 0x0010;
		CFDictionarySetValue(matchDict, CFSTR(kUSBVendorName), CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usbVendor));
		CFDictionarySetValue(matchDict, CFSTR(kUSBProductName), CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usbProduct));
		io_iterator_t				devIter = IO_OBJECT_NULL;
		kr = IOServiceAddMatchingNotification(nPort, kIOFirstPublishNotification, matchDict, SeekThermalNewDeviceCallback, nil, &devIter);
		if (kr != kIOReturnSuccess)	{
			NSLog(@"\t\terr %X at IOServiceAddMatchingNotification() in %s",kr,__func__);
			return;
		}
		//	the notification isn't armed yet- it will arm as soon as we run through the iterator that was returned
		io_service_t		usbDevice = IO_OBJECT_NULL;
		while ((usbDevice = IOIteratorNext(devIter)))	{
			SeekThermalDevice		*newDevice = [[SeekThermalDevice alloc] initWithService:usbDevice];
			if (newDevice != nil)	{
				OSSpinLockLock(&_seekThermalGlobalArrayLock);
				[_seekThermalGlobalArray addObject:newDevice];
				OSSpinLockUnlock(&_seekThermalGlobalArrayLock);
				[newDevice release];
			}
			//	free the device object
			IOObjectRelease(usbDevice);
		}
	}
	
	//	set up to receive notifications that USB devices matching the dict have been removed
	{
		//	make a notification port
		IONotificationPortRef	nPort = IONotificationPortCreate(masterPort);
		if (nPort == NULL)	{
			NSLog(@"\t\terr: couldn't create IONotificationPort, %s",__func__);
			return;
		}
		//	get a runloop source for the notification port, install it on the current run loop
		CFRunLoopSourceRef		rl = IONotificationPortGetRunLoopSource(nPort);
		if (rl == NULL)	{
			NSLog(@"\t\terr: runloop source null, %s",__func__);
			return;
		}
		CFRunLoopAddSource(CFRunLoopGetCurrent(), rl, kCFRunLoopDefaultMode);
	
		//	install a notification request for UNPLUGGING IOSurfaces that match the same dict
		io_iterator_t				devIter = IO_OBJECT_NULL;
		kr = IOServiceAddMatchingNotification(nPort, kIOTerminatedNotification, matchDict, SeekThermalRemoveDeviceCallback, nil, &devIter);
		if (kr != kIOReturnSuccess)	{
			NSLog(@"\t\terr %X at 2nd IOServiceAddMatchingNotification() in %s",kr,__func__);
			return;
		}
		//	the notification isn't armed yet- it will arm as soon as we run through the iterator that was returned
		io_service_t		usbDevice = IO_OBJECT_NULL;
		while ((usbDevice = IOIteratorNext(devIter)))	{
			//	free the device object
			IOObjectRelease(usbDevice);
		}
	}
	
	//NSLog(@"\t\tnot sure if i sholud be deallocating the mach port here... %s",__func__);
	mach_port_deallocate(mach_task_self(), masterPort);
}
+ (NSArray *) deviceArray	{
	OSSpinLockLock(&_seekThermalGlobalArrayLock);
	NSArray		*returnMe = ([_seekThermalGlobalArray count]<1) ? nil : [[_seekThermalGlobalArray copy] autorelease];
	OSSpinLockUnlock(&_seekThermalGlobalArrayLock);
	return returnMe;
}


- (id) initWithService:(io_service_t)usbDevice	{
	//NSLog(@"%s",__func__);
	self = [super init];
	if (self != nil)	{
		runningLock = OS_SPINLOCK_INIT;
		runningQueue = NULL;
		running = NO;
		delegateLock = OS_SPINLOCK_INIT;
		delegate= nil;
		dev = NULL;
		intf = NULL;
		interfaceImagePipe = 0;
		deviceLocation = 0;
		frame = [[SeekThermalFrame alloc] init];
		
		//lastFrameType = 0;
		
		BOOL					foundADevice = NO;
		//	make an intermediate plug-in
		IOReturn				kr = kIOReturnSuccess;
		IOCFPlugInInterface		**plugInInterface = NULL;
		SInt32					score;
		kr = IOCreatePlugInInterfaceForService(usbDevice, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugInInterface, &score);
		if (kr != kIOReturnSuccess)	{
			NSLog(@"\t\terr %X at IOCreatePlugInInterfaceForSerivce() in %s",kr,__func__);
		}
		else	{
			//	now create the device interface
			//IOUSBDeviceInterface	**dev = NULL;
			HRESULT					result = (*plugInInterface)->QueryInterface(plugInInterface, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
			if (result || !dev)	{
				NSLog(@"\t\terr %X at QueryInterface() in %s",result,__func__);
			}
			else	{
			
				//	get the location ID!
				(*dev)->GetLocationID(dev, &deviceLocation);
				//	check a couple vals, confirm that this is the cam i'm looking for...
				//UInt16		testVendor;
				//UInt16		testProduct;
				//(*dev)->GetDeviceVendor(dev, &testVendor);
				//(*dev)->GetDeviceProduct(dev, &testProduct);
				//if (testVendor!=usbVendor || testProduct!=usbProduct)	{
				//	NSLog(@"\t\terr: test vendor/product don't match target vendor/product, %s",__func__);
				//}
				//else	{
					//	open the device
					kr = (*dev)->USBDeviceOpen(dev);
					if (kr != kIOReturnSuccess)	{
						NSLog(@"\t\terr %X at USBDeviceOpen() in %s",kr,__func__);
					}
					else	{
						foundADevice = YES;
						//NSLog(@"\t\tsuccess!  found the device i was looking for!");
					}
				//}
			
			
				//	if i didn't find a device, this wasn't the device i was looking for- i should free it
				if (!foundADevice)	{
					(*dev)->USBDeviceClose(dev);
					(*dev)->Release(dev);
					dev = NULL;
				}
			}
		
		
			//	free the plugin
			(*plugInInterface)->Release(plugInInterface);
		}
		//	if i didn't find a device, bail and return nil
		if (!foundADevice)	{
			[self release];
			return nil;
		}
	}
	return self;
}
- (void) dealloc	{
	//NSLog(@"%s",__func__);
	//	stop the device- this closes the interface
	[self stop];
	
	//	close the USB device
	if (dev != nil)	{
		IOReturn			kr = (*dev)->USBDeviceClose(dev);
		if (kr != kIOReturnSuccess)
			NSLog(@"\t\terr %X at USBDeviceClose(0 in %s",kr,__func__);
		(*dev)->Release(dev);
		dev = NULL;
	}
	
	//	release the frame
	if (frame != nil)	{
		[frame release];
		frame = nil;
	}
	
	[super dealloc];
}


- (void) start	{
	if ([self running])
		return;
	/*
	if (![self openDevice])	{
		[self closeDevice];
		return;
	}
	*/
	[self setDefaultConfiguration];
	if (![self openInterface])	{
		[self closeInterface];
		//[self closeDevice];
		return;
	}
	[self customSetup];
	OSSpinLockLock(&runningLock);
	runningQueue = dispatch_queue_create([[NSString stringWithFormat:@"SeekThermalDevice%p",self] cStringUsingEncoding:NSASCIIStringEncoding], DISPATCH_QUEUE_SERIAL);
	running = YES;
	OSSpinLockUnlock(&runningLock);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1./30.*NSEC_PER_SEC), runningQueue, ^{
		[self pullFrame];
	});
}
- (void) stop	{
	//NSLog(@"%s",__func__);
	if (![self running])
		return;
	OSSpinLockLock(&runningLock);
	dispatch_release(runningQueue);
	runningQueue = NULL;
	running = NO;
	OSSpinLockUnlock(&runningLock);
	[self customTeardown];
	[self closeInterface];
	//[self closeDevice];
}


- (BOOL) running	{
	OSSpinLockLock(&runningLock);
	BOOL		returnMe = running;
	OSSpinLockUnlock(&runningLock);
	return returnMe;
}
- (uint32_t) deviceLocation	{
	return deviceLocation;
}


- (void) setDefaultConfiguration	{
	//NSLog(@"%s",__func__);
	if (dev == NULL)	{
		NSLog(@"\t\terr: bailing immediately, no device ref, %s",__func__);
		return;
	}
	//	get the configuration descriptor for index 0
	IOReturn		kr;
	UInt8			numConfig;
	kr = (*dev)->GetNumberOfConfigurations(dev, &numConfig);
	if (kr!=kIOReturnSuccess || numConfig<1)	{
		NSLog(@"\t\terr: %X, either error or no configs in %s",kr,__func__);
	}
	else	{
		IOUSBConfigurationDescriptorPtr		configDesc;
		kr = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &configDesc);
		if (kr != kIOReturnSuccess)	{
			NSLog(@"\t\terr %X  at GetConfigurationDescriptorPtr() in %s",kr,__func__);
		}
		else	{
			//	set the device's configuration (found in the bConfigurationValue field of the descriptor struct)
			kr = (*dev)->SetConfiguration(dev, configDesc->bConfigurationValue);
			if (kr != kIOReturnSuccess)	{
				NSLog(@"\t\terr %X at SetConfiguration() in %s",kr,__func__);
			}
			else	{
				NSLog(@"\t\tsuccess!  set the default configuration...");
			}
		}
	}
}
- (BOOL) openInterface	{
	//NSLog(@"%s",__func__);
	if (dev == NULL)	{
		NSLog(@"\t\terr: bailing immediately, no device ref, %s",__func__);
		return NO;
	}
	if (intf != NULL)	{
		NSLog(@"\t\terr: bailing immediately, already an open interface, %s",__func__);
		return NO;
	}
	IOReturn					kr;
	//	make a request, create an interator for it, run through the interfaces
	IOUSBFindInterfaceRequest	request;
	request.bInterfaceClass = kIOUSBFindInterfaceDontCare;
	request.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
	request.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
	request.bAlternateSetting = kIOUSBFindInterfaceDontCare;
	io_iterator_t				iterator;
	kr = (*dev)->CreateInterfaceIterator(dev, &request, &iterator);
	if (kr != kIOReturnSuccess)	{
		NSLog(@"\t\terr %X at CreateInterfaceIterator() in %s",kr,__func__);
		return NO;
	}
	BOOL						foundAnInterface = NO;
	io_service_t				usbInterface;
	while ((usbInterface = IOIteratorNext(iterator)))	{
		//	create an intermediate plug-in
		IOCFPlugInInterface		**plugInInterface = NULL;
		SInt32					score;
		kr = IOCreatePlugInInterfaceForService(usbInterface, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugInInterface, &score);
		if (kr != kIOReturnSuccess)	{
			NSLog(@"\t\terr %X at IOCreatePlugInInterfaceForService() in %s",kr,__func__);
		}
		else	{
			//	create the interface interface from the plugin
			HRESULT					result = (*plugInInterface)->QueryInterface(plugInInterface, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&intf);
			if (result || !intf)	{
				NSLog(@"\t\terr %d at QueryInterface() in %s",result,__func__);
			}
			else	{
				//	get the interface class and subclass, number of endpoints
				UInt8				interfaceClass;
				UInt8				interfaceSubClass;
				UInt8				interfaceNumEndpoints;
				(*intf)->GetInterfaceClass(intf, &interfaceClass);
				(*intf)->GetInterfaceSubClass(intf, &interfaceSubClass);
				(*intf)->GetNumEndpoints(intf, &interfaceNumEndpoints);
				//NSLog(@"\t\tinterface class is %X, subclass is %X, num endpoints is %d",interfaceClass,interfaceSubClass,interfaceNumEndpoints);
				if (interfaceClass!=0xFF || interfaceSubClass!=0xF0 || interfaceNumEndpoints<2)	{
					NSLog(@"\t\terr: interface class/subclass (%X/%X) not as expected or endpoint count wrong (%d), %s",interfaceClass,interfaceSubClass,interfaceNumEndpoints,__func__);
				}
				else	{
					//	actually open the interface
					kr = (*intf)->USBInterfaceOpen(intf);
					if (kr != kIOReturnSuccess)	{
						NSLog(@"\t\terr %X at USBInterfaceOpen() in %s",kr,__func__);
					}
					else	{
						
						//	run through each of the pipes- we need to examine their properties to locate the pipe that will give us image data
						for (int pipeRef=0; pipeRef<(interfaceNumEndpoints+1); ++pipeRef)	{
							UInt8			direction;
							UInt8			number;
							UInt8			transferType;
							UInt16			maxPacketSize;
							UInt8			interval;
							kr = (*intf)->GetPipeProperties(intf, pipeRef, &direction, &number, &transferType, &maxPacketSize, &interval);
							if (kr != kIOReturnSuccess)	{
								NSLog(@"\t\terr %X at GetPipeProperties() in %s",kr,__func__);
							}
							else	{
								NSString		*xferTypeString = nil;
								NSString		*xferDirectionString = nil;
								
								switch (transferType)	{
								case kUSBControl:
									xferTypeString = @"control";
									break;
								case kUSBIsoc:
									xferTypeString = @"isoc";
									break;
								case kUSBBulk:
									xferTypeString = @"bulk";
									break;
								case kUSBInterrupt:
									xferTypeString = @"interrupt";
									break;
								case kUSBAnyType:
									xferTypeString = @"any";
									break;
								default:
									xferTypeString = @"???";
								}
								
								switch (direction)	{
								case kUSBOut:
									xferDirectionString = @"out";
									break;
								case kUSBIn:
									xferDirectionString = @"in";
									break;
								case kUSBNone:
									xferDirectionString = @"none";
									break;
								case kUSBAnyDirn:
									xferDirectionString = @"any";
									break;
								default:
									xferDirectionString = @"???";
								}
								
								if (transferType==kUSBBulk && direction==kUSBIn)	{
									//NSLog(@"\t\tfound my pipeRef, %d: %@ %@",pipeRef,xferTypeString,xferDirectionString);
									interfaceImagePipe = pipeRef;
									break;
								}
							}
						}
						
						//	if everything's good and this is my interface, set this to YES so we hang on to a copy of the interface!
						foundAnInterface = YES;
						//NSLog(@"\t\tsuccess!  found the interface i was looking for!");
						
						//	if i didn't find an interface, close the interface i just opened...
						if (!foundAnInterface)	{
							(*intf)->USBInterfaceClose(intf);
						}
					}
				}
				
				//	if i haven't found an interface, free this interface
				if (!foundAnInterface)	{
					(*intf)->Release(intf);
					intf = NULL;
				}
			}
			
			//	free the intermediate plug-in
			(*plugInInterface)->Release(plugInInterface);
		}
		
		//	free the interface object
		IOObjectRelease(usbInterface);
		
		//	if i found the interface i was looking for, i can break the loop..
		if (foundAnInterface)
			break;
	}
	if (!foundAnInterface)
		return NO;
	return YES;
}
- (void) closeInterface	{
	//NSLog(@"%s",__func__);
	if (dev == NULL)	{
		NSLog(@"\t\terr: bailing immediately, no device ref, %s",__func__);
		return;
	}
	if (intf == NULL)	{
		NSLog(@"\t\terr: bailing immediately, no open interface, %s",__func__);
		return;
	}
	IOReturn			kr = (*intf)->USBInterfaceClose(intf);
	if (kr != kIOReturnSuccess)
		NSLog(@"\t\terr %X at USBInterfaceClose() in %s",kr,__func__);
	(*intf)->Release(intf);
	intf = NULL;
}
- (void) customSetup	{
	//NSLog(@"%s",__func__);
	if (dev==NULL || intf==NULL)	{
		NSLog(@"\t\terr: bailing, device or interface nil, %s",__func__);
		return;
	}
	
	//	this is all custom setup stuff- i don't know what most of it "means" or "does", i'm just converting a functional python script to this API
	/*
	void		(^replyDisplayBlock)(NSData *replyData) = ^(NSData *replyData)	{
		if (replyData != nil)	{
			NSMutableArray	*valArray = [NSMutableArray arrayWithCapacity:0];
			UInt8			*rPtr = (UInt8 *)[replyData bytes];
			for (int i=0; i<[replyData length]; ++i)	{
				[valArray addObject:[NSNumber numberWithInteger:*rPtr]];
				++rPtr;
			}
			NSLog(@"\t\treceived vals %@",valArray);
		}
	};
	*/
	
	
	{
		UInt8		tmpVal = 0x01;
		//send_msg(0x41, 0x54, 0, 0, msg)
		[self sendMsg:0x41 :0x54 :0 :0 :sizeof(tmpVal) :&tmpVal];
	}
	
	{
		UInt16		tmpVal = 0x0000;
		//send_msg(0x41, 0x3C, 0, 0, '\x00\x00')
		[self sendMsg:0x41 :0x3C :0 :0 :sizeof(tmpVal) :&tmpVal];
	}
	
	{
		//ret1 = receive_msg(0xC1, 0x4E, 0, 0, 4)
		//print ret1
		[self rcvMsg:0xC1 :0x4E :0 :0 :4];
		//replyDisplayBlock(reply);
	}
	
	{
		//ret2 = receive_msg(0xC1, 0x36, 0, 0, 12)
		//print ret2
		[self rcvMsg:0xC1 :0x36 :0 :0 :12];
		//replyDisplayBlock(reply);
	}
	
	{
		size_t		tmpValSize = sizeof(UInt8)*6;
		UInt8		*tmpVal = malloc(tmpValSize);
		*(tmpVal+0) = 0x20;
		*(tmpVal+1) = 0x00;
		*(tmpVal+2) = 0x30;
		*(tmpVal+3) = 0x00;
		*(tmpVal+4) = 0x00;
		*(tmpVal+5) = 0x00;
		//send_msg(0x41, 0x56, 0, 0, '\x20\x00\x30\x00\x00\x00')
		[self sendMsg:0x41 :0x56 :0 :0 :tmpValSize :tmpVal];
		free(tmpVal);
	}
	
	{
		//ret3 = receive_msg(0xC1, 0x58, 0, 0, 0x40)
		//print ret3
		[self rcvMsg:0xC1 :0x58 :0 :0 :0x40];
		//replyDisplayBlock(reply);
	}
	
	{
		size_t		tmpValSize = sizeof(UInt8)*6;
		UInt8		*tmpVal = malloc(tmpValSize);
		*(tmpVal+0) = 0x20;
		*(tmpVal+1) = 0x00;
		*(tmpVal+2) = 0x50;
		*(tmpVal+3) = 0x00;
		*(tmpVal+4) = 0x00;
		*(tmpVal+5) = 0x00;
		//send_msg(0x41, 0x56, 0, 0, '\x20\x00\x50\x00\x00\x00')
		[self sendMsg:0x41 :0x56 :0 :0 :tmpValSize :tmpVal];
		free(tmpVal);
	}
	
	{
		//ret4 = receive_msg(0xC1, 0x58, 0, 0, 0x40)
		//print ret4
		[self rcvMsg:0xC1 :0x58 :0 :0 :0x40];
		//replyDisplayBlock(reply);
	}
	
	{
		size_t		tmpValSize = sizeof(UInt8)*6;
		UInt8		*tmpVal = malloc(tmpValSize);
		*(tmpVal+0) = 0x0C;
		*(tmpVal+1) = 0x00;
		*(tmpVal+2) = 0x70;
		*(tmpVal+3) = 0x00;
		*(tmpVal+4) = 0x00;
		*(tmpVal+5) = 0x00;
		//send_msg(0x41, 0x56, 0, 0, '\x0C\x00\x70\x00\x00\x00')
		[self sendMsg:0x41 :0x56 :0 :0 :tmpValSize :tmpVal];
		free(tmpVal);
	}
	
	{
		//ret5 = receive_msg(0xC1, 0x58, 0, 0, 0x18)
		//print ret5
		[self rcvMsg:0xC1 :0x58 :0 :0 :0x18];
		//replyDisplayBlock(reply);
	}
	
	{
		size_t		tmpValSize = sizeof(UInt8)*6;
		UInt8		*tmpVal = malloc(tmpValSize);
		*(tmpVal+0) = 0x06;
		*(tmpVal+1) = 0x00;
		*(tmpVal+2) = 0x08;
		*(tmpVal+3) = 0x00;
		*(tmpVal+4) = 0x00;
		*(tmpVal+5) = 0x00;
		//send_msg(0x41, 0x56, 0, 0, '\x06\x00\x08\x00\x00\x00')
		[self sendMsg:0x41 :0x56 :0 :0 :tmpValSize :tmpVal];
		free(tmpVal);
	}
	
	{
		//ret6 = receive_msg(0xC1, 0x58, 0, 0, 0x0C)
		//print ret6
		[self rcvMsg:0xC1 :0x58 :0 :0 :0x0C];
		//replyDisplayBlock(reply);
	}
	
	{
		size_t		tmpValSize = sizeof(UInt8)*4;
		UInt8		*tmpVal = malloc(tmpValSize);
		*(tmpVal+0) = 0x08;
		*(tmpVal+1) = 0x00;
		//send_msg(0x41, 0x3E, 0, 0, '\x08\x00')
		[self sendMsg:0x41 :0x3E :0 :0 :tmpValSize :tmpVal];
		free(tmpVal);
	}
	
	{
		//ret7 = receive_msg(0xC1, 0x3D, 0, 0, 2)
		//print ret7
		[self rcvMsg:0xC1 :0x3D :0 :0 :2];
		//replyDisplayBlock(reply);
	}
	
	{
		size_t		tmpValSize = sizeof(UInt8)*4;
		UInt8		*tmpVal = malloc(tmpValSize);
		*(tmpVal+0) = 0x08;
		*(tmpVal+1) = 0x00;
		//send_msg(0x41, 0x3E, 0, 0, '\x08\x00')
		[self sendMsg:0x41 :0x3E :0 :0 :tmpValSize :tmpVal];
		free(tmpVal);
	}
	
	{
		size_t		tmpValSize = sizeof(UInt8)*4;
		UInt8		*tmpVal = malloc(tmpValSize);
		*(tmpVal+0) = 0x01;
		*(tmpVal+1) = 0x00;
		//send_msg(0x41, 0x3C, 0, 0, '\x01\x00')
		[self sendMsg:0x41 :0x3C :0 :0 :tmpValSize :tmpVal];
		free(tmpVal);
	}
	
	{
		//ret8 = receive_msg(0xC1, 0x3D, 0, 0, 2)
		//print ret8
		[self rcvMsg:0xC1 :0x3D :0 :0 :2];
		//replyDisplayBlock(reply);
	}
}
- (void) customTeardown	{
	//NSLog(@"%s",__func__);
	if (dev==NULL || intf==NULL)	{
		//NSLog(@"\t\terr: bailing, device or interface nil, %s",__func__);
		return;
	}
	UInt16			tmpVal = 0x0000;
	for (int i=0; i<3; ++i)	{
		[self sendMsg:0x41:0x3C:0:0:sizeof(tmpVal):&tmpVal];
	}
}


- (void) sendMsg:(UInt8)bmRequestType :(UInt8)bRequest :(UInt16)wValue :(UInt16)wIndex :(UInt16)wLength :(void *)pData	{
	//NSLog(@"%s ... %X, %X, %d, %d, %d, %p",__func__,bmRequestType,bRequest,wValue,wIndex,wLength,pData);
	if (dev==NULL || intf==NULL)	{
		//NSLog(@"\t\terr: bailing, device or interface nil, %s",__func__);
		return;
	}
	IOUSBDevRequest		cr;
	cr.bmRequestType = bmRequestType;
	cr.bRequest = bRequest;
	cr.wValue = wValue;
	cr.wIndex = wIndex;
	cr.wLength = wLength;
	cr.pData = pData;
	cr.wLenDone = 0;
	
	BOOL				suddenlyDisconnected = NO;
	kern_return_t		kr = (*intf)->ControlRequest(intf, 0, &cr);
	if (kr != kIOReturnSuccess)	{
		//	0x02D9 is 'device not attached', 0x02C0 is 'no such device'
		if (kr==0xE00002D9 || kr==0xE00002C0)
			suddenlyDisconnected = YES;
		else	{
			//NSLog(@"%s ... %X, %X, %d, %d, %d, %p",__func__,bmRequestType,bRequest,wValue,wIndex,wLength,pData);
			NSLog(@"\t\terr: %X at ControlRequest() in %s",kr,__func__);
		}
	}
	else	{
		//NSLog(@"\t\tsuccessfully sent the msg...");
	}
	
	if (suddenlyDisconnected)	{
		dev = nil;
		intf = nil;
		OSSpinLockLock(&runningLock);
		running = NO;
		OSSpinLockUnlock(&runningLock);
	}
}
- (NSData *) rcvMsg:(UInt8)bmRequestType :(UInt8)bRequest :(UInt16)wValue :(UInt16)wIndex :(UInt16)expectedLength	{
	//NSLog(@"%s ... %X, %X, %d, %d, %d",__func__,bmRequestType,bRequest,wValue,wIndex,expectedLength);
	if (dev==NULL || intf==NULL)	{
		//NSLog(@"\t\terr: bailing, device or interface nil, %s",__func__);
		return nil;
	}
	NSData				*returnMe = nil;
	void				*replyData = malloc(expectedLength);
	bzero(replyData, expectedLength);
	
	IOUSBDevRequest		cr;
	cr.bmRequestType = bmRequestType;
	cr.bRequest = bRequest;
	cr.wValue = wValue;
	cr.wIndex = wIndex;
	cr.wLength = expectedLength;
	cr.pData = replyData;
	cr.wLenDone = 0;
	
	BOOL				suddenlyDisconnected = NO;
	kern_return_t		kr = (*intf)->ControlRequest(intf, 0, &cr);
	if (kr != kIOReturnSuccess)	{
		//	0x02D9 is 'device not attached', 0x02C0 is 'no such device'
		if (kr==0xE00002D9 || kr==0xE00002C0)
			suddenlyDisconnected = YES;
		else	{
			//NSLog(@"%s ... %X, %X, %d, %d, %d",__func__,bmRequestType,bRequest,wValue,wIndex,expectedLength);
			NSLog(@"\t\terr: %X at ControlRequest() in %s",kr,__func__);
		}
	}
	else	{
		//NSLog(@"\t\tsuccessfully sent the msg...");
		returnMe = [NSData dataWithBytes:replyData length:expectedLength];
	}
	free(replyData);
	
	if (suddenlyDisconnected)	{
		dev = nil;
		intf = nil;
		OSSpinLockLock(&runningLock);
		running = NO;
		OSSpinLockUnlock(&runningLock);
	}
	
	return returnMe;
}


- (void) pullFrame	{
	if (![self running])
		return;
	
	//	i think this is a "read frame" request?
	{
		size_t		tmpValSize = sizeof(UInt8)*4;
		UInt8		*tmpVal = malloc(tmpValSize);
		*(tmpVal+0) = 0xC0;
		*(tmpVal+1) = 0x7E;
		*(tmpVal+2) = 0x00;
		*(tmpVal+3) = 0x00;
		//send_msg(0x41, 0x53, 0, 0, '\xC0\x7E\x00\x00')
		[self sendMsg:0x41 :0x53 :0 :0 :tmpValSize :tmpVal];
		free(tmpVal);
	}
	
	kern_return_t	kr;
	UInt16			*newFrameData = malloc(208 * 156 * 16 / 8);
	UInt16			*pipeDest = newFrameData;
	UInt32			pipeDestSize = 0;
	UInt32			totalXFerSize = 0;
	UInt32			targetXFerSize = (208 * 156 * 16 / 8);
	//	write the raw vals from the USB device into 'newFrameData'
	do	{
		//	we set 'pipDestSize' to 0x3F60 because that's how much we want to xfer- after reading, it's set to how many bytes were actually xfered
		pipeDestSize = 0x3F60;
		
		kr = (*intf)->ReadPipe(intf, interfaceImagePipe, pipeDest, &pipeDestSize);
		if (kr != kIOReturnSuccess)	{
			NSLog(@"\t\terr %X at ReadPipe() in %s",kr,__func__);
			if (kr == 0xE00002EB)	//	'operation aborted'
				break;
		}
		else	{
			//NSLog(@"\t\tsuccessfully read %d bytes from the pipe...",(unsigned int)pipeDestSize);
			
			totalXFerSize += pipeDestSize;
			pipeDest += pipeDestSize/2;
		}
	} while (kr==kIOReturnSuccess && totalXFerSize<targetXFerSize);	
	
	//	figure out what kind of frame i just wrote
	UInt16			frameType = (*(newFrameData+10));
	BOOL			newFrameAvailable = NO;
	switch (frameType)	{
	//case 1:	//	offset calibration (shutter blocking sensor?)
	//	newFrameAvailable = NO;
	//	break;
	case 3:	//	main data frame
		newFrameAvailable = YES;
		break;
	//case 4:	//	gain calibration
	//	newFrameAvailable = NO;
	//	break;
	}
	
	//	pass the frame cache to the frame, which will assume ownership for it
	[frame consumeDataFromDevice:newFrameData];
	
	//	if there's a new frame available, pass it to the delegate
	if (newFrameAvailable)	{
		//[analysisArray addObject:NUMDOUBLE([frame avgAreaCalibratedVal])];
		//[frameIndexArray addObject:NUMLONG([frame lastFrameIndex])];
		
		OSSpinLockLock(&delegateLock);
		id				localDelegate = (delegate==nil) ? nil : [delegate object];
		OSSpinLockUnlock(&delegateLock);
		if (localDelegate != nil)	{
			[localDelegate thermalCamera:self hasNewFrameAvailable:[[frame retain] autorelease]];
		}
		else
			NSLog(@"\t\tdelegate nil!  hurray!  ZWRs work!");
	}
	
	//	if i'm still running, enqueue another block that calls this method
	if ([self running])	{
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1./30.*NSEC_PER_SEC), runningQueue, ^{
			[self pullFrame];
		});
	}
}


- (void) setDelegate:(id)n	{
	OSSpinLockLock(&delegateLock);
	delegate = [[ZWRObject alloc] initWithObject:n];
	OSSpinLockUnlock(&delegateLock);
}
- (NSString *) description	{
	return [NSString stringWithFormat:@"<SeekThermalDevice: %X>",deviceLocation];
}


@end




void SeekThermalNewDeviceCallback(void *refCon, io_iterator_t iterator)	{
	//NSLog(@"%s",__func__);
	
	io_service_t		usbDevice = IO_OBJECT_NULL;
	while ((usbDevice = IOIteratorNext(iterator)))	{
		SeekThermalDevice		*newDevice = [[SeekThermalDevice alloc] initWithService:usbDevice];
		if (newDevice != nil)	{
			//	add the new device to the array of devices
			OSSpinLockLock(&_seekThermalGlobalArrayLock);
			[_seekThermalGlobalArray addObject:newDevice];
			OSSpinLockUnlock(&_seekThermalGlobalArrayLock);
			[newDevice release];
			//	post a notification that the new device was discovered
			[[NSNotificationCenter defaultCenter] postNotificationName:kSeekThermalDeviceAddedNotification object:newDevice];
		}
		//	free the device object
		IOObjectRelease(usbDevice);
	}
}
void SeekThermalRemoveDeviceCallback(void *refCon, io_iterator_t iterator)	{
	//NSLog(@"%s",__func__);
	
	io_service_t		usbDevice = IO_OBJECT_NULL;
	while ((usbDevice = IOIteratorNext(iterator)))	{
		//	get the location of the device being removed
		CFTypeRef			prop  = IORegistryEntryCreateCFProperty (usbDevice,
			CFSTR(kUSBDevicePropertyLocationID),
			kCFAllocatorDefault,
			0);
		uint32_t			targetLocationID = 0;
		if (CFGetTypeID(prop) == CFNumberGetTypeID())
			CFNumberGetValue((CFNumberRef)prop, kCFNumberSInt32Type, &targetLocationID);
		
		//	free the device object
		IOObjectRelease(usbDevice);
		
		
		//	find the SeekThermalDevice instance that corresponds to the locationID of the device being removed
		SeekThermalDevice			*targetDevice = nil;
		OSSpinLockLock(&_seekThermalGlobalArrayLock);
		for (SeekThermalDevice *tmpDevice in _seekThermalGlobalArray)	{
			if ([tmpDevice deviceLocation] == targetLocationID)	{
				targetDevice = tmpDevice;
				break;
			}
		}
		if (targetDevice != nil)
			[targetDevice retain];
		OSSpinLockUnlock(&_seekThermalGlobalArrayLock);
		
		//	if i found the instance being removed, stop it, remove it, post a notification, and release it
		if (targetDevice != nil)	{
			[targetDevice stop];
			
			OSSpinLockLock(&_seekThermalGlobalArrayLock);
			[_seekThermalGlobalArray removeObjectIdenticalTo:targetDevice];
			OSSpinLockUnlock(&_seekThermalGlobalArrayLock);
			
			[[NSNotificationCenter defaultCenter] postNotificationName:kSeekThermalDeviceRemovedNotification object:targetDevice];
			
			[targetDevice autorelease];
		}
	}
}
