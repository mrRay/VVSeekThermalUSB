#import "SeekThermalFrame.h"




#define VVMAXX(r) ((r.size.width>=0) ? (r.origin.x+r.size.width) : (r.origin.x))
#define VVMAXY(r) ((r.size.height>=0) ? (r.origin.y+r.size.height) : (r.origin.y))




@interface SeekThermalFrame ()

//	run through 'rawImageData' and 'rawGainData' locating "bad pixels", writes the results to 'badPixels'
- (void) updateBadPixels;
//	applies the gain (via 'gainVals') and offset (via 'rawOffsetData') to 'rawGainData'
- (void) applyCalibrations;

- (void) setRawData:(UInt16 *)n;
- (void) setGainCalData:(UInt16 *)n;
- (void) setOffsetCalData:(UInt16 *)n;

@end




@implementation SeekThermalFrame


- (id) init	{
	//NSLog(@"%s",__func__);
	self = [super init];
	if (self != nil)	{
		localBitmapsLock = OS_SPINLOCK_INIT;
		rawImageData = nil;
		rawGainData = nil;
		rawOffsetData = nil;
		lastFrameIndex = 0;
		badPixels = malloc(208 * 156 * 16 / 8);
		gainVals = malloc(208 * 156 * sizeof(double));
		calibratedVals = malloc(206 * 156 * sizeof(double));
		propertyLock = OS_SPINLOCK_INIT;
		minCalibratedVal = 0;
		maxCalibratedVal = 0;
		avgArea = NSMakeRect(102,76,4,4);
		avgAreaCalibratedVal = 0.;
	}
	return self;
}
- (void) dealloc	{
	//NSLog(@"%s",__func__);
	OSSpinLockLock(&localBitmapsLock);
	if (rawImageData != nil)	{
		free(rawImageData);
		rawImageData = nil;
	}
	if (rawGainData != nil)	{
		free(rawGainData);
		rawGainData = nil;
	}
	if (rawOffsetData != nil)	{
		free(rawOffsetData);
		rawOffsetData = nil;
	}
	if (badPixels != nil)	{
		free(badPixels);
		badPixels = nil;
	}
	if (gainVals != nil)	{
		free(gainVals);
		gainVals = nil;
	}
	if (calibratedVals != nil)	{
		free(calibratedVals);
		calibratedVals = nil;
	}
	OSSpinLockUnlock(&localBitmapsLock);
	//VVRELEASE(buffer);
	[super dealloc];
}
- (void) updateBadPixels	{
	//NSLog(@"%s",__func__);
	OSSpinLockLock(&localBitmapsLock);
	if (rawImageData!=nil && rawGainData!=nil)	{
		//	start by running through 'rawImageData'- if it's a patent pixel or its value is 0, it's "bad"
		UInt16			*badPtr = badPixels;
		if (rawImageData != nil)	{
			UInt16		*rPtr = rawImageData;
			for (int y=0; y<156; ++y)	{
				for (int x=0; x<208; ++x)	{
					if (ArePixelCoordsAPatentPixel(x,y) || *rPtr<=0x000)	{
						*badPtr = 1;
					}
					else
						*badPtr = 0;
				
					++rPtr;
					++badPtr;
				}
			}
			//NSLog(@"\t\tbadPixelCount is %ld",badPixelCount);
		}
		//	run through the gain cal data- if the gain's unknown, it's "bad"
		badPtr = badPixels;
		if (rawGainData != nil)	{
			UInt16		*rPtr = rawGainData;
			for (int y=0; y<156; ++y)	{
				for (int x=0; x<208; ++x)	{
					if (x < 206)	{
						if (*rPtr==0)
							*badPtr = 1;
					}
					++rPtr;
					++badPtr;
				}
			}
		}
	}
	OSSpinLockUnlock(&localBitmapsLock);
}
- (void) applyCalibrations	{
	//NSLog(@"%s",__func__);
	if (rawImageData==nil || rawGainData==nil || rawOffsetData==nil)
		return;
	
	/*	okay, so here's the deal: the raw values output by the sensor 'drift" substantially during 
	the first hour or so of the camera's operation.  this can be observed by recording the average 
	value of a small area of the image (i used a 4x4 block of pixels) every frame for an hour, and 
	then plotting the results on a graph- the result will be an asymptotic curve.
	
	i'm no great shakes at math, so i broke the curve up into a couple discrete "chunks" in a 
	spreadsheet app, and asked it to calculate the best-fit line for each of these chunks.  this 
	gave me an equation (well, a couple equations) that i can plug the frame # into and calculate 
	the sensor value at that frame time.
	
	so what i do is i calculate what the "sensor value" is according to the eq. at the current time, 
	and then i calculate what the "sensor value" would be after an hour- these two values will give 
	me a multiplier.  if i apply this multiplier to every pixel in the frame, the results exhibit 
	less "drift" during operation, and should be more useful for measuring absolute temperatures.			*/
	//double			driftMultiplier = SensorWarmupCalMultiplierForFrameIndex(lastFrameIndex);
	double				driftMultiplier = 1.0;
	//NSLog(@"\t\tdriftMultiplier is %f",driftMultiplier);
	
	long			tmpCalMin = 32767;
	long			tmpCalMax = 0;
	double			tmpAvgVal = 0.;
	//	populate 'calibratedVals' by subtracting 'offsetVals' from 'rawImageData'
	//	note: 'calibratedVals' is flipped horizontally relative to the data we receive from the camera
	{
		OSSpinLockLock(&localBitmapsLock);
		double			*wCalibratedVals = calibratedVals+206;
		UInt16			*rData = rawImageData;
		double			col207 = 0.;
		UInt16			*rOffset = rawOffsetData;
		double			*rGain = gainVals;
		UInt16			*rBadPixel = badPixels;
		for (int y=0; y<156; ++y)	{
			col207 = (double)(*(rData + 206));
			for (int x=0; x<208; ++x)	{
				//	if this is a pixel we want to process and it's not a "bad pixel"
				if (x<206 && *rBadPixel==0)	{
					//	apply the offset, gain, and col 207 to the raw data
					SInt32		tmpRaw = (*rData);
					SInt32		tmpOffset = (*rOffset);
					SInt32		tmpCalibratedVal = (SInt32)(((double)(tmpRaw - tmpOffset) * (*rGain) + col207)*driftMultiplier);
					//	write the resulting value to 'calibratedVals'
					*wCalibratedVals = (double)(tmpCalibratedVal);
					//	calculate the min and max calibrated vals for this frame!
					tmpCalMin = fminl(tmpCalMin, tmpCalibratedVal);
					tmpCalMax = fmaxl(tmpCalMax, tmpCalibratedVal);
				}
				
				if (x<206)
					--wCalibratedVals;
				++rData;
				++rOffset;
				++rGain;
				++rBadPixel;
			}
			wCalibratedVals += (206*2);
		}
		OSSpinLockUnlock(&localBitmapsLock);
		
		
		OSSpinLockLock(&propertyLock);
		minCalibratedVal = tmpCalMin;
		maxCalibratedVal = tmpCalMax;
		OSSpinLockUnlock(&propertyLock);
		//NSLog(@"\t\traw min/max is %d / %d",rawMin,rawMax);
		//NSLog(@"\t\tscratch min/max is %d / %d",tmpCalMin,tmpCalMax);
	}
	
	
	OSSpinLockLock(&localBitmapsLock);
	
	//	fix the bad pixels in 'calibratedVals' (using 'badPixels' as the reference to which pixels are bad)
	//	note: 'calibratedVals' is flipped horizontally relative to the data we receive from the camera
	{
		UInt16			*rBadPixel = badPixels;
		for (int y=0; y<156; ++y)	{
			for (int x=0; x<208; ++x)	{
				//	if this pixel is bad...
				if (x<206 && *rBadPixel>0)	{
					//*(calibratedVals + 206*y + x) = 32767.;
					
					double			localAvg = 0.0;
					double			localAvgCount = 0.0;
					
					//	compute an average using the pixels around the "bad" pixel (only use pixels for the avg that aren't also bad!)
					
					
					int				tmpX,tmpY;
					//	above
					tmpX = x;
					tmpY = y+1;
					if (tmpX>=0 && tmpX<206 && tmpY>=0 && tmpY<156)	{
						if (*(badPixels + 208*tmpY + tmpX) == 0)	{
							localAvg += *(calibratedVals + (206*(tmpY)) + (206-tmpX));
							++localAvgCount;
						}
					}
					//	below
					tmpX = x;
					tmpY = y-1;
					if (tmpX>=0 && tmpX<206 && tmpY>=0 && tmpY<156)	{
						if (*(badPixels + 208*tmpY + tmpX) == 0)	{
							localAvg += *(calibratedVals + (206*(tmpY)) + (206-tmpX));
							++localAvgCount;
						}
					}
					//	left
					tmpX = x-1;
					tmpY = y;
					if (tmpX>=0 && tmpX<206 && tmpY>=0 && tmpY<156)	{
						if (*(badPixels + 208*tmpY + tmpX) == 0)	{
							localAvg += *(calibratedVals + (206*(tmpY)) + (206-tmpX));
							++localAvgCount;
						}
					}
					//	right
					tmpX = x+1;
					tmpY = y;
					if (tmpX>=0 && tmpX<206 && tmpY>=0 && tmpY<156)	{
						if (*(badPixels + 208*tmpY + tmpX) == 0)	{
							localAvg += *(calibratedVals + (206*(tmpY)) + (206-tmpX));
							++localAvgCount;
						}
					}
					
					*(calibratedVals + 206*y + (206-x)) = localAvg/localAvgCount;
					
				}
				
				++rBadPixel;
			}
		}
	}
	
	
	//	calculate the "average value"
	if (avgArea.size.width>0 && avgArea.size.height>0)	{
		avgAreaCalibratedVal = 0.;
		for (int y=avgArea.origin.y; y<VVMAXY(avgArea); ++y)	{
			for (int x=avgArea.origin.x; x<VVMAXX(avgArea); ++x)	{
				tmpAvgVal += *(calibratedVals+(206*y+x));
			}
		}
		
		//	get the average
		tmpAvgVal /= (avgArea.size.width * avgArea.size.height);
		//	convert the average to degrees K
		//avgAreaCalibratedVal = (0.0238*avgAreaCalibratedVal)+181.59;
		//	convert the average to degrees F
		//avgAreaCalibratedVal = ((avgAreaCalibratedVal-273.15)*1.8)+32.0;
		
		//	this bit tries to adjust 'avgAreaCalibratedVal' to compensate for the warmup curve exhibited by my camera
		{
			if (lastFrameIndex < 21000)	{
				
			}
			else if (lastFrameIndex < 40000)	{
				
			}
			else if (lastFrameIndex < 70000)	{
				
			}
			else	{
				//	else the val is fine- we're not going to alter it at all
			}
		}
	}
	
	OSSpinLockUnlock(&localBitmapsLock);
	
	OSSpinLockLock(&propertyLock);
	avgAreaCalibratedVal = tmpAvgVal;
	OSSpinLockUnlock(&propertyLock);
}


