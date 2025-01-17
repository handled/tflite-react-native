
#import "TfliteReactNative.h"

#include <pthread.h>
#include <unistd.h>
#include <fstream>
#include <iostream>
#include <queue>
#include <sstream>
#include <string>

#include "tensorflow/lite/kernels/register.h"
#include "tensorflow/lite/model.h"
#include "tensorflow/lite/string_util.h"
#include "tensorflow/lite/op_resolver.h"

#include "ios_image_load.h"

#define LOG(x) std::cerr

@implementation TfliteReactNative

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}

RCT_EXPORT_MODULE()

std::vector<std::string> labels;
std::unique_ptr<tflite::FlatBufferModel> model;
std::unique_ptr<tflite::Interpreter> interpreter;

static void LoadLabels(NSString* labels_path,
                       std::vector<std::string>* label_strings) {
  if (!labels_path) {
    LOG(ERROR) << "Failed to find label file at" << labels_path;
  }
  std::ifstream t;
  t.open([labels_path UTF8String]);
  std::string line;
  while (t) {
    std::getline(t, line);
    label_strings->push_back(line);
  }
  t.close();
}

RCT_EXPORT_METHOD(loadModel:(NSString *)model_file
                  withLabels:(NSString *)labels_file
                  numThreads:(int)num_threads
                  callback:(RCTResponseSenderBlock)callback)
{
  /*

  We need to use the fully qualified full paths for model and label files passed into this method 
  because it will be dynamically added to the Downloads directory via rn-fetch-blob.

  We will probably want to revisit this approach to use NSBundle methods to generate the URLs

  */
  // NSString* graph_path = [[NSBundle mainBundle] pathForResource:model_file ofType:nil];
  // model = tflite::FlatBufferModel::BuildFromFile([graph_path UTF8String]);

  model = tflite::FlatBufferModel::BuildFromFile([model_file UTF8String]);

  // LOG(INFO) << "Loaded model " << graph_path;
  LOG(INFO) << "Loaded model " << model_file;

  model->error_reporter();
  LOG(INFO) << "resolved reporter";
  
  if (!model) {
    callback(@[[NSString stringWithFormat:@"%s %@", "Failed to mmap model", model_file]]);
  }
  
  // NSString* labels_path = [[NSBundle mainBundle] pathForResource:labels_file ofType:nil];
  // LoadLabels(labels_path, &labels);

  LoadLabels(labels_file, &labels);
  
  tflite::ops::builtin::BuiltinOpResolver resolver;
  tflite::InterpreterBuilder(*model, resolver)(&interpreter);
  if (!interpreter) {
    callback(@[@"Failed to construct interpreter"]);
  }
  
  if (interpreter->AllocateTensors() != kTfLiteOk) {
    callback(@[@"Failed to allocate tensors!"]);
  }
  
  if (num_threads != -1) {
    interpreter->SetNumThreads(num_threads);
  }
  
  callback(@[[NSNull null], @"success"]);
}

void feedInputTensorImage(const NSString* image_path, float input_mean, float input_std, int* input_size) {
  int image_channels;
  int image_height;
  int image_width;
  std::vector<uint8_t> image_data = LoadImageFromFile([image_path UTF8String], &image_width, &image_height, &image_channels);
  uint8_t* in = image_data.data();
  
  assert(interpreter->inputs().size() == 1);
  int input = interpreter->inputs()[0];
  TfLiteTensor* input_tensor = interpreter->tensor(input);
  const int input_channels = input_tensor->dims->data[3];
  const int width = input_tensor->dims->data[2];
  const int height = input_tensor->dims->data[1];
  *input_size = width;
  
  if (input_tensor->type == kTfLiteUInt8) {
    uint8_t* out = interpreter->typed_tensor<uint8_t>(input);
    for (int y = 0; y < height; ++y) {
      const int in_y = (y * image_height) / height;
      uint8_t* in_row = in + (in_y * image_width * image_channels);
      uint8_t* out_row = out + (y * width * input_channels);
      for (int x = 0; x < width; ++x) {
        const int in_x = (x * image_width) / width;
        uint8_t* in_pixel = in_row + (in_x * image_channels);
        uint8_t* out_pixel = out_row + (x * input_channels);
        for (int c = 0; c < input_channels; ++c) {
          out_pixel[c] = in_pixel[c];
        }
      }
    }
  } else { // kTfLiteFloat32
    float* out = interpreter->typed_tensor<float>(input);
    for (int y = 0; y < height; ++y) {
      const int in_y = (y * image_height) / height;
      uint8_t* in_row = in + (in_y * image_width * image_channels);
      float* out_row = out + (y * width * input_channels);
      for (int x = 0; x < width; ++x) {
        const int in_x = (x * image_width) / width;
        uint8_t* in_pixel = in_row + (in_x * image_channels);
        float* out_pixel = out_row + (x * input_channels);
        for (int c = 0; c < input_channels; ++c) {
          out_pixel[c] = (in_pixel[c] - input_mean) / input_std;
        }
      }
    }
  }
}

