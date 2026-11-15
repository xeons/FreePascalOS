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
}

{
  Effects on voices: the interface every effect has (like XAudio2's
  XAPO), and a voice's chain of them.

  An effect works in place on a voice's samples (32-bit float,
  interleaved, Channels per frame) once per processing pass. Parameters
  are a block of bytes whose layout belongs to the effect. TailFrames
  says how long the effect still sounds after its input stopped (a
  reverb's tail), so a voice stopped with its tails keeps processing
  that long. An effect is released (Release) when its voice is
  destroyed or the chain is replaced.

  Anyone can write an effect: fill in a TAudioEffect with the routines
  and a state of one's own. Audio.Effects has the built-in ones.
}
unit Audio.EffectChain;

{$mode objfpc}
{$pointermath on}

interface

const
  MaximumEffects = 8;

type
  PAudioEffect = ^TAudioEffect;
  TAudioEffect = record
    { Processes Frames frames of Channels samples at Rate, in place. }
    Process: procedure(Effect: PAudioEffect; Samples: PSingle; Frames, Channels, Rate: LongWord);
    SetParameters: procedure(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
    GetParameters: procedure(Effect: PAudioEffect; Parameters: Pointer; Size: LongWord);
    { Forgets everything heard so far (a voice's discontinuity). }
    Reset: procedure(Effect: PAudioEffect);
    Release: procedure(Effect: PAudioEffect);
    TailFrames: function(Effect: PAudioEffect; Rate: LongWord): LongWord;
    State: Pointer;
  end;

  TEffectSlot = record
    Effect: PAudioEffect;
    Enabled: Boolean;
  end;

  TEffectChain = record
    Slots: array[0..MaximumEffects - 1] of TEffectSlot;
    Count: Integer;
  end;

{ A new effect with StateBytes of zeroed state (Effect^.State), whose
  Release frees both (an effect can set its own Release that ends with
  FreeEffect). Nil if out of memory. }
function CreateEffect(StateBytes: LongWord): PAudioEffect;
procedure FreeEffect(Effect: PAudioEffect);

procedure ClearEffectChain(var Chain: TEffectChain);
{ Runs the enabled effects in order. }
procedure ProcessEffectChain(var Chain: TEffectChain; Samples: PSingle; Frames, Channels, Rate: LongWord);
{ The longest tail of the chain's enabled effects. }
function EffectChainTail(var Chain: TEffectChain; Rate: LongWord): LongWord;
procedure ResetEffectChain(var Chain: TEffectChain);

implementation

uses
  Sys.Memory;

function CreateEffect(StateBytes: LongWord): PAudioEffect;
begin
  Result := PAudioEffect(AllocateMemory(SizeOf(TAudioEffect) + StateBytes));
  if Result = nil then
    Exit;
  FillChar(Result^, SizeOf(TAudioEffect) + StateBytes, 0);
  Result^.State := PByte(Result) + SizeOf(TAudioEffect);
  Result^.Release := @FreeEffect;
end;

procedure FreeEffect(Effect: PAudioEffect);
begin
  FreeMemory(Effect);
end;

procedure ClearEffectChain(var Chain: TEffectChain);
var
  Index: Integer;
begin
  for Index := 0 to Chain.Count - 1 do
    if Assigned(Chain.Slots[Index].Effect^.Release) then
      Chain.Slots[Index].Effect^.Release(Chain.Slots[Index].Effect);
  Chain.Count := 0;
end;

procedure ProcessEffectChain(var Chain: TEffectChain; Samples: PSingle; Frames, Channels, Rate: LongWord);
var
  Index: Integer;
begin
  for Index := 0 to Chain.Count - 1 do
    if Chain.Slots[Index].Enabled then
      Chain.Slots[Index].Effect^.Process(Chain.Slots[Index].Effect, Samples, Frames, Channels, Rate);
end;

function EffectChainTail(var Chain: TEffectChain; Rate: LongWord): LongWord;
var
  Index: Integer;
  Tail: LongWord;
begin
  Result := 0;
  for Index := 0 to Chain.Count - 1 do
    if Chain.Slots[Index].Enabled and Assigned(Chain.Slots[Index].Effect^.TailFrames) then
    begin
      Tail := Chain.Slots[Index].Effect^.TailFrames(Chain.Slots[Index].Effect, Rate);
      if Tail > Result then
        Result := Tail;
    end;
end;

procedure ResetEffectChain(var Chain: TEffectChain);
var
  Index: Integer;
begin
  for Index := 0 to Chain.Count - 1 do
    if Assigned(Chain.Slots[Index].Effect^.Reset) then
      Chain.Slots[Index].Effect^.Reset(Chain.Slots[Index].Effect);
end;

end.
