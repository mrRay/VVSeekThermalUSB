#import <Foundation/Foundation.h>
#import <IOKit/usb/IOUSBLib.h>
#import "SeekThermalFrame.h"
#import "ZWRObject.h"




//	this delegate protocol is how you get frames from the device (register as the device's delegate and you'll be passed frames as they become available).  frame processing occurs on a dispatch queue (this method probably won't get called on the main thread/queue)
@protocol SeekThermalDeviceDelegate
- (void) thermalCamera:(id)device hasNewFrameAvailable:(SeekThermalFrame *)newFrame;
@end

//	these notifications are fired when seek thermal devices are plugged in or removed.  the notification object is the instance of SeekThermalDevice being added/removed.
extern NSString * const kSeekThermalDeviceAddedNotification;
extern NSString * const kSeekThermalDeviceRemovedNotification;




@interface SeekThermalDevice : NSObject	{
	OSSpinLock				runningLock;
	dispatch_queue_t		runningQueue;	//	the "work" (USB comm & image processing) is done on this serial queue
	BOOL					running;
	
	OSSpinLock				delegateLock;
	ZWRObject				*delegate;
	
	IOUSBDeviceInterface			**dev;
	IOUSBInterfaceInterface			**intf;
	int								interfaceImagePipe;	//	one of the interface's endpoints is a bulk in that vends image data- this is the index of the pipe to its data, which we need to read from it
	
	uint32_t				deviceLocation;	//	this is how you tell one device from another?
	SeekThermalFrame		*frame;	//	this is what gets passed to the delegate.  also, raw data from the camera is passed to this (SeekThermalFrame manages all the image/offset/gain calibration)
}

+ (NSMutableArray *) deviceArray;

//	starts pulling data from the device
- (void) start;
//	stops pulling data from the device
- (void) stop;
//	whether or not this instance is running
- (BOOL) running;
//	the deviceLocation is how you differentiate between multiple physical devices
- (uint32_t) deviceLocation;

//	the delegate is NOT retained
- (void) setDelegate:(id)n;

@end




void SeekThermalNewDeviceCallback(void *refCon, io_iterator_t iterator);
void SeekThermalRemoveDeviceCallback(void *refCon, io_iterator_t iterator);