NSMutableArray* GetTopN(const float* prediction, const unsigned long prediction_size, const int num_results,
                        const float threshold) {
  std::priority_queue<std::pair<float, int>, std::vector<std::pair<float, int>>,
  std::greater<std::pair<float, int>>> top_result_pq;
  std::vector<std::pair<float, int>> top_results;
  
  const long count = prediction_size;
  for (int i = 0; i < count; ++i) {
    const float value = prediction[i];
    
    if (value < threshold) {
      continue;
    }
    
    top_result_pq.push(std::pair<float, int>(value, i));
    
    if (top_result_pq.size() > num_results) {
      top_result_pq.pop();
    }
  }
  
  while (!top_result_pq.empty()) {
    top_results.push_back(top_result_pq.top());
    top_result_pq.pop();
  }
  std::reverse(top_results.begin(), top_results.end());
  
  NSMutableArray* predictions = [NSMutableArray array];
  for (const auto& result : top_results) {
    const float confidence = result.first;
    const int index = result.second;
    NSString* labelObject = [NSString stringWithUTF8String:labels[index].c_str()];
    NSNumber* valueObject = [NSNumber numberWithFloat:confidence];
    NSMutableDictionary* res = [NSMutableDictionary dictionary];
    [res setValue:[NSNumber numberWithInt:index] forKey:@"index"];
    [res setObject:labelObject forKey:@"label"];
    [res setObject:valueObject forKey:@"confidence"];
    [predictions addObject:res];
  }
  
  return predictions;
}

RCT_EXPORT_METHOD(runModelOnImage:(NSString*)image_path
                  mean:(float)input_mean
                  std:(float)input_std
                  numResults:(int)num_results
                  threshold:(float)threshold
                  callback:(RCTResponseSenderBlock)callback) {
  
  if (!interpreter) {
    NSLog(@"Failed to construct interpreter.");
    callback(@[@"Failed to construct interpreter."]);
  }
  
  image_path = [image_path stringByReplacingOccurrencesOfString:@"file://" withString:@""];
  int input_size;
  feedInputTensorImage(image_path, input_mean, input_std, &input_size);
  
  if (interpreter->Invoke() != kTfLiteOk) {
    NSLog(@"Failed to invoke!");
    callback(@[@"Failed to invoke!"]);
  }
  
  float* output = interpreter->typed_output_tensor<float>(0);
  
  if (output == NULL)
    callback(@[@"No output!"]);
  
  const unsigned long output_size = labels.size();
  NSMutableArray* results = GetTopN(output, output_size, num_results, threshold);
  callback(@[[NSNull null], results]);
}

NSMutableArray* parseSSDMobileNet(float threshold, int num_results_per_class) {
  assert(interpreter->outputs().size() == 4);
  
  NSMutableArray* results = [NSMutableArray array];
  float* output_locations = interpreter->typed_output_tensor<float>(0);
  float* output_classes = interpreter->typed_output_tensor<float>(1);
  float* output_scores = interpreter->typed_output_tensor<float>(2);
  float* num_detections = interpreter->typed_output_tensor<float>(3);
  
  NSMutableDictionary* counters = [NSMutableDictionary dictionary];
  for (int d = 0; d < *num_detections; d++)
  {
    const int detected_class = output_classes[d];
    float score = output_scores[d];
    
    if (score < threshold) continue;
    
    NSMutableDictionary* res = [NSMutableDictionary dictionary];
    NSString* class_name = [NSString stringWithUTF8String:labels[detected_class + 1].c_str()];
    NSObject* counter = [counters objectForKey:class_name];
    if (counter) {
      int countValue = [(NSNumber*)counter intValue] + 1;
      if (countValue > num_results_per_class) {
        continue;
      }
      [counters setObject:@(countValue) forKey:class_name];
    } else {
      [counters setObject:@(1) forKey:class_name];
    }
    
    [res setObject:@(score) forKey:@"confidenceInClass"];
    [res setObject:class_name forKey:@"detectedClass"];
    
    const float ymin = fmax(0, output_locations[d * 4]);
    const float xmin = fmax(0, output_locations[d * 4 + 1]);
    const float ymax = output_locations[d * 4 + 2];
    const float xmax = output_locations[d * 4 + 3];
    
    NSMutableDictionary* rect = [NSMutableDictionary dictionary];
    [rect setObject:@(xmin) forKey:@"x"];
    [rect setObject:@(ymin) forKey:@"y"];
    [rect setObject:@(fmin(1 - xmin, xmax - xmin)) forKey:@"w"];
    [rect setObject:@(fmin(1 - ymin, ymax - ymin)) forKey:@"h"];
    
    [res setObject:rect forKey:@"rect"];
    [results addObject:res];
  }
  
  return results;
}

float sigmoid(float x) {
  return 1.0 / (1.0 + exp(-x));
}

void softmax(float vals[], int count) {
  float max = -FLT_MAX;
  for (int i=0; i<count; i++) {
    max = fmax(max, vals[i]);
  }
  float sum = 0.0;
  for (int i=0; i<count; i++) {
    vals[i] = exp(vals[i] - max);
    sum += vals[i];
  }
  for (int i=0; i<count; i++) {
    vals[i] /= sum;
  }
}

