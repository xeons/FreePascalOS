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
  CELT's band energies (RFC 6716 section 4.3.2): the coarse energy in
  6 dB steps, predicted in time and frequency and coded with the Laplace
  model, then the fine energy bits and the leftover bits that finalise
  it. Energies are base-2 logarithms (1.0 = 6 dB) relative to the band
  means.
}
unit Media.Opus.CeltEnergy;

{$mode objfpc}
{$H+}
{$pointermath on}

interface

uses
  Media.Opus.RangeDecoder,
  Media.Opus.CeltRate;

procedure CeltDecodeCoarseEnergy(StartBand, EndBand: Integer; OldEnergies: PSingle; Intra: Boolean;
  Decoder: TOpusRangeDecoder; Channels, LM: Integer);
procedure CeltDecodeFineEnergy(StartBand, EndBand: Integer; OldEnergies: PSingle; const FineBits: TCeltBandInts;
  Decoder: TOpusRangeDecoder; Channels: Integer);
procedure CeltFinaliseEnergy(StartBand, EndBand: Integer; OldEnergies: PSingle;
  const FineBits, FinePriority: TCeltBandInts; BitsLeft: Integer; Decoder: TOpusRangeDecoder; Channels: Integer);

implementation

uses
  Media.Opus.CeltTables;

procedure CeltDecodeCoarseEnergy(StartBand, EndBand: Integer; OldEnergies: PSingle; Intra: Boolean;
  Decoder: TOpusRangeDecoder; Channels, LM: Integer);
var
  Previous: array[0..1] of Single;
  Coefficient, Beta, Q, Value: Single;
  Budget, Tell, Band, Channel, Quantised, ModelIndex, IntraIndex: Integer;
begin
  Previous[0] := 0;
  Previous[1] := 0;
  if Intra then
  begin
    Coefficient := 0;
    Beta := CeltBetaIntra;
    IntraIndex := 1;
  end
  else
  begin
    Beta := CeltBetaCoefficients[LM];
    Coefficient := CeltPredictionCoefficients[LM];
    IntraIndex := 0;
  end;
  Budget := Integer(Decoder.Storage) * 8;
  for Band := StartBand to EndBand - 1 do
    for Channel := 0 to Channels - 1 do
    begin
      Tell := Decoder.Tell;
      if Budget - Tell >= 15 then
      begin
        if Band < 20 then
          ModelIndex := 2 * Band
        else
          ModelIndex := 40;
        Quantised := Decoder.DecodeLaplace(LongWord(CeltEnergyProbabilityModel[LM, IntraIndex, ModelIndex]) shl 7,
          CeltEnergyProbabilityModel[LM, IntraIndex, ModelIndex + 1] shl 6);
      end
      else if Budget - Tell >= 2 then
      begin
        Quantised := Decoder.DecodeIcdf(@CeltSmallEnergyIcdf[0], 2);
        Quantised := (Quantised shr 1) xor -(Quantised and 1);
      end
      else if Budget - Tell >= 1 then
        Quantised := -Ord(Decoder.DecodeBitLogP(1))
      else
        Quantised := -1;
      Q := Quantised;
      if OldEnergies[Band + Channel * CeltBandCount] < -9 then
        OldEnergies[Band + Channel * CeltBandCount] := -9;
      Value := Coefficient * OldEnergies[Band + Channel * CeltBandCount] + Previous[Channel] + Q;
      OldEnergies[Band + Channel * CeltBandCount] := Value;
      Previous[Channel] := Previous[Channel] + Q - Beta * Q;
    end;
end;

procedure CeltDecodeFineEnergy(StartBand, EndBand: Integer; OldEnergies: PSingle; const FineBits: TCeltBandInts;
  Decoder: TOpusRangeDecoder; Channels: Integer);
var
  Band, Channel, Quantised: Integer;
  Offset: Single;
begin
  for Band := StartBand to EndBand - 1 do
  begin
    if FineBits[Band] <= 0 then
      Continue;
    for Channel := 0 to Channels - 1 do
    begin
      Quantised := Decoder.DecodeBits(FineBits[Band]);
      Offset := (Quantised + 0.5) * (1 shl (14 - FineBits[Band])) * (1 / 16384) - 0.5;
      OldEnergies[Band + Channel * CeltBandCount] := OldEnergies[Band + Channel * CeltBandCount] + Offset;
    end;
  end;
end;

procedure CeltFinaliseEnergy(StartBand, EndBand: Integer; OldEnergies: PSingle;
  const FineBits, FinePriority: TCeltBandInts; BitsLeft: Integer; Decoder: TOpusRangeDecoder; Channels: Integer);
var
  Priority, Band, Channel, Quantised: Integer;
  Offset: Single;
begin
  for Priority := 0 to 1 do
  begin
    Band := StartBand;
    while (Band < EndBand) and (BitsLeft >= Channels) do
    begin
      if (FineBits[Band] < CeltMaximumFineBits) and (FinePriority[Band] = Priority) then
        for Channel := 0 to Channels - 1 do
        begin
          Quantised := Decoder.DecodeBits(1);
          Offset := (Quantised - 0.5) * (1 shl (14 - FineBits[Band] - 1)) * (1 / 16384);
          OldEnergies[Band + Channel * CeltBandCount] := OldEnergies[Band + Channel * CeltBandCount] + Offset;
          Dec(BitsLeft);
        end;
      Inc(Band);
    end;
  end;
end;

end.
