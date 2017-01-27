//
//  ViewController.m
//  OptiNav
//
//  Created by Dragan Ahmetovic on 26/1/2017.
//  Copyright © 2017 Dragan Ahmetovic. All rights reserved.
//

#import "ViewController.h"
#import <opencv2/opencv.hpp>
#import <AVFoundation/AVFoundation.h>

const int PATCH_SIZE = 31;
const int MAX_POINTS_COUNT = 50;
const int MAX_AVGFILTER_SIZE = 5;
const int32_t MAX_FPS = 30;
const CGSize RESOLUTION = CGSizeMake(1280, 720);
const cv::Point2f CENTER = cv::Point2f(360,640);
const cv::TermCriteria CRITERIA = cv::TermCriteria(cv::TermCriteria::COUNT|cv::TermCriteria::EPS,20,0.03);

@interface ViewController () <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    AVCaptureSession            *_session;
    IBOutlet UIImageView        *_preview;
    
    cv::Mat                     _currentFrame;
    cv::Mat                     _previousFrame;
    
    //if using fir
    //cv::Point2f                 _avgfilter[MAX_AVGFILTER_SIZE];
    //size_t                      _avgfiltersize;
    
    //if using iir
    cv::Point2f                 _avg;

    cv::vector<cv::Point2f>     _fallbackpoints;
}
@end

@implementation ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self setupCaptureSession];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [_preview becomeFirstResponder];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    [_preview resignFirstResponder];
}

- (BOOL)shouldAutorotate
{
    return NO;
}

- (BOOL)prefersStatusBarHidden
{
    return YES;
}

- (void)dealloc
{
    [_session stopRunning];
}