- (void) consumeDataFromDevice:(UInt16 *)n	{
	UInt16		frameType = *(n+10);
	switch (frameType)	{
	case 1:	//	offset calibration (shutter blocking sensor?)
		[self setOffsetCalData:n];
		break;
	case 3:	//	main data frame
		[self setRawData:n];
		break;
	case 4:	//	gain calibration
		[self setGainCalData:n];
		break;
	default:	//	default: just free the passed data
		free(n);
		break;
	}
}
- (void) setRawData:(UInt16 *)n	{
	//NSLog(@"%s",__func__);
	OSSpinLockLock(&localBitmapsLock);
	if (rawImageData != nil)
		free(rawImageData);
	rawImageData = n;
	
	if (n != nil)
		lastFrameIndex = (*(n+40));
	OSSpinLockUnlock(&localBitmapsLock);
	
	//	update the "bad pixels"
	[self updateBadPixels];
	
	//	apply the calibrations
	[self applyCalibrations];
}
- (void) setGainCalData:(UInt16 *)n	{
	//NSLog(@"%s",__func__);
	OSSpinLockLock(&localBitmapsLock);
	if (rawGainData != nil)
		free(rawGainData);
	rawGainData = n;
	OSSpinLockUnlock(&localBitmapsLock);
	
	//	update the "bad pixels"
	[self updateBadPixels];
	
	OSSpinLockLock(&localBitmapsLock);
	//	run through the gain cal data, calculate the avg gain
	UInt32			avgGain = 0.;
	UInt16			minGain = 16383;
	{
		UInt16			avgGainCount = 0;
		UInt16			*rPtr = rawGainData;
		UInt16			*rBadPixel = badPixels;
		for (int y=0; y<156; ++y)	{
			for (int x=0; x<208; ++x)	{
				if (x<206 && *rBadPixel==0)	{
					avgGain += *rPtr;
					++avgGainCount;
					minGain = fminl(minGain,*rPtr);
				}
				++rPtr;
				++rBadPixel;
			}
		}
		avgGain /= avgGainCount;
	}
	
	
	//	populate 'gainVals' by applying the avgGain to 'rawGainData'.  'gainVals' are essentially multipliers used on the raw + offset data
	{
		double			*wGain = gainVals;
		UInt16			*rGain = rawGainData;
		UInt16			*rBadPixel = badPixels;
		for (int y=0; y<156; ++y)	{
			for (int x=0; x<208; ++x)	{
				if (x<206 && *rBadPixel==0)	{
					//*wGain = ((double)avgGain - (double)minGain) / ((double)(*rGain) - (double)minGain);
					*wGain = ((double)avgGain - (double)0.) / ((double)(*rGain) - (double)0.);
				}
				else
					*wGain = 1.0;
			
				++rGain;
				++wGain;
				++rBadPixel;
			}
		}
	}
	OSSpinLockUnlock(&localBitmapsLock);
}
- (void) setOffsetCalData:(UInt16 *)n	{
	//NSLog(@"%s",__func__);
	OSSpinLockLock(&localBitmapsLock);
	if (rawOffsetData != nil)
		free(rawOffsetData);
	rawOffsetData = n;
	OSSpinLockUnlock(&localBitmapsLock);
}

