#import <Cocoa/Cocoa.h>
#import <VVSeekThermalUSB/VVSeekThermalUSB.h>


@interface SeekThermalTestAppDelegate : NSObject <NSApplicationDelegate,SeekThermalDeviceDelegate>	{
	SeekThermalDevice		*device;
	
	IBOutlet NSImageView	*imgView;
}

@property (strong,readwrite) SeekThermalDevice *deviceA;
@property (strong,readwrite) SeekThermalDevice *deviceB;

@end

