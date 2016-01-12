#import <Foundation/Foundation.h>




@interface SeekThermalFrame : NSObject	{
	OSSpinLock		localBitmapsLock;	//	used to lock all the 'raw' data, the bad pixels, the gain vals, and the calibrated vals
	
	//	these contain raw vals from the camera
	UInt16			*rawImageData;	//	raw data from the sensor (frametype 3)
	UInt16			*rawGainData;	//	raw data from the sensor (frametype 4)
	UInt16			*rawOffsetData;	//	raw data from the sensor (frametype 1)
	long			lastFrameIndex;	//	the sensor values output by cameras change as the sensor "warms up"- to compensate for this, we extract the frame index (it's transmitted in the frame) and use this in an algorithm derived by recording sensor data...
	
	//	these are arrays i maintain for doing calculations
	UInt16			*badPixels;	//	0 means "not bad", anything other than 0 means "bad".  contains "patent pixels", any pixels from 'rawGainData' that were 0, and any pixels from 'rawImageData' that were 0.
	double			*gainVals;	//	derived from 'rawGainData'- these gain vals are used as a multiplier when calibrating raw image data
	double			*calibratedVals;	//	locally-maintained array of calibrated vals- values are calibrated sensor values, not a human-readable temperature.  this is what you want.
	
	//	"calibrated" means (gain*(sensor-offset))+col207...
	
	OSSpinLock		propertyLock;	//	used to lock min/maxCalibratedVal, all the avgArea vars
	double			minCalibratedVal;	//	min calibrated val (sensor value, not a temperature)
	double			maxCalibratedVal;	//	max calibrated val (sensor value, not a temperature)
	NSRect			avgArea;	//	if non-zero-rect, calculate the average sensor value of the pixels within this rect
	double			avgAreaCalibratedVal;	//	the average calibrated value of the pixels in "avgArea"
}

- (id) init;

//	assumes ownership of the passed ptr, will free it when it is no longer needed
- (void) consumeDataFromDevice:(UInt16 *)n;

//	the min val in 'calibratedVals'
- (double) minCalibratedVal;
//	the max val in 'calibratedVals'
- (double) maxCalibratedVal;

//	'avgArea' defines a rect in this frame, with the purpose of calculating the average calibrated value of this area
- (void) setAvgArea:(NSRect)n;
- (NSRect) avgArea;
//	the average value of the pixels in 'avgArea'
- (double) avgAreaCalibratedVal;

//	the camera outputs a frame number, and right now i want to retrieve this val from other objects for calibration & testing
- (long) lastFrameIndex;

//	returns a ptr to an array of values describing a bitmap image.  the dimensions of the bitmap image can be retrieved by calling the "calibratedSize" method (it's a 206x156 bitmap).  the image itself is single-channel, and the values retrieved from this method are sensor values, so they aren't normalized (you can either convert these values to a temperature or normalize them and and draw an image).
- (double *) calibratedVals;
//	the size of the image described by the values returned by the "calibratedVals" method
- (NSSize) calibratedSize;

@end




BOOL ArePixelCoordsAPatentPixel(long x, long y);
BOOL IsPixelIndexAPatentPixel(long pixelIndex);
double SensorWarmupCalMultiplierForFrameIndex(double t);