NSMutableArray* parseYOLO(int num_classes, const NSArray* anchors, int block_size, int num_boxes_per_bolock,
                          int num_results_per_class, float threshold, int input_size) {
  float* output = interpreter->typed_output_tensor<float>(0);
  NSMutableArray* results = [NSMutableArray array];
  std::priority_queue<std::pair<float, NSMutableDictionary*>, std::vector<std::pair<float, NSMutableDictionary*>>,
  std::less<std::pair<float, NSMutableDictionary*>>> top_result_pq;
  
  int grid_size = input_size / block_size;
  for (int y = 0; y < grid_size; ++y) {
    for (int x = 0; x < grid_size; ++x) {
      for (int b = 0; b < num_boxes_per_bolock; ++b) {
        int offset = (grid_size * (num_boxes_per_bolock * (num_classes + 5))) * y
        + (num_boxes_per_bolock * (num_classes + 5)) * x
        + (num_classes + 5) * b;
        
        float confidence = sigmoid(output[offset + 4]);
        
        float classes[num_classes];
        for (int c = 0; c < num_classes; ++c) {
          classes[c] = output[offset + 5 + c];
        }
        
        softmax(classes, num_classes);
        
        int detected_class = -1;
        float max_class = 0;
        for (int c = 0; c < num_classes; ++c) {
          if (classes[c] > max_class) {
            detected_class = c;
            max_class = classes[c];
          }
        }
        
        float confidence_in_class = max_class * confidence;
        if (confidence_in_class > threshold) {
          NSMutableDictionary* rect = [NSMutableDictionary dictionary];
          NSMutableDictionary* res = [NSMutableDictionary dictionary];
          
          float xPos = (x + sigmoid(output[offset + 0])) * block_size;
          float yPos = (y + sigmoid(output[offset + 1])) * block_size;
          
          float anchor_w = [[anchors objectAtIndex:(2 * b + 0)] floatValue];
          float anchor_h = [[anchors objectAtIndex:(2 * b + 1)] floatValue];
          float w = (float) (exp(output[offset + 2]) * anchor_w) * block_size;
          float h = (float) (exp(output[offset + 3]) * anchor_h) * block_size;
          
          float x = fmax(0, (xPos - w / 2) / input_size);
          float y = fmax(0, (yPos - h / 2) / input_size);
          [rect setObject:@(x) forKey:@"x"];
          [rect setObject:@(y) forKey:@"y"];
          [rect setObject:@(fmin(1 - x, w / input_size)) forKey:@"w"];
          [rect setObject:@(fmin(1 - y, h / input_size)) forKey:@"h"];
          
          [res setObject:rect forKey:@"rect"];
          [res setObject:@(confidence_in_class) forKey:@"confidenceInClass"];
          NSString* class_name = [NSString stringWithUTF8String:labels[detected_class].c_str()];
          [res setObject:class_name forKey:@"detectedClass"];
          
          top_result_pq.push(std::pair<float, NSMutableDictionary*>(confidence_in_class, res));
        }
      }
    }
  }
  
  NSMutableDictionary* counters = [NSMutableDictionary dictionary];
  while (!top_result_pq.empty()) {
    NSMutableDictionary* result = top_result_pq.top().second;
    top_result_pq.pop();
    
    NSString* detected_class = [result objectForKey:@"detectedClass"];
    NSObject* counter = [counters objectForKey:detected_class];
    if (counter) {
      int countValue = [(NSNumber*)counter intValue] + 1;
      if (countValue > num_results_per_class) {
        continue;
      }
      [counters setObject:@(countValue) forKey:detected_class];
    } else {
      [counters setObject:@(1) forKey:detected_class];
    }
    [results addObject:result];
  }
  
  return results;
}

RCT_EXPORT_METHOD(detectObjectOnImage:(NSString*)image_path
                  model:(NSString*)model
                  mean:(float)input_mean
                  std:(float)input_std
                  threshold:(float)threshold
                  numResultsPerClass:(int)num_results_per_class
                  anchors:(NSArray*)anchors
                  blockSize:(int)block_size
                  callback:(RCTResponseSenderBlock)callback) {
  if (!interpreter) {
    NSLog(@"Failed to construct interpreter.");
    callback(@[@"Failed to construct interpreter."]);
  }
  
  int input_size;
  image_path = [image_path stringByReplacingOccurrencesOfString:@"file://" withString:@""];
  feedInputTensorImage(image_path, input_mean, input_std, &input_size);
  
  if (interpreter->Invoke() != kTfLiteOk) {
    NSLog(@"Failed to invoke!");
    callback(@[@"Failed to invoke!"]);
  }
  
  NSMutableArray* results;
  
  if ([model isEqual: @"SSDMobileNet"])
    results = parseSSDMobileNet(threshold, num_results_per_class);
  else
    results = parseYOLO((int)(labels.size() - 1), anchors, block_size, 5, num_results_per_class,
                     threshold, input_size);
  
  callback(@[[NSNull null], results]);
}

RCT_EXPORT_METHOD(close)
{
  interpreter = NULL;
  model = NULL;
  labels.clear();
}

@end
