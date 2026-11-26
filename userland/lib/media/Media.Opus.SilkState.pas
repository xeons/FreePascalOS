{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.

  This file follows the Opus reference decoder (RFC 6716, libopus 1.5.2),
  which carries this notice:

  Copyright (c) 2001-2011 Xiph.Org, Skype Limited, Octasic,
                          Jean-Marc Valin, Timothy B. Terriberry,
                          CSIRO, Gregory Maxwell, Mark Borgerding,
                          Erik de Castro Lopo

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions
  are met:
  - Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  - Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
  - Neither the name of Internet Society, IETF or IETF Trust, nor the
    names of specific contributors, may be used to endorse or promote
    products derived from this software without specific prior written
    permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
  A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
  OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
  DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
  THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
  OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
}

{
  The SILK decoder's state: per channel, the side information of the
  frame being decoded (indices), the excitation, LPC and LTP memories,
  the output history, and the concealment and comfort noise states; and
  the per-frame parameters (gains, prediction coefficients, pitch lags).
}
unit Media.Opus.SilkState;

{$mode objfpc}
{$H+}

interface

uses
  Media.Opus.SilkLpc,
  Media.Opus.SilkResampler;

const
  SilkMaximumFramesPerPacket = 3;
  SilkMaximumSubframes = 4;
  SilkMaximumFrequencyKHz = 16;
  SilkSubframeLengthMs = 5;
  SilkMaximumSubframeLength = SilkSubframeLengthMs * SilkMaximumFrequencyKHz;
  SilkMaximumFrameLength = SilkSubframeLengthMs * SilkMaximumSubframes * SilkMaximumFrequencyKHz;
  SilkLtpMemoryLengthMs = 20;
  SilkLtpOrder = 5;
  SilkTypeNoVoiceActivity = 0;
  SilkTypeUnvoiced = 1;
  SilkTypeVoiced = 2;
  SilkCodeIndependently = 0;
  SilkCodeIndependentlyNoLtpScaling = 1;
  SilkCodeConditionally = 2;
  SilkDecodeNormal = 0;
  SilkPacketLost = 1;
  SilkDecodeLbrr = 2;

type
  TSilkSideInfo = record
    GainsIndices: array[0..SilkMaximumSubframes - 1] of ShortInt;
    LtpIndex: array[0..SilkMaximumSubframes - 1] of ShortInt;
    NlsfIndices: array[0..SilkMaximumLpcOrder] of ShortInt;
    LagIndex: SmallInt;
    ContourIndex: ShortInt;
    SignalType: ShortInt;
    QuantOffsetType: ShortInt;
    NlsfInterpolationCoefficientQ2: ShortInt;
    PeriodicityIndex: ShortInt;
    LtpScaleIndex: ShortInt;
    Seed: ShortInt;
  end;

  TSilkConcealmentState = record
    PitchLagQ8: LongInt;
    LtpCoefficientsQ14: array[0..SilkLtpOrder - 1] of SmallInt;
    PreviousLpcQ12: array[0..SilkMaximumLpcOrder - 1] of SmallInt;
    LastFrameLost: Boolean;
    RandomSeed: LongInt;
    RandomScaleQ14: SmallInt;
    ConcealedEnergy: LongInt;
    ConcealedEnergyShift: Integer;
    PreviousLtpScaleQ14: SmallInt;
    PreviousGainQ16: array[0..1] of LongInt;
    FrequencyKHz: Integer;
    SubframeCount: Integer;
    SubframeLength: Integer;
  end;

  TSilkComfortNoiseState = record
    ExcitationBufferQ14: array[0..SilkMaximumFrameLength - 1] of LongInt;
    SmoothedNlsfQ15: array[0..SilkMaximumLpcOrder - 1] of SmallInt;
    SynthesisState: array[0..SilkMaximumLpcOrder - 1] of LongInt;
    SmoothedGainQ16: LongInt;
    RandomSeed: LongInt;
    FrequencyKHz: Integer;
  end;

  TSilkChannelState = record
    PreviousGainQ16: LongInt;
    ExcitationQ14: array[0..SilkMaximumFrameLength - 1] of LongInt;
    LpcStateQ14: array[0..SilkMaximumLpcOrder - 1] of LongInt;
    OutputBuffer: array[0..SilkMaximumFrameLength + 2 * SilkMaximumSubframeLength - 1] of SmallInt;
    PreviousLag: Integer;
    LastGainIndex: ShortInt;
    FrequencyKHz: Integer;
    ApiSampleRate: LongInt;
    SubframeCount: Integer;
    FrameLength: Integer;
    SubframeLength: Integer;
    LtpMemoryLength: Integer;
    LpcOrder: Integer;
    PreviousNlsfQ15: array[0..SilkMaximumLpcOrder - 1] of SmallInt;
    FirstFrameAfterReset: Boolean;
    PitchLagLowBitsIcdf: PByte;
    PitchContourIcdf: PByte;
    FramesDecoded: Integer;
    FramesPerPacket: Integer;
    EntropyPreviousSignalType: Integer;
    EntropyPreviousLagIndex: SmallInt;
    VadFlags: array[0..SilkMaximumFramesPerPacket - 1] of Integer;
    LbrrFlag: Integer;
    LbrrFlags: array[0..SilkMaximumFramesPerPacket - 1] of Integer;
    Resampler: TSilkResamplerState;
    NlsfCodebook: PSilkNlsfCodebook;
    Indices: TSilkSideInfo;
    ComfortNoise: TSilkComfortNoiseState;
    LossCount: Integer;
    PreviousSignalType: Integer;
    Concealment: TSilkConcealmentState;
  end;
  PSilkChannelState = ^TSilkChannelState;

  TSilkDecoderControl = record
    PitchLags: array[0..SilkMaximumSubframes - 1] of Integer;
    GainsQ16: array[0..SilkMaximumSubframes - 1] of LongInt;
    PredictionCoefficientsQ12: array[0..1, 0..SilkMaximumLpcOrder - 1] of SmallInt;
    LtpCoefficientsQ14: array[0..SilkLtpOrder * SilkMaximumSubframes - 1] of SmallInt;
    LtpScaleQ14: Integer;
  end;

implementation

end.
