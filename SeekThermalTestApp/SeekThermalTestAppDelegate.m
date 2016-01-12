#import "SeekThermalTestAppDelegate.h"




@interface SeekThermalTestAppDelegate ()
@property (weak) IBOutlet NSWindow *window;
@end




@implementation SeekThermalTestAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	NSLog(@"%s",__func__);
	device = nil;
	
	[SeekThermalDevice class];
	
	//	try to get a device right away
	NSArray				*devices = [SeekThermalDevice deviceArray];
	if (devices!=nil && [devices count]>=1)	{
		[self setDevice:[devices objectAtIndex:0]];
	}
	
	//	register to receive notifications that devices have been added or removed
	NSNotificationCenter		*ns = [NSNotificationCenter defaultCenter];
	[ns addObserver:self selector:@selector(newThermalDevice:) name:kSeekThermalDeviceAddedNotification object:nil];
	[ns addObserver:self selector:@selector(removedThermalDevice:) name:kSeekThermalDeviceRemovedNotification object:nil];
	
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
	NSLog(@"%s",__func__);
	if ([self device]!=nil)
		[[self device] stop];
}

- (void) newThermalDevice:(NSNotification *)note	{
	NSLog(@"%s",__func__);
	if ([self device]==nil)
		[self setDevice:[note object]];
}
- (void) removedThermalDevice:(NSNotification *)note	{
	NSLog(@"%s",__func__);
	if ([self device] == [note object])
		[self setDevice:nil];
}
- (SeekThermalDevice *) device	{
	return device;
}
- (void) setDevice:(SeekThermalDevice *)n	{
	device = n;
	if (device != nil)	{
		[device setDelegate:self];
		[device start];
	}
}
- (void) thermalCamera:(id)device hasNewFrameAvailable:(SeekThermalFrame *)newFrame	{
	//	make a RGB bitmap rep, populate it with the contents of the frame
	NSSize				frameSize = [newFrame calibratedSize];
	NSBitmapImageRep	*rep = [[NSBitmapImageRep alloc]
		initWithBitmapDataPlanes:nil
		pixelsWide:(long)frameSize.width
		pixelsHigh:(long)frameSize.height
		bitsPerSample:8
		samplesPerPixel:4
		hasAlpha:YES
		isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace
		bitmapFormat:0
		bytesPerRow:32 * (long)frameSize.width / 8
		bitsPerPixel:32];
	if (rep == nil)	{
		NSLog(@"\t\terr: couldn't make bitmap rep, %s",__func__);
		return;
	}
	unsigned char		*repData = [rep bitmapData];
	if (repData == nil)	{
		NSLog(@"\t\terr: rep bitmapData nil, %s",__func__);
		return;
	}
	//	the bitmap rep may have more bytes per row than the array of calibrated vals from the frame, so we need to know how many bytes per row are in the rep, and how many bytes per row we're actually writing to the rep
	NSInteger			repBytesPerRow = [rep bytesPerRow];
	NSInteger			minBytesPerRow = 8*4*(int)frameSize.width/8;
	
	
	uint8_t				*wPtr = repData;
	double				*rPtr = [newFrame calibratedVals];
	double				frameMin = [newFrame minCalibratedVal];
	double				frameMax = [newFrame maxCalibratedVal];
	
	for (int y=0; y<(int)frameSize.height; ++y)	{
		for (int x=0; x<(int)frameSize.width; ++x)	{
			*(wPtr+0) = (uint8_t)((*rPtr-frameMin)/(frameMax-frameMin)*255.);
			*(wPtr+1) = *(wPtr);
			*(wPtr+2) = *(wPtr);
			*(wPtr+3) = 255;
			wPtr += 4;
			++rPtr;
		}
		wPtr += (repBytesPerRow - minBytesPerRow);
	}
	
	NSImage		*newImg = [[NSImage alloc] initWithSize:frameSize];
	[newImg addRepresentation:rep];
	[newImg setFlipped:YES];
	
	dispatch_async(dispatch_get_main_queue(), ^{
		[imgView setImage:newImg];
	});
}

@end