// Create and configure a capture session and start it running
- (void)setupCaptureSession
{
    NSError *error = nil;
    
    //if using iif
    _avg = cv::Point2f(0,0);
    
    //if using fir
    //_avgfiltersize = 0;

    //make fallback grid
    for(size_t i = 0; i*80+40 < RESOLUTION.width; i++)
        for(size_t j = 0; j*80+40 < RESOLUTION.height; j++)
            _fallbackpoints.push_back(cv::Point2f(j*80+40,i*80+40));
    
    _session = [[AVCaptureSession alloc] init];
    
    _session.sessionPreset = AVCaptureSessionPreset1280x720;
    
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    [_session addInput:input];
    
    //setup output
    AVCaptureVideoDataOutput *videoDataOutput = [AVCaptureVideoDataOutput new];

    videoDataOutput.videoSettings =
        [NSDictionary
            dictionaryWithObject:
                [NSNumber numberWithUnsignedInteger:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            forKey:
                (id)kCVPixelBufferPixelFormatTypeKey];
    
    dispatch_queue_t videoDataOutputQueue = dispatch_queue_create("cmu.navcog.OptiNav.videodataoutputqueue", DISPATCH_QUEUE_SERIAL);

    [videoDataOutput setSampleBufferDelegate:self queue:videoDataOutputQueue];
    
    if ([_session canAddOutput:videoDataOutput])
        [_session addOutput:videoDataOutput];
    
    //set orientation
    AVCaptureConnection *captureConnection = [[[[_session outputs] firstObject] connections] firstObject];
    
    if ([captureConnection isVideoOrientationSupported]) {
        UIInterfaceOrientation orientation = [[UIApplication sharedApplication] statusBarOrientation];
        [captureConnection setVideoOrientation:(AVCaptureVideoOrientation)orientation];
    }

    //and go
    [_session startRunning];
    
    //setup framerate and focus
    [self configureDevice:device frameRate:MAX_FPS];

}

- (void)configureDevice:(AVCaptureDevice *)device frameRate:(int32_t)frameRate
{
    if ([device lockForConfiguration:NULL] == YES)
    {
        device.activeVideoMinFrameDuration = CMTimeMake(1, frameRate);
        device.activeVideoMaxFrameDuration = CMTimeMake(1, frameRate);
        
        if([device isFocusPointOfInterestSupported] && [device isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
            
            CGPoint center = CGPointMake(
                                         self.view.center.x/_preview.bounds.size.width,
                                         self.view.center.y/_preview.bounds.size.height);
            
            [device setFocusPointOfInterest:center];
            [device setFocusMode:AVCaptureFocusModeAutoFocus];
            [device unlockForConfiguration];
        }
        
        [device unlockForConfiguration];
    }
}

- (cv::Mat)MatFromSampleBuffer: (CMSampleBufferRef)buffer {
    CVImageBufferRef imgBuf = CMSampleBufferGetImageBuffer(buffer);
    
    CVPixelBufferLockBaseAddress(imgBuf, 0);
    
    void *imgBufAddr = CVPixelBufferGetBaseAddressOfPlane(imgBuf, 0);
    
    int height = (int)CVPixelBufferGetHeight(imgBuf);
    int width = (int)CVPixelBufferGetWidth(imgBuf);
    
    cv::Mat mat;
    mat.create(height, width, CV_8UC1);
    memcpy(mat.data, imgBufAddr, width * height);
    
    CVPixelBufferUnlockBaseAddress(imgBuf, 0);
    
    return mat;
}

- (UIImage *)imageFromMat:(const cv::Mat *)mat {
    
    NSData *data = [NSData dataWithBytes:mat->data length: mat->elemSize() * mat->total()];
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data);
    
    CGImageRef imageRef = CGImageCreate(
                                        mat->cols,
                                        mat->rows,
                                        8,
                                        8 * mat->elemSize(),
                                        mat->step.p[0],
                                        colorSpace,
                                        kCGImageAlphaNone|kCGBitmapByteOrderDefault,
                                        provider,
                                        NULL,
                                        false,
                                        kCGRenderingIntentDefault);
    
    
    UIImage *finalImage = [UIImage imageWithCGImage:imageRef];
    
    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    
    return finalImage;
}

// Delegate routine that is called when a sample buffer was written
- (void)captureOutput:          (AVCaptureOutput *)captureOutput
        didOutputSampleBuffer:  (CMSampleBufferRef)sampleBuffer
        fromConnection:         (AVCaptureConnection *)connection
{
    
    _currentFrame = [self MatFromSampleBuffer:sampleBuffer];
    
    /********FEATURES*********/
    cv::vector<cv::KeyPoint> kpoints;
    cv::vector<cv::Point2f> points;

    //goodFeaturesToTrack(_currentFrame, _points[0], MAX_POINTS_COUNT, 0.01, 20); //slow
    //FAST(_currentFrame,_kpoints, 100, true); // bad features
    
    cv::ORB orb = cv::ORB::ORB(MAX_POINTS_COUNT,1.5f,4,PATCH_SIZE,0,2,cv::ORB::HARRIS_SCORE,PATCH_SIZE); //faster options
    //cv::ORB orb; //default constructor
    orb.detect(_currentFrame, kpoints); //better and faster than shi-tomasi, better than FAST
    
    if(kpoints.size() < 10) //if small number of points found use a grid of points as features
        points = _fallbackpoints;
    else //use feature points found
        cv::KeyPoint::convert(kpoints, points);
    
    /*************************/

    cv::Point2f result = [self opticalFlowUsingFeaturePoints: points];
    
    //moving average iir
    _avg = _avg*(1-1/double(MAX_AVGFILTER_SIZE))+result*(1/double(MAX_AVGFILTER_SIZE));
    
    //moving average fir
    //for(long i = _avgfiltersize-1; i > 0; i--) {
    //    _avgfilter[i] = _avgfilter[i-1];
    //    _avg += _avgfilter[i];
    //}
    //_avgfilter[0] = result;
    //_avg += _avgfilter[0];
    //if(_avgfiltersize < MAX_AVGFILTER_SIZE)
    //  _avgfiltersize++;
    //_avg *= 1/double(MAX_AVGFILTER_SIZE);
    
    //show results
    cv::Point2f show = _avg*5 + CENTER;
    
    circle(_currentFrame, CENTER, 10, cv::Scalar(0,255,0), -1, 8);
    circle(_currentFrame, show, 10, cv::Scalar(255,255,0), -1, 8);
    line(_currentFrame, CENTER, show, cv::Scalar(255,255,0), 8, 8, 0);

    UIImage *imageToDisplay = [self imageFromMat:&_currentFrame];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        _preview.image = imageToDisplay;
    });
}

- (cv::Point2f)opticalFlowUsingFeaturePoints: (cv::vector<cv::Point2f>) points
{
    cv::Point2f avg = cv::Point2f(0,0);
    
    cv::vector<cv::Point2f> newpoints;
    
    cv::vector<uchar> status;
    cv::vector<float> err;
        
    if(_previousFrame.empty()) {
        _currentFrame.copyTo(_previousFrame);
    } else {
    
        calcOpticalFlowPyrLK(
                             _previousFrame,
                             _currentFrame,
                             points,
                             newpoints,
                             status,
                             err,
                             cv::Size(PATCH_SIZE,PATCH_SIZE),
                             3,
                             CRITERIA,
                             0,
                             0.001);
        
        cv::swap(_previousFrame, _currentFrame);

        for(size_t i = 0; i < points.size(); i++) {
            //find average vector
            avg = (avg*(int)i + newpoints[i] - points[i])*((double)1/(i+1));

            //draw feature points
            //circle(_currentFrame, points[i], 1, cv::Scalar(255,255,255), -1, 8);
            
            //compute angle
            //compute norm
            //when transmitting gyro data use angle to tweak it and norm as a confidence measure
        }
    }

    return avg;
}

@end