- (double) minCalibratedVal	{
	OSSpinLockLock(&propertyLock);
	double		returnMe = minCalibratedVal;
	OSSpinLockUnlock(&propertyLock);
	return returnMe;
}
- (double) maxCalibratedVal	{
	OSSpinLockLock(&propertyLock);
	double		returnMe = maxCalibratedVal;
	OSSpinLockUnlock(&propertyLock);
	return returnMe;
}
- (void) setAvgArea:(NSRect)n	{
	OSSpinLockLock(&propertyLock);
	avgArea = n;
	OSSpinLockUnlock(&propertyLock);
}
- (NSRect) avgArea	{
	OSSpinLockLock(&propertyLock);
	NSRect		returnMe = avgArea;
	OSSpinLockUnlock(&propertyLock);
	return returnMe;
}
- (double) avgAreaCalibratedVal	{
	OSSpinLockLock(&propertyLock);
	double		returnMe = avgAreaCalibratedVal;
	OSSpinLockUnlock(&propertyLock);
	return returnMe;
}
- (long) lastFrameIndex	{
	return lastFrameIndex;
}
- (double *) calibratedVals	{
	return calibratedVals;
}
- (NSSize) calibratedSize	{
	return NSMakeSize(206,156);
}


@end





BOOL ArePixelCoordsAPatentPixel(long x, long y)	{
	int			pattern_start = (10 - y * 4) % 15;
	if (pattern_start < 0)
		pattern_start += 15;
	
	if (x>=pattern_start && ((x-pattern_start)%15)==0)
		return YES;
	return NO;
}
BOOL IsPixelIndexAPatentPixel(long pixelIndex)	{
	return ArePixelCoordsAPatentPixel(pixelIndex%206, pixelIndex/206);
}
double SensorWarmupCalMultiplierForFrameIndex(double t)	{
	double			returnMe = 0.;
	if (t>=0 && t<21000)	{
		returnMe = 3.225*pow(10.,-14.)*pow(t,4.) - 8.582*pow(10.,-10.)*pow(t,3.) + 1.193*pow(10.,-5.)*pow(t,2.) - 0.1001*t + 5395;
	}
	else if (t>=21000 && t<39900)	{
		returnMe = -6.496*pow(10.,-12.)*pow(t,3.) - 5.773*pow(10.,-7.)*pow(t,2.) - 0.0179*t + 5088.9;
	}
	else if (t>=39900 && t<69900)	{
		returnMe = -5.455*pow(10.,-13.)*pow(t,3.) + 1.142*pow(10.,-7.)*pow(t,2.) - 0.0077*t + 5040.2;
	}
	else if (t>=69900 && t<123900)	{
		returnMe = -6.989*pow(10.,-5.)*t + 4879.1;
	}
	else
		returnMe = 4870.0;
	
	returnMe = 4870./returnMe;
	
	return returnMe;
}
