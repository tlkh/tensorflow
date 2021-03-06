/* Copyright 2019 The TensorFlow Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/

// This is the optimization pattern definition file for TensorFlow Lite.

include "mlir/IR/OpBase.td"
include "mlir/StandardOps/Ops.td"
include "tensorflow/compiler/mlir/lite/ir/tfl_ops.td"

def F32ElementsAttr : ElementsAttrBase<
  CPred<"$_self.cast<ElementsAttr>().getType().getElementType().isF32()">, "float constant tensor">;

//===----------------------------------------------------------------------===//
// Ternary ops patterns.
//===----------------------------------------------------------------------===//
// Multi-pattern consisting of matching stand-alone convolution op followed by
// activation op.
multiclass FuseActFnIntoConvOpPat<dag ActFnOp, dag ActFnAttr> {
  def : Pat<(ActFnOp (TFL_Conv2DOp $input, $filter, $bias,
                                   $h_factor, $w_factor, TFL_AF_None,
                                   $padding, $stride_h, $stride_w)),
            (TFL_Conv2DOp $input, $filter, $bias,
                          $h_factor, $w_factor, ActFnAttr,
                          $padding, $stride_h, $stride_w)>;
  def : Pat<(ActFnOp (TFL_DepthwiseConv2DOp $input, $filter, $bias,
                                   $h_factor, $w_factor, TFL_AF_None,
                                   $padding, $stride_h, $stride_w,
                                   $multiplier)),
            (TFL_DepthwiseConv2DOp $input, $filter, $bias,
                                   $h_factor, $w_factor, ActFnAttr,
                                   $padding, $stride_h, $stride_w,
                                   $multiplier)>;
}

// TODO(hinsu): Also fuse ops corresponding to RELU_N1_TO_1 and SIGN_BIT fused
// activation functions.
foreach actFnPair = [[TFL_ReluOp, TFL_AF_Relu],
                     [TFL_Relu6Op, TFL_AF_Relu6],
		     [TFL_TanhOp, TFL_AF_Tanh]] in
  defm : FuseActFnIntoConvOpPat<actFnPair[0], actFnPair[1]>;


// If we see an add op adding a constant value to a convolution op with constant
// bias, we can fuse the add into the convolution op by constant folding the
// bias and the add op's constant operand.
// The following pattern restricts to float constant values for now.
def : Pat<(TFL_AddOp (TFL_Conv2DOp $input, $filter,
                          (ConstantOp F32ElementsAttr:$bias),
                          $h_factor, $w_factor, TFL_AF_None,
                          $padding, $stride_h, $stride_w),
                     (ConstantOp F32ElementsAttr:$value), $act_fn),
          (TFL_Conv2DOp $input, $filter,
                        (TFL_AddOp (ConstantOp $bias),
                                   (ConstantOp $value), TFL_AF_None),
                        $h_factor, $w_factor, $act_fn,
                        $padding, $stride_h, $stride_w)>;
def : Pat<(TFL_AddOp (TFL_DepthwiseConv2DOp $input, $filter,
                          (ConstantOp F32ElementsAttr:$bias),
                          $h_factor, $w_factor, TFL_AF_None,
                          $padding, $stride_h, $stride_w,
                          $multiplier),
                     (ConstantOp F32ElementsAttr:$value), $act_fn),
          (TFL_DepthwiseConv2DOp $input, $filter,
                          (TFL_AddOp (ConstantOp $bias),
                                     (ConstantOp $value),
                                     TFL_AF_None),
                          $h_factor, $w_factor, $act_fn,
                          $padding, $stride_h, $stride_w,
                          $multiplier)>;

def BroadcastableElementsAttrs :
    Constraint<CPred<"IsBroadcastableElementsAttrs($0, $1)">>;

// If we see a mul op multiplying a constant value to a convolution op with
// constant filter and bias, we can fuse the multiplication into the convolution
// op by constant folding the filter/bias and the mul op's constant operand.
// The following pattern restricts to float constant values for now.
def : Pat<(TFL_MulOp (TFL_DepthwiseConv2DOp $input,
                          (ConstantOp F32ElementsAttr:$filter),
                          (ConstantOp F32ElementsAttr:$bias),
                          $h_factor, $w_factor, TFL_AF_None,
                          $padding, $stride_h, $stride_w,
                          $multiplier),
                     (ConstantOp F32ElementsAttr:$value), $act_fn),
          (TFL_DepthwiseConv2DOp $input,
                          (TFL_MulOp (ConstantOp $filter),
                                     (ConstantOp $value),
                                     TFL_AF_None),
                          (TFL_MulOp (ConstantOp $bias),
                                     (ConstantOp $value),
                                     TFL_AF_None),
                          $h_factor, $w_factor, $act_fn,
                          $padding, $stride_h, $stride_w,
                          $multiplier),
          [(BroadcastableElementsAttrs $filter, $value)]>;

// This pattern applies when the same quantize/dequantize have been used twice
// with the same scale. We want to remove the redundancy.
// TODO(fengliuai): move this to the sanity check of pre-quantize pass.
def : Pat<(TFL_QuantizeOp (TFL_DequantizeOp $in), $qt), (replaceWithValue $in)>;
